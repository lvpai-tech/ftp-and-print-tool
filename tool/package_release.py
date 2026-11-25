"""Build/package locally. Never uploads or updates a production manifest."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

from bundle_print_runtime import bundle, require_bundle

# Keep a Windows subst drive in the path passed to Flutter and MSBuild.
APP = pathlib.Path(__file__).absolute().parents[1]
CHANNEL_APP_NAMES = {'local': '帧集快拍（本地版）', 'test': '帧集快拍（测试版）', 'prd': '帧集快拍'}


def run(*args):
    return subprocess.run([str(arg) for arg in args], cwd=APP, check=True,
                          capture_output=False)


def windows_payload(release, payload, node, node_license):
    if not (release / 'lvpai_ftp_client.exe').is_file():
        raise RuntimeError('release EXE is missing')
    for path in sorted(release.rglob('*')):
        relative = path.relative_to(release)
        if relative.parts[0].casefold() == 'print-runtime':
            continue
        if path.is_symlink():
            raise RuntimeError('unexpected symlink in Windows release')
        if path.is_file() and path.suffix.lower() != '.pdb':
            target = payload / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
    bundle(payload / 'print-runtime', node, node_license)


def add_msvc_runtime(release, payload):
    # Use the redistributable DLLs from the same Visual Studio instance as the build.
    cache = release.parents[1] / 'CMakeCache.txt'
    instance = re.search(r'^CMAKE_GENERATOR_INSTANCE:[^=]+=([^\r\n,]+)',
                         cache.read_text(encoding='utf-8'), re.M)
    if not instance:
        raise RuntimeError('Visual Studio installation path is missing from CMakeCache.txt')
    redist = pathlib.Path(instance.group(1)) / 'VC/Redist/MSVC'
    runtimes = list(redist.glob('*/x64/Microsoft.VC*.CRT/vcruntime140.dll'))
    if not runtimes:
        raise RuntimeError(f'No redistributable x64 Visual C++ runtime found under {redist}')
    runtime = max(runtimes, key=lambda file: tuple(map(int, file.parents[2].name.split('.'))))
    for dll in runtime.parent.glob('*.dll'):
        shutil.copy2(dll, payload / dll.name)


def write_release_info(output, package, *, version, code, platform, channel, setup=False):
    with package.open('rb') as source:
        digest = hashlib.file_digest(source, 'sha256').hexdigest()
    prefix = f'ftp-client/{channel}/{platform}' + ('/setup' if setup else '')
    manifest = {'versionCode': int(code), 'versionName': version, 'platform': platform,
                'channel': channel, 'sizeBytes': package.stat().st_size, 'sha256': digest,
                'installerUrl': f'https://cdn.hilvpai.com/{prefix}/{package.name}'}
    output.write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', required=True,
                        choices=['windows-x64', 'macos-arm64', 'macos-x64'])
    parser.add_argument('--channel', required=True, choices=['local', 'test', 'prd'])
    parser.add_argument('--flutter', default='flutter')
    parser.add_argument('--node', help='Windows: path to x64 Node executable (defaults to PATH)')
    parser.add_argument('--node-license', help='Windows: path to the corresponding Node LICENSE')
    parser.add_argument('--iscc', type=pathlib.Path, help='Windows: Inno Setup ISCC.exe, also emit Setup.exe')
    parser.add_argument('--windows-sign-tool', type=pathlib.Path, help='Windows: signtool.exe')
    parser.add_argument('--windows-sign-thumbprint', help='Windows: certificate in CurrentUser/My')
    parser.add_argument('--app', type=pathlib.Path, help='Mac: signed release .app, matching current pubspec version')
    parser.add_argument('--notary-profile', help='Mac: existing notarytool Keychain profile, no credentials in repo')
    parser.add_argument('--sign-identity', help='Mac: Developer ID Application identity for signing the DMG')
    args = parser.parse_args()
    match = re.search(r'^version:\s*([0-9]+(?:\.[0-9]+){2})\+([0-9]+)\s*$',
                      (APP / 'pubspec.yaml').read_text(encoding='utf-8'), re.M)
    if not match:
        parser.error('pubspec version must be x.y.z+integer')
    version, code = match.groups()
    if not 1 <= int(code) <= 2_000_000_000:
        parser.error('build number must be 1..2000000000')
    windows = args.platform == 'windows-x64'
    if args.iscc and (not windows or not args.iscc.is_file()):
        parser.error('--iscc must point to Inno Setup ISCC.exe for a Windows release')
    signing = args.windows_sign_tool is not None or args.windows_sign_thumbprint is not None
    if signing and (not args.iscc or not args.windows_sign_tool
                    or not args.windows_sign_tool.is_file()
                    or not re.fullmatch(r'[a-fA-F0-9]{40}', args.windows_sign_thumbprint or '')):
        parser.error('signed Windows setup requires ISCC, SignTool and a certificate thumbprint')
    extension = '.zip' if windows else '.dmg'
    name = f'lvpai-ftp-{version}-{code}-{args.platform}{extension}'
    directory = APP / 'build' / 'releases' / args.channel / args.platform
    directory.mkdir(parents=True, exist_ok=True)
    destination = directory / name
    setup = directory / f'{destination.stem}-setup.exe' if args.iscc else None
    if destination.exists() or (setup and setup.exists()):
        parser.error('release file already exists; increment version/build or explicitly archive your previous output')
    with tempfile.TemporaryDirectory(prefix='ftp-package-', dir=directory) as temporary:
        staging = pathlib.Path(temporary)
        package = staging / name
        if windows:
            if sys.platform != 'win32':
                parser.error('Windows release must be built on Windows')
            candidate = pathlib.Path(args.flutter).expanduser()
            executable = candidate.resolve() if candidate.is_file() else shutil.which(args.flutter)
            if not executable:
                parser.error('Flutter executable not found; use --flutter with its absolute path')
            run(executable, '--no-version-check', 'build', 'windows', '--release',
                f'--dart-define=LVPAI_UPDATE_ENV={args.channel}',
                f'--dart-define=LVPAI_WINDOWS_AUTO_UPDATE={str(signing).lower()}')
            release = APP / 'build/windows/x64/runner/Release'
            payload = staging / 'payload'
            windows_payload(release, payload, args.node, args.node_license)
            if signing:
                sign_windows(args, payload / 'lvpai_ftp_client.exe')
            with zipfile.ZipFile(package, 'w', zipfile.ZIP_DEFLATED) as archive:
                for path in sorted(payload.rglob('*')):
                    if path.is_file():
                        archive.write(path, path.relative_to(payload).as_posix())
            if setup:
                add_msvc_runtime(release, payload)
                run(args.iscc.resolve(), f'/O{staging}', f'/F{setup.stem}',
                    f'/DPayloadDir={payload}', f'/DAppVersion={version}+{code}',
                    f'/DWorkstation={CHANNEL_APP_NAMES[args.channel]}',
                    APP / 'windows/installer/workstation.iss')
                staged_setup = staging / setup.name
                if signing:
                    sign_windows(args, staged_setup)
        else:
            if sys.platform != 'darwin' or not args.app or not args.notary_profile or not args.sign_identity:
                parser.error('Mac requires macOS, --app, --notary-profile and --sign-identity')
            app = args.app.expanduser().resolve(strict=True)
            if app.suffix != '.app':
                parser.error('--app must point to an .app bundle')
            with (app / 'Contents/Info.plist').open('rb') as source:
                info = plistlib.load(source)
            if info.get('CFBundleShortVersionString') != version or str(info.get('CFBundleVersion')) != code:
                raise RuntimeError('signed app version does not match pubspec; rebuild and sign the current release')
            display_name = CHANNEL_APP_NAMES[args.channel]
            if (info.get('LvpaiUpdateChannel', args.channel) != args.channel
                    or info.get('CFBundleDisplayName') != display_name):
                raise RuntimeError('signed app name or channel does not match the requested release channel')
            run('codesign', '--verify', '--deep', '--strict', app)
            signature = subprocess.run(['codesign', '-dv', '--verbose=4', str(app)],
                                       check=True, capture_output=True, text=True)
            if 'Authority=Developer ID Application:' not in signature.stderr or 'runtime' not in signature.stderr:
                raise RuntimeError('app must have Developer ID Application signature and hardened runtime')
            arch = 'arm64' if args.platform == 'macos-arm64' else 'x86_64'
            runtime = app / 'Contents/Resources/print-runtime'
            require_bundle(runtime, windows=False)
            run('codesign', '--verify', '--strict', runtime / 'node')
            run('lipo', '-verify_arch', arch, app / 'Contents/MacOS' / info['CFBundleExecutable'])
            run('lipo', '-verify_arch', arch, runtime / 'node')
            content = staging / 'image'
            content.mkdir()
            shutil.copytree(app, content / f'{display_name}.app', symlinks=True)
            (content / 'Applications').symlink_to('/Applications')
            run('hdiutil', 'create', '-volname', display_name, '-srcfolder', content,
                '-format', 'UDZO', package)
            run('codesign', '--sign', args.sign_identity, '--timestamp', package)
            run('codesign', '--verify', '--strict', package)
            run('xcrun', 'notarytool', 'submit', package, '--keychain-profile', args.notary_profile, '--wait')
            run('xcrun', 'stapler', 'staple', package)
            run('xcrun', 'stapler', 'validate', package)
            run('spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', package)
        package.replace(destination)
        if setup:
            staged_setup.replace(setup)
            setup_info = write_release_info(directory / 'setup-release-info.json', setup,
                                            version=version, code=code, platform=args.platform,
                                            channel=args.channel, setup=True)
            setup.with_suffix('.exe.sha256').write_text(
                f'{setup_info["sha256"]}  {setup.name}\n', encoding='ascii')
            print(f'Local installer: {setup}')
    manifest = write_release_info(directory / 'release-info.json', destination,
                                  version=version, code=code, platform=args.platform, channel=args.channel)
    print(f'Local package: {destination}')
    print(json.dumps(manifest, indent=2))
    print('Package built locally. Publication is a separate step.')


def sign_windows(args, file):
    run(args.windows_sign_tool, 'sign', '/sha1', args.windows_sign_thumbprint,
        '/fd', 'SHA256', '/tr', 'http://timestamp.digicert.com', '/td', 'SHA256', file)
    run(args.windows_sign_tool, 'verify', '/pa', file)


if __name__ == '__main__':
    main()
