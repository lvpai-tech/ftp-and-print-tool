"""Publish a signed desktop update to its test feed after uploading the package."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
from tempfile import TemporaryDirectory
import time
from urllib.request import Request, urlopen
from xml.etree import ElementTree as xml

ORIGIN = "https://cdn.hilvpai.com"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
MAX_PACKAGE_BYTES = 512 * 1024 * 1024


def package_metadata(package):
    match = re.fullmatch(
        r"lvpai-ftp-(\d+\.\d+\.\d+)-(\d+)-(windows-x64-setup\.exe|macos-arm64\.dmg)",
        package.name,
    )
    if not match:
        raise ValueError("Expected a versioned Windows Setup.exe or Apple silicon DMG")
    version, code_text, suffix = match.groups()
    code = int(code_text)
    size = package.stat().st_size
    if not (1 <= code <= 2_000_000_000 and 1 <= size <= MAX_PACKAGE_BYTES):
        raise ValueError("Package size or build number is outside the update protocol")
    windows = suffix.endswith(".exe")
    platform = "windows-x64" if windows else "macos-arm64"
    prefix = f"ftp-client/test/{platform}" + ("/setup" if windows else "")
    with package.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    return prefix, {
        "versionCode": code,
        "versionName": version,
        "platform": platform,
        "channel": "test",
        "installerUrl": f"{ORIGIN}/{prefix}/{package.name}",
        "sizeBytes": size,
        "sha256": digest,
    }


def sign(tool, file, secret, signature_only=False):
    command = [str(tool), "--ed-key-file", "-"]
    if signature_only:
        command.append("-p")
    return subprocess.run(
        [*command, str(file)], input=secret, text=True, check=True, capture_output=True
    ).stdout.strip()


def make_appcast(package, manifest, tool, public_key):
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

    public = Ed25519PublicKey.from_public_bytes(base64.b64decode(public_key, validate=True))
    secret = os.environ["SPARKLE_PRIVATE_KEY"]
    signature = sign(tool, package, secret, signature_only=True)
    public.verify(base64.b64decode(signature, validate=True), package.read_bytes())

    xml.register_namespace("sparkle", SPARKLE)
    rss = xml.Element("rss", version="2.0")
    channel = xml.SubElement(rss, "channel")
    xml.SubElement(channel, "title").text = "帧集快拍"
    item = xml.SubElement(channel, "item")
    xml.SubElement(item, "title").text = manifest["versionName"]
    for name, value in {
        "version": manifest["versionCode"],
        "shortVersionString": manifest["versionName"],
        "minimumSystemVersion": "14.0",
        "hardwareRequirements": "arm64",
    }.items():
        xml.SubElement(item, f"{{{SPARKLE}}}{name}").text = str(value)
    xml.SubElement(item, "enclosure", {
        "url": manifest["installerUrl"],
        "length": str(manifest["sizeBytes"]),
        "type": "application/octet-stream",
        f"{{{SPARKLE}}}edSignature": signature,
    })
    xml.indent(rss)
    with TemporaryDirectory() as scratch:
        feed = Path(scratch) / "appcast.xml"
        xml.ElementTree(rss).write(feed, encoding="utf-8", xml_declaration=True)
        sign(tool, feed, secret)
        return feed.read_bytes()


def read_current(client, bucket, key, appcast):
    from qcloud_cos import CosServiceError

    try:
        response = client.get_object(Bucket=bucket, Key=key)
    except CosServiceError as error:
        if str(error.get_status_code()) == "404":
            return None, None
        raise
    stream = response["Body"].get_raw_stream()
    try:
        body = stream.read(65537)
    finally:
        stream.close()
    if len(body) > 65536:
        raise ValueError("Existing update feed exceeds the expected size")
    if appcast:
        versions = xml.fromstring(body).findall(f"./channel/item/{{{SPARKLE}}}version")
        code = max(int(version.text) for version in versions)
    else:
        code = json.loads(body)["versionCode"]
    if type(code) is not int or not 1 <= code <= 2_000_000_000:
        raise ValueError("Existing update feed has an invalid build number")
    return code, body


def upload_package(client, bucket, key, package, manifest):
    from qcloud_cos import CosServiceError

    try:
        with package.open("rb") as source:
            client.put_object(
                Bucket=bucket, Key=key, Body=source, EnableMD5=True,
                ForbidOverwrite="true", ContentType="application/octet-stream",
                CacheControl="public,max-age=31536000,immutable",
                Metadata={"x-cos-meta-sha256": manifest["sha256"]},
            )
    except CosServiceError as error:
        if str(error.get_status_code()) != "409":
            raise
    headers = {name.lower(): value for name, value in
               client.head_object(Bucket=bucket, Key=key).items()}
    if (int(headers["content-length"]) != manifest["sizeBytes"]
            or headers.get("x-cos-meta-sha256") != manifest["sha256"]):
        raise ValueError("An immutable object already exists with different bytes")


def check_cdn(url, expected):
    for attempt in range(6):
        try:
            request = Request(url, headers={"Cache-Control": "no-cache"},
                              method="HEAD" if isinstance(expected, int) else "GET")
            with urlopen(request, timeout=15) as response:
                actual = (response.headers.get("Content-Length")
                          if isinstance(expected, int) else response.read(65537))
                if response.geturl() == url and actual == (
                        str(expected) if isinstance(expected, int) else expected):
                    return
        except OSError:
            pass
        if attempt < 5:
            time.sleep(5)
    raise RuntimeError(f"CDN readback did not match {url}")


def main():
    from qcloud_cos import CosConfig, CosS3Client

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("--sparkle-sign-tool", type=Path)
    args = parser.parse_args()
    prefix, manifest = package_metadata(args.package)
    appcast = manifest["platform"] == "macos-arm64"
    if appcast != (args.sparkle_sign_tool is not None):
        parser.error("macOS publication requires the Sparkle signing tool")
    feed_key = f"{prefix}/" + ("appcast.xml" if appcast else "latest.json")
    client = CosS3Client(CosConfig(
        Region=os.environ["COS_REGION"],
        SecretId=os.environ["COS_SECRET_ID"],
        SecretKey=os.environ["COS_SECRET_KEY"],
        Scheme="https",
    ))
    bucket = os.environ["COS_BUCKET"]
    previous, previous_body = read_current(client, bucket, feed_key, appcast)
    code = manifest["versionCode"]
    body = (make_appcast(args.package, manifest, args.sparkle_sign_tool,
                         os.environ["SPARKLE_PUBLIC_KEY"])
            if appcast else (json.dumps(manifest, indent=2) + "\n").encode())
    if previous is not None and (previous > code or (previous == code and previous_body != body)):
        raise ValueError("The release must have a higher build number than the current feed")

    upload_package(client, bucket, f"{prefix}/{args.package.name}", args.package, manifest)
    check_cdn(manifest["installerUrl"], manifest["sizeBytes"])
    if previous != code:
        client.put_object(
            Bucket=bucket, Key=feed_key, Body=body, EnableMD5=True,
            ContentType="application/rss+xml" if appcast else "application/json",
            CacheControl="no-cache,max-age=0",
        )
    check_cdn(f"{ORIGIN}/{feed_key}", body)
    print(f"Published and verified {ORIGIN}/{feed_key} at build {code}")


if __name__ == "__main__":
    main()
