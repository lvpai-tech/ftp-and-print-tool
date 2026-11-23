"""Upload a verified Actions DMG using object-scoped COS multipart URLs."""

import base64
import hashlib
import json
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from tempfile import TemporaryDirectory
from urllib.parse import parse_qs, urlsplit
from xml.etree import ElementTree

PART_SIZE = 2 * 1024 * 1024
WORKERS = 24
MAX_PARTS = 80
COMPLETE_HEADERS = {"Content-Type": "application/xml", "x-cos-forbid-overwrite": "true"}


def validate_url(url: str, name: str, upload_id: str, part_number: int | None = None):
    target = urlsplit(url)
    query = parse_qs(target.query)
    if (
        target.scheme != "https"
        or not re.fullmatch(r"[a-z0-9-]+\.cos\.[a-z0-9-]+\.(?:myqcloud\.com|tencentcos\.cn)", target.netloc)
        or not re.fullmatch(r"/ftp-client/test/macos-arm64/ci/[a-z0-9-]+/" + re.escape(name), target.path)
        or not re.fullmatch(r"[a-zA-Z0-9%&=._;~+-]+", target.query)
        or target.fragment
        or query.get("uploadId") != [upload_id]
        or query.get("partNumber") != ([str(part_number)] if part_number else None)
        or not query.get("q-signature")
    ):
        raise ValueError("Expected a COS URL scoped to this test object and multipart upload")
    return target.netloc, target.path


def part_headers(data: bytes) -> dict[str, str]:
    digest = hashlib.md5(data, usedforsecurity=False).digest()
    return {
        "Content-Type": "application/octet-stream",
        "Content-Length": str(len(data)),
        "Content-MD5": base64.b64encode(digest).decode("ascii"),
    }


def prepare_plan(client, bucket: str, key: str, dmg: Path) -> dict:
    """Create a short-lived plan using a COS SDK client on the trusted machine."""
    if not re.fullmatch(r"ftp-client/test/macos-arm64/ci/[a-z0-9-]+/" + re.escape(dmg.name), key):
        raise ValueError("Expected a new CI archive key for the DMG")
    count = (dmg.stat().st_size + PART_SIZE - 1) // PART_SIZE
    if not 1 <= count <= MAX_PARTS:
        raise ValueError("DMG size is outside the supported multipart test range")
    sha256 = hashlib.sha256()
    upload_id = client.create_multipart_upload(
        Bucket=bucket, Key=key, ContentType="application/octet-stream", ForbidOverwrite="true"
    )["UploadId"]
    try:
        def sign(method, params, headers):
            return client.get_presigned_url(
                Bucket=bucket, Key=key, Method=method, Expired=1800, Params=params, Headers=headers
            )

        parts = []
        with dmg.open("rb") as body:
            for number in range(1, count + 1):
                data = body.read(PART_SIZE)
                sha256.update(data)
                url = sign("PUT", {"uploadId": upload_id, "partNumber": number}, part_headers(data))
                validate_url(url, dmg.name, upload_id, number)
                parts.append(url)
        complete = sign("POST", {"uploadId": upload_id}, {**COMPLETE_HEADERS, "x-cos-pnum-max": str(count)})
        validate_url(complete, dmg.name, upload_id)
        return {"upload_id": upload_id, "sha256": sha256.hexdigest(), "parts": parts, "complete": complete}
    except Exception:
        client.abort_multipart_upload(Bucket=bucket, Key=key, UploadId=upload_id)
        raise


def curl_upload(url: str, path: Path, method: str, headers: dict[str, str], timeout: int, response_body: str):
    command = [
        "curl", "--disable", "--config", "-", "--silent", "--output", response_body,
        "--request", method, "--connect-timeout", "20", "--max-time", str(timeout),
        "--speed-limit", "1024", "--speed-time", "30", "--upload-file", str(path),
        "--write-out", "%{http_code} %{size_upload} %{time_total}\n%{header_json}",
    ]
    for key, value in headers.items():
        command.extend(("--header", f"{key}: {value}"))
    result = subprocess.run(command, input=f'url = "{url}"\n', text=True, capture_output=True, check=False)
    metrics, _, response_headers = result.stdout.partition("\n")
    if not re.fullmatch(r"[0-9]{3} [0-9]+ [0-9.]+", metrics):
        raise ValueError(f"COS transport failed (curl exit {result.returncode})")
    status, uploaded, seconds = metrics.split()
    return result.returncode, int(status), int(uploaded), seconds, response_headers


