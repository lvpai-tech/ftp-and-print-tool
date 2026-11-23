"""Upload one verified Actions DMG using an object-scoped COS PUT URL."""

import base64
import hashlib
import os
import re
import sys
from http.client import HTTPSConnection
from pathlib import Path
from urllib.parse import urlsplit


def upload(directory: Path, url: str) -> None:
    dmg, = directory.glob("*-macos-arm64-personal.dmg")
    target = urlsplit(url)
    if (
        target.scheme != "https"
        or not re.fullmatch(r"[a-z0-9-]+\.cos\.[a-z0-9-]+\.(?:myqcloud\.com|tencentcos\.cn)", target.netloc)
        or not re.fullmatch(r"/ftp-client/test/macos-arm64/ci/[a-z0-9-]+/" + re.escape(dmg.name), target.path)
        or not target.query
        or target.fragment
    ):
        raise ValueError("Expected a scoped Tencent COS test upload URL")

    sha256 = hashlib.sha256()
    md5 = hashlib.md5(usedforsecurity=False)
    with dmg.open("rb") as body:
        for chunk in iter(lambda: body.read(1024 * 1024), b""):
            sha256.update(chunk)
            md5.update(chunk)
        expected = dmg.with_suffix(".dmg.sha256").read_text(encoding="utf-8").split()[0]
        if sha256.hexdigest() != expected:
            raise ValueError("DMG SHA-256 does not match the artifact checksum")

        headers = {
            "Content-Type": "application/octet-stream",
            "Content-Length": str(body.tell()),
            "Content-MD5": base64.b64encode(md5.digest()).decode("ascii"),
            "x-cos-forbid-overwrite": "true",
        }
        body.seek(0)
        connection = HTTPSConnection(target.netloc, timeout=180)
        try:
            connection.request("PUT", f"{target.path}?{target.query}", body=body, headers=headers)
            response = connection.getresponse()
            if response.status != 200:
                raise ValueError(f"COS upload returned HTTP {response.status}")
        finally:
            connection.close()

    print(f"Uploaded {target.path} ({headers['Content-Length']} bytes, SHA-256 {expected})")


if __name__ == "__main__":
    if len(sys.argv) != 2 or not os.environ.get("COS_SMOKE_PUT_URL"):
        sys.exit("Usage: set COS_SMOKE_PUT_URL and pass the Actions artifact directory")
    try:
        upload(Path(sys.argv[1]), os.environ["COS_SMOKE_PUT_URL"])
    except (OSError, ValueError) as error:
        message = str(error) if isinstance(error, ValueError) else type(error).__name__
        sys.exit(f"COS upload failed: {message}")
