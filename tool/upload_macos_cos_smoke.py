"""Test COS upload of a verified Actions DMG and its checksum."""

import base64
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlsplit


def put_file(path: Path, url: str, timeout: int) -> None:
    target = urlsplit(url)
    if (
        target.scheme != "https"
        or not re.fullmatch(r"[a-z0-9-]+\.cos\.[a-z0-9-]+\.(?:myqcloud\.com|tencentcos\.cn)", target.netloc)
        or not re.fullmatch(r"/ftp-client/test/macos-arm64/ci/[a-z0-9-]+/" + re.escape(path.name), target.path)
        or not target.query
        or not re.fullmatch(r"[a-zA-Z0-9%&=._;~-]+", target.query)
        or target.fragment
    ):
        raise ValueError("Expected a scoped Tencent COS test upload URL")

    with path.open("rb") as body:
        digest = hashlib.file_digest(body, lambda: hashlib.md5(usedforsecurity=False))
    md5 = base64.b64encode(digest.digest()).decode("ascii")
    size = path.stat().st_size
    print(f"Uploading {path.name} ({size} bytes)", flush=True)
    result = subprocess.run(
        [
            "curl", "--disable", "--config", "-", "--silent", "--output", "/dev/null",
            "--connect-timeout", "20", "--max-time", str(timeout),
            "--speed-limit", "1024", "--speed-time", "30", "--expect100-timeout", "5",
            "--header", "Expect: 100-continue", "--header", "Content-Type: application/octet-stream",
            "--header", f"Content-Length: {size}", "--header", f"Content-MD5: {md5}",
            "--header", "x-cos-forbid-overwrite: true", "--upload-file", str(path),
            "--write-out", "%{http_code} %{size_upload} %{time_total}",
        ],
        input=f'url = "{url}"\n', text=True, capture_output=True, check=False,
    )
    metrics = result.stdout.strip()
    if not re.fullmatch(r"[0-9]{3} [0-9]+ [0-9.]+", metrics):
        raise ValueError(f"COS transport failed for {path.name} (curl exit {result.returncode})")
    status, uploaded, seconds = metrics.split()
    print(f"{path.name}: HTTP {status}, sent {uploaded} bytes in {seconds}s", flush=True)
    if result.returncode or status != "200" or int(uploaded) != size:
        raise ValueError(f"COS upload failed for {path.name} (curl exit {result.returncode})")


def upload(directory: Path, urls: dict[str, str]) -> None:
    dmg, = directory.glob("*-macos-arm64-personal.dmg")
    checksum = dmg.with_suffix(".dmg.sha256")
    expected = checksum.read_text(encoding="utf-8").split()[0]
    with dmg.open("rb") as body:
        if hashlib.file_digest(body, "sha256").hexdigest() != expected:
            raise ValueError("DMG SHA-256 does not match the artifact checksum")

    put_file(checksum, urls["checksum"], timeout=50)
    put_file(dmg, urls["dmg"], timeout=480)
    print(f"Verified artifact SHA-256 {expected}")


if __name__ == "__main__":
    if len(sys.argv) != 2 or not os.environ.get("COS_SMOKE_PUT_URL"):
        sys.exit("Usage: set COS_SMOKE_PUT_URL and pass the Actions artifact directory")
    try:
        urls = json.loads(os.environ["COS_SMOKE_PUT_URL"])
    except json.JSONDecodeError:
        sys.exit("Expected JSON with presigned URLs for the checksum and DMG")
    if not isinstance(urls, dict) or not all(isinstance(urls.get(key), str) for key in ("checksum", "dmg")):
        sys.exit("Missing presigned URL for the checksum or DMG")
    try:
        upload(Path(sys.argv[1]), urls)
    except (OSError, ValueError) as error:
        message = str(error) if isinstance(error, ValueError) else type(error).__name__
        sys.exit(f"COS upload failed: {message}")
