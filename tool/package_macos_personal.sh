#!/usr/bin/env bash
# 个人跨机用 macOS 包：临时签名、随包打印内核、.command 启动器。
# 不做 Developer ID / 公证。其他 Mac 首次需右键打开或「仍要打开」。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT/build/macos/Build/Products/Release/lvpai_ftp_client.app}"
CHANNEL="${LVPAI_UPDATE_ENV:-test}"
case "$CHANNEL" in
  local) APP_NAME='帧集快拍（本地版）' ;;
  test) APP_NAME='帧集快拍（测试版）' ;;
  prd) APP_NAME='帧集快拍' ;;
  *) echo 'Invalid update channel' >&2; exit 2 ;;
esac
NODE_VERSION="${LVPAI_PRINT_NODE_VERSION:-v20.18.1}"
DIST_NAME="${DIST_NAME:-lvpai-ftp-macos-personal}"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "必须在 macOS 上打包" >&2
  exit 1
fi
if [[ ! -d "$APP_PATH" ]]; then
  echo "找不到应用：$APP_PATH" >&2
  exit 1
fi
ARCH="$(uname -m)"
case "$ARCH" in
  arm64) NODE_ARCH=arm64 ;;
  x86_64) NODE_ARCH=x64 ;;
  *) echo "不支持的架构：$ARCH" >&2; exit 1 ;;
esac

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lvpai-macos-personal.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

STAGE="$WORK/$DIST_NAME"
mkdir -p "$STAGE"
ditto "$APP_PATH" "$STAGE/lvpai_ftp_client.app"
APP="$STAGE/lvpai_ftp_client.app"
INFO="$APP/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "$APP_NAME" "$INFO"
plutil -replace CFBundleName -string "$APP_NAME" "$INFO"
plutil -insert LvpaiUpdateChannel -string "$CHANNEL" "$INFO"
plutil -insert LvpaiUnsandboxedDistribution -bool YES "$INFO"
test -x "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
RUNTIME="$APP/Contents/Resources/print-runtime"
NODE_TGZ="$WORK/node.tar.gz"
NODE_URL="https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-darwin-${NODE_ARCH}.tar.gz"
echo "下载 Node ${NODE_VERSION} (${NODE_ARCH})…"
curl -fsSL "$NODE_URL" -o "$NODE_TGZ"
mkdir -p "$WORK/node"
tar -xzf "$NODE_TGZ" -C "$WORK/node" --strip-components=1
python3 "$ROOT/tool/bundle_print_runtime.py" --destination "$RUNTIME" \
  --node "$WORK/node/bin/node" --node-license "$WORK/node/LICENSE"

# 个人包：临时签名，不带 App Sandbox，避免无开发证书时无法启动。
find "$APP/Contents/Frameworks" -name '*.framework' -maxdepth 1 -print0 2>/dev/null \
  | while IFS= read -r -d '' framework; do
      codesign --force --sign - --timestamp=none "$framework"
    done
codesign --force --sign - --timestamp=none "$RUNTIME/node"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

# 启动器：清隔离属性后打开应用。首次仍可能需右键「打开」。
cat > "$STAGE/打开旅派客户端.command" <<'EOF'
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="./lvpai_ftp_client.app"
if [[ ! -d "$APP" ]]; then
  osascript -e 'display alert "找不到 lvpai_ftp_client.app" message "请保持本启动器与应用在同一文件夹。" as critical' >/dev/null 2>&1 || true
  exit 1
fi
xattr -cr "$APP" 2>/dev/null || true
xattr -cr . 2>/dev/null || true
open "$APP"
EOF
chmod 755 "$STAGE/打开旅派客户端.command"

# 写入包内说明，避免误当正式公证包。
cat > "$STAGE/使用说明.txt" <<EOF
${APP_NAME} · macOS 个人包（${CHANNEL}）
架构：${ARCH}
Node：${NODE_VERSION}

1. 解压整个文件夹，不要只抽出 .app。
2. 第一次：右键「打开旅派客户端.command」，或选「仍要打开」。
3. 之后可双击该 .command，或直接打开 lvpai_ftp_client.app。
4. 本包为临时签名，未做 Apple 公证，仅供个人跨机使用。
5. 打印内核已随包；正式对外分发仍须按 RELEASING.md 签名公证。
EOF

mkdir -p "$OUT_DIR"
ZIP="$OUT_DIR/${DIST_NAME}.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$ZIP"
shasum -a 256 "$ZIP" | tee "$OUT_DIR/${DIST_NAME}.sha256"
echo "包已生成：$ZIP"
echo "通道：${CHANNEL}"
