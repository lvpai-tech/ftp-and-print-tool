#!/usr/bin/env bash
set -euo pipefail

archive="$1"
channel="${2:?Update channel required (local, test or prd)}"
case "$channel" in local|test|prd) ;; *) echo 'Invalid update channel' >&2; exit 2 ;; esac
: "${MACOS_SIGN_IDENTITY:?Developer ID Application identity required}"
: "${SPARKLE_PUBLIC_KEY:?Sparkle public key required}"
: "${MACOS_NOTARY_PROFILE:?notarytool keychain profile required}"
root="$(cd "$(dirname "$0")/.." && pwd)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
ditto -x -k "$archive" "$stage"
app="$stage/lvpai-ftp-macos-personal/lvpai_ftp_client.app"
frameworks="$app/Contents/Frameworks"
sparkle="$frameworks/Sparkle.framework/Versions/B"
test -x "$sparkle/Autoupdate"
test -d "$sparkle/Updater.app"

python3 - "$app/Contents/Info.plist" "$channel" <<'PY'
import base64
import os
from pathlib import Path
import plistlib
import sys

file = Path(sys.argv[1])
info = plistlib.loads(file.read_bytes())
if info.get("LvpaiUpdateChannel") != sys.argv[2]:
    raise ValueError("The macOS app was packaged for a different update channel")
key = os.environ["SPARKLE_PUBLIC_KEY"]
if len(base64.b64decode(key, validate=True)) != 32:
    raise ValueError("Invalid Sparkle public key")
info["SUPublicEDKey"] = key
info["SURequireSignedFeed"] = True
info["SUVerifyUpdateBeforeExtraction"] = True
file.write_bytes(plistlib.dumps(info))
PY

sign=(codesign --force --sign "$MACOS_SIGN_IDENTITY" --options runtime --timestamp)
for service in "$sparkle"/XPCServices/*.xpc; do
    "${sign[@]}" --preserve-metadata=entitlements "$service"
done
"${sign[@]}" "$sparkle/Autoupdate"
"${sign[@]}" "$sparkle/Updater.app"
for framework in "$frameworks"/*.framework; do
    "${sign[@]}" "$framework"
done
cat > "$stage/node-entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>com.apple.security.cs.allow-jit</key><true/>
</dict></plist>
PLIST
node="$app/Contents/Resources/print-runtime/node"
"${sign[@]}" --entitlements "$stage/node-entitlements.plist" "$node"
"$node" --version
# Keep the same sandbox mode as the existing personal DMG and its data paths.
"${sign[@]}" "$app"
codesign --verify --deep --strict "$app"

python3 "$root/tool/package_release.py" --platform macos-arm64 --channel "$channel" --app "$app" --sign-identity "$MACOS_SIGN_IDENTITY" --notary-profile "$MACOS_NOTARY_PROFILE"
