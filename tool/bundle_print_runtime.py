"""把正式打印内核加入统一客户端；不读取本机业务配置，不发布或打印。"""
import argparse
from pathlib import Path
import shutil
import subprocess


def bundle(destination, node=None, license_file=None):
    source = Path(__file__).resolve().parents[2] / 'print-desktop'
    executable = Path(node or shutil.which('node') or '')
    if not executable.is_file():
        raise RuntimeError('缺少Node可执行文件')
    version = subprocess.check_output([str(executable), '--version'], text=True).strip()
    if int(version.lstrip('v').split('.')[0]) < 20:
        raise RuntimeError('打印内核需要Node20及以上')
    candidates = [Path(license_file)] if license_file else [
        executable.parent / 'LICENSE',
        executable.parent.parent / 'installs' / version / 'LICENSE',
    ]
    license_path = next((file for file in candidates if file.is_file()), None)
    if license_path is None:
        raise RuntimeError('缺少Node许可证，请传入--node-license')
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    (destination / 'src').mkdir(exist_ok=True)
    (destination / 'scripts').mkdir(exist_ok=True)
    for file in (source / 'src').iterdir():
        if file.is_file():
            shutil.copy2(file, destination / 'src' / file.name)
    for name in ('print-image.ps1', 'printer-status.ps1', 'print-image-mac.sh'):
        shutil.copy2(source / 'scripts' / name, destination / 'scripts' / name)
    for name in ('config.example.json', 'config.mac.example.json'):
        shutil.copy2(source / name, destination / name)
    name = 'node.exe' if executable.suffix.lower() == '.exe' else 'node'
    shutil.copy2(executable, destination / name)
    (destination / name).chmod(0o755)
    shutil.copy2(license_path, destination / 'NODE-LICENSE.txt')
    print(f'已加入打印内核 {version}: {destination}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', required=True)
    parser.add_argument('--node')
    parser.add_argument('--node-license')
    args = parser.parse_args()
    bundle(args.destination, args.node, args.node_license)
