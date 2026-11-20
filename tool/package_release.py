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

APP = pathlib.Path(__file__).resolve().parents[1]


def run(*args):
    return subprocess.run([str(arg) for arg in args], cwd=APP, check=True,
                          capture_output=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', required=True,
                        choices=['windows-x64', 'macos-arm64', 'macos-x64'])
    parser.add_argument('--channel', required=True, choices=['local', 'test', 'prd'])
    parser.add_argument('--flutter', default='flutter')
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
    extension = '.zip' if windows else '.dmg'
    name = f'lvpai-ftp-{version}-{code}-{args.platform}{extension}'
    directory = APP / 'build' / 'releases' / args.channel / args.platform
    directory.mkdir(parents=True, exist_ok=True)
    destination = directory / name
    if destination.exists():
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
                f'--dart-define=LVPAI_UPDATE_ENV={args.channel}')
            release = APP / 'build/windows/x64/runner/Release'
            if not (release / 'lvpai_ftp_client.exe').is_file():
                raise RuntimeError('release EXE is missing')
            with zipfile.ZipFile(package, 'w', zipfile.ZIP_DEFLATED) as archive:
                for path in sorted(release.rglob('*')):
                    if path.is_symlink():
                        raise RuntimeError('unexpected symlink in Windows release')
                    if path.is_file() and path.suffix.lower() != '.pdb':
                        archive.write(path, path.relative_to(release).as_posix())
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
            run('codesign', '--verify', '--deep', '--strict', app)
            signature = subprocess.run(['codesign', '-dv', '--verbose=4', str(app)],
                                       check=True, capture_output=True, text=True)
            if 'Authority=Developer ID Application:' not in signature.stderr or 'runtime' not in signature.stderr:
                raise RuntimeError('app must have Developer ID Application signature and hardened runtime')
            run('lipo', '-verify_arch', 'arm64' if args.platform == 'macos-arm64' else 'x86_64',
                app / 'Contents/MacOS' / info['CFBundleExecutable'])
            content = staging / 'image'
            content.mkdir()
            shutil.copytree(app, content / app.name, symlinks=True)
            (content / 'Applications').symlink_to('/Applications')
            run('hdiutil', 'create', '-volname', '帧集快拍', '-srcfolder', content,
                '-format', 'UDZO', package)
            run('codesign', '--sign', args.sign_identity, '--timestamp', package)
            run('codesign', '--verify', '--strict', package)
            run('xcrun', 'notarytool', 'submit', package, '--keychain-profile', args.notary_profile, '--wait')
            run('xcrun', 'stapler', 'staple', package)
            run('xcrun', 'stapler', 'validate', package)
            run('spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', package)
        package.replace(destination)
    with destination.open('rb') as source:
        digest = hashlib.file_digest(source, 'sha256').hexdigest()
    manifest = {'versionCode': int(code), 'versionName': version, 'platform': args.platform,
                'channel': args.channel, 'sizeBytes': destination.stat().st_size, 'sha256': digest,
                'installerUrl': f'https://cdn.hilvpai.com/ftp-client/{args.channel}/{args.platform}/{name}'}
    (directory / 'release-info.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print(f'Local package: {destination}')
    print(json.dumps(manifest, indent=2))
    print('Not published. Use the administrator release page after testing this exact artifact.')


if __name__ == '__main__':
    main()
