"""Build the CI app with the core ONNX Runtime Swift package."""

import argparse
import json
from pathlib import Path
import re
import subprocess
from tempfile import TemporaryDirectory
from urllib.request import url2pathname


ORT_PACKAGE = "onnxruntime-swift-package-manager"
ORT_URL = f"https://github.com/masicai/{ORT_PACKAGE}"
ORT_VERSION = "1.28.0"
ORT_COMMIT = "3fb68950a5967c8c120f9f99a1a850a43985a4c9"


def core_manifest(manifest):
    # Xcode also resolves binary targets that the Flutter plugin does not use.
    # The extensions download endpoint has an invalid TLS certificate.
    manifest, extensions_branch, _ = manifest.partition(
        'if let ext_pod_archive_path = ProcessInfo.processInfo.environment'
    )
    if not extensions_branch:
        raise ValueError("Expected ONNX Runtime extensions binary block")

    for declaration in (
        r'library\(name: "onnxruntime_extensions",.*?\),',
        r'target\(name: "OnnxRuntimeExtensions",.*?\]\),',
        r'testTarget\(name: "OnnxRuntimeExtensionsTests",.*?\]\),',
    ):
        manifest, removed = re.subn(
            rf"(?m)^ +\.{declaration}\n", "", manifest, flags=re.DOTALL
        )
        if removed != 1:
            raise ValueError(f"Expected one ONNX Runtime extensions declaration: {declaration}")
    return manifest


def build(channel):
    package_config = Path(".dart_tool/package_config.json").resolve()
    packages = json.loads(package_config.read_text(encoding="utf-8"))["packages"]
    plugin_uri = next(pkg["rootUri"] for pkg in packages if pkg["name"] == "flutter_onnxruntime")
    if not plugin_uri.startswith("file:"):
        raise ValueError("Expected a hosted flutter_onnxruntime package")
    plugin_manifest = (
        Path(url2pathname(plugin_uri.removeprefix("file://")))
        / "macos/flutter_onnxruntime/Package.swift"
    )
    original = plugin_manifest.read_text(encoding="utf-8")
    upstream_dependency = f'.package(url: "{ORT_URL}", exact: "{ORT_VERSION}")'
    if original.count(upstream_dependency) != 1:
        raise ValueError("Flutter ONNX Runtime changed its Swift package dependency")

    with TemporaryDirectory(prefix="macos-ort-") as scratch:
        checkout = Path(scratch).resolve() / ORT_PACKAGE
        subprocess.run(
            ["git", "clone", "--depth", "1", "--branch", ORT_VERSION, ORT_URL, str(checkout)],
            check=True,
        )
        revision = subprocess.check_output(["git", "-C", checkout, "rev-parse", "HEAD"], text=True)
        if revision.strip() != ORT_COMMIT:
            raise ValueError("ONNX Runtime Swift package tag does not match the pinned commit")

        manifest = checkout / "Package.swift"
        manifest.write_text(core_manifest(manifest.read_text(encoding="utf-8")), encoding="utf-8")
        local_dependency = f'.package(path: {json.dumps(str(checkout), ensure_ascii=False)})'
        try:
            plugin_manifest.write_text(
                original.replace(upstream_dependency, local_dependency), encoding="utf-8"
            )
            subprocess.run(
                [
                    "flutter", "build", "macos", "--release", "--no-pub",
                    f"--dart-define=LVPAI_UPDATE_ENV={channel}",
                ],
                check=True,
            )
        finally:
            plugin_manifest.write_text(original, encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--channel", choices=("local", "test", "prd"), default="test")
    build(parser.parse_args().channel)