def upload_part(path: Path, url: str, number: int) -> tuple[int, str]:
    headers = part_headers(path.read_bytes())
    for attempt in (1, 2):
        code, status, uploaded, seconds, response_headers = curl_upload(
            url, path, "PUT", headers, timeout=130, response_body=os.devnull
        )
        print(f"Part {number} attempt {attempt}: HTTP {status}, sent {uploaded} bytes in {seconds}s", flush=True)
        if (code, status, uploaded) == (0, 200, int(headers["Content-Length"])):
            etags = json.loads(response_headers).get("etag", [])
            if len(etags) != 1 or not re.fullmatch(r'"[0-9a-fA-F]{32}"', etags[0]):
                raise ValueError(f"COS returned no valid ETag for part {number}")
            return number, etags[0]
        if code not in (7, 18, 28, 52, 55, 56) and status not in (408, 429, 500, 502, 503, 504):
            break
    raise ValueError(f"COS rejected or timed out uploading part {number} (curl exit {code}, HTTP {status})")


def complete_upload(directory: Path, url: str, etags: list[tuple[int, str]]) -> None:
    document = ElementTree.Element("CompleteMultipartUpload")
    for number, etag in sorted(etags):
        part = ElementTree.SubElement(document, "Part")
        ElementTree.SubElement(part, "PartNumber").text = str(number)
        ElementTree.SubElement(part, "ETag").text = etag

    manifest = directory / "complete.xml"
    manifest.write_bytes(ElementTree.tostring(document))
    response = directory / "complete-response.xml"
    headers = {**COMPLETE_HEADERS, "x-cos-pnum-max": str(len(etags))}
    code, status, _, seconds, _ = curl_upload(url, manifest, "POST", headers, 100, str(response))
    print(f"COS multipart completion: HTTP {status} in {seconds}s", flush=True)
    if code or status != 200:
        raise ValueError(f"COS multipart completion failed (curl exit {code}, HTTP {status})")
    document = ElementTree.fromstring(response.read_bytes().lstrip())
    if document.tag.rsplit("}", 1)[-1] != "CompleteMultipartUploadResult":
        raise ValueError("COS did not confirm that it assembled the DMG")


def upload(directory: Path, plan: dict) -> None:
    dmg, = directory.glob("*-macos-arm64-personal.dmg")
    expected = dmg.with_suffix(".dmg.sha256").read_text(encoding="utf-8").split()[0]
    with dmg.open("rb") as body:
        if hashlib.file_digest(body, "sha256").hexdigest() != expected or plan.get("sha256") != expected:
            raise ValueError("DMG SHA-256 does not match the artifact checksum and signed upload plan")

    size = dmg.stat().st_size
    count = (size + PART_SIZE - 1) // PART_SIZE
    if not 1 <= count <= MAX_PARTS or not isinstance(plan.get("parts"), list) or len(plan["parts"]) != count:
        raise ValueError("The COS upload plan does not match the number of DMG parts")
    if not isinstance(plan.get("upload_id"), str) or not plan["upload_id"]:
        raise ValueError("The COS upload plan lacks the multipart upload ID")
    destination = validate_url(plan["complete"], dmg.name, plan["upload_id"])
    for number, url in enumerate(plan["parts"], start=1):
        if validate_url(url, dmg.name, plan["upload_id"], number) != destination:
            raise ValueError("The COS upload plan references more than one destination")
    print(f"Uploading {size} bytes in {count} parts with up to {WORKERS} parallel requests", flush=True)
    with TemporaryDirectory() as temporary:
        staging = Path(temporary)
        with dmg.open("rb") as body, ThreadPoolExecutor(max_workers=WORKERS) as executor:
            pending = []
            for number, url in enumerate(plan["parts"], start=1):
                part = staging / f"part-{number}"
                part.write_bytes(body.read(PART_SIZE))
                pending.append(executor.submit(upload_part, part, url, number))
            try:
                etags = [task.result() for task in as_completed(pending)]
            except Exception:
                for task in pending:
                    task.cancel()
                raise
        complete_upload(staging, plan["complete"], etags)
    print(f"Uploaded {destination[1]} ({size} bytes, SHA-256 {expected})")


if __name__ == "__main__":
    if len(sys.argv) != 2 or not os.environ.get("COS_SMOKE_PUT_URL"):
        sys.exit("Usage: set COS_SMOKE_PUT_URL to the multipart plan and pass the Actions artifact directory")
    try:
        plan = json.loads(os.environ["COS_SMOKE_PUT_URL"])
        if not isinstance(plan, dict) or not isinstance(plan.get("complete"), str):
            raise ValueError("Invalid COS multipart upload plan")
        upload(Path(sys.argv[1]), plan)
    except (json.JSONDecodeError, ElementTree.ParseError, OSError, TypeError) as error:
        sys.exit(f"COS upload failed: {type(error).__name__}")
    except ValueError as error:
        sys.exit(f"COS upload failed: {error}")
