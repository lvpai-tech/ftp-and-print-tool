"""Bundle the workstation print runtime from this checkout."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys

SOURCE = Path(__file__).resolve().parents[1] / 'print-runtime'
BRIDGE = Path('src/flutter-bridge.cjs')


def runtime_files(windows):
    files = [file.relative_to(SOURCE) for file in sorted((SOURCE / 'src').iterdir())
             if file.is_file() and file.suffix in ('.js', '.cjs')]
    if BRIDGE not in files:
        raise RuntimeError(f'Print bridge not found: {SOURCE / BRIDGE}')
    if windows:
        return files + [Path('scripts/print-image.ps1'), Path('scripts/printer-status.ps1'),
                        Path('config.example.json')]
    return files + [Path('scripts/print-image-mac.sh'), Path('config.mac.example.json')]


def require_bundle(destination, windows):
    node_name = 'node.exe' if windows else 'node'
    for file in [*runtime_files(windows), Path(node_name), Path('NODE-LICENSE.txt')]:
        if not (destination / file).is_file():
            raise RuntimeError(f'Incomplete print runtime: missing {destination / file}')
    if (destination / 'config.json').exists() or (destination / '.runtime').exists():
        raise RuntimeError(f'Print runtime contains local configuration or state: {destination}')


def bundle(destination, node=None, license_file=None):
    windows = sys.platform == 'win32'
    executable = Path(node).expanduser() if node else Path(shutil.which('node') or '')
    if not executable.is_file():
        raise RuntimeError('缺少Node可执行文件')
    node_info = json.loads(subprocess.check_output([
        str(executable.resolve()), '-p',
        'JSON.stringify({executable:process.execPath,version:process.version,arch:process.arch})',
    ], encoding='utf-8'))
    executable = Path(node_info['executable']).resolve(strict=True)
    if windows and node_info['arch'] != 'x64':
        raise RuntimeError('Windows x64 工作台需要 x64 Node')
    version = node_info['version']
    if int(version.lstrip('v').split('.')[0]) < 20:
        raise RuntimeError('打印内核需要Node20及以上')
    candidates = [Path(license_file)] if license_file else [
        executable.parent / 'LICENSE',
        executable.parent.parent / 'LICENSE',
        executable.parent.parent / 'installs' / version / 'LICENSE',
    ]
    license_path = next((file for file in candidates if file.is_file()), None)
    if license_path is None:
        raise RuntimeError('缺少Node许可证，请传入--node-license')
    destination = Path(destination)
    for file in runtime_files(windows):
        target = destination / file
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(SOURCE / file, target)
    if not windows:
        (destination / 'scripts/print-image-mac.sh').chmod(0o755)
    bundled_node = destination / ('node.exe' if windows else 'node')
    shutil.copy2(executable, bundled_node)
    bundled_node.chmod(0o755)
    shutil.copy2(license_path, destination / 'NODE-LICENSE.txt')
    require_bundle(destination, windows)
    loaded_from = subprocess.check_output([
        str(bundled_node.resolve()), '-e', 'require(process.argv[1]); console.log(JSON.stringify(process.execPath))',
        str((destination / BRIDGE).resolve()),
    ], encoding='utf-8')
    if Path(json.loads(loaded_from)).resolve() != bundled_node.resolve():
        raise RuntimeError(f'Bundled Node resolves to an external executable: {bundled_node}')
    print(f'已加入打印内核 {version}: {destination}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', required=True)
    parser.add_argument('--node')
    parser.add_argument('--node-license')
    args = parser.parse_args()
    bundle(args.destination, args.node, args.node_license)
