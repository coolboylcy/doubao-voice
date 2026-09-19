#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

APP="dist/Doubao Voice.app"
DMG="dist/Doubao Voice 0.2.0.dmg"
EXPECTED_TRANSCRIPT="今天天气不错，我正在测试豆包语音识别。"

for command in uv lua luacheck xcodebuild hdiutil codesign; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "缺少验收工具：$command" >&2
    exit 1
  }
done

test -d "$APP" || { echo "缺少 $APP，请先运行 scripts/build-macos-app.sh" >&2; exit 1; }
test -f "$DMG" || { echo "缺少 $DMG，请先运行 scripts/make-dmg.sh" >&2; exit 1; }

echo "[1/8] Python 测试与静态检查"
uv run pytest -q
uv run --with ruff ruff check src tests packaging

echo "[2/8] Lua 状态机与静态检查"
lua tests/state_test.lua
luacheck lua tests/state_test.lua

echo "[3/8] Swift 单元测试与原生 UI 测试"
xcodebuild -quiet \
  -project DoubaoVoice.xcodeproj \
  -scheme DoubaoVoice \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build/ReleaseVerification \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) LOCAL_DISTRIBUTION' \
  test

echo "[4/8] 属性列表与工作区差异检查"
while IFS= read -r plist; do
  plutil -lint "$plist"
done < <(find App packaging -type f -name '*.plist' -print | sort)
git diff --check

echo "[5/8] App 深层签名与必要资源"
codesign --verify --deep --strict --verbose=2 "$APP"
test -x "$APP/Contents/Helpers/dbvoice"
test -x "$APP/Contents/Resources/funasr/bin/llama-funasr-sensevoice"
test -f "$APP/Contents/Resources/funasr/gguf/sensevoice-small-q8.gguf"
test -f "$APP/Contents/Resources/funasr/gguf/fsmn-vad.gguf"

echo "[6/8] DMG 校验"
hdiutil verify "$DMG"

mount_dir="$(mktemp -d /tmp/doubao-voice-release-verify.XXXXXX)"
mounted=0
cleanup() {
  if [[ "$mounted" == 1 ]]; then
    hdiutil detach "$mount_dir" >/dev/null 2>&1 || true
  fi
  rmdir "$mount_dir" 2>/dev/null || true
}
trap cleanup EXIT

echo "[7/8] 从只读 DMG 反向检查 App"
hdiutil attach -readonly -nobrowse -mountpoint "$mount_dir" "$DMG" >/dev/null
mounted=1
mounted_app="$mount_dir/Doubao Voice.app"
codesign --verify --deep --strict --verbose=2 "$mounted_app"
test -L "$mount_dir/Applications"
test -x "$mounted_app/Contents/Helpers/dbvoice"

echo "[8/8] 直接运行 DMG 内离线模型"
transcript="$(
  "$mounted_app/Contents/Resources/funasr/bin/llama-funasr-sensevoice" \
    -m "$mounted_app/Contents/Resources/funasr/gguf/sensevoice-small-q8.gguf" \
    --vad "$mounted_app/Contents/Resources/funasr/gguf/fsmn-vad.gguf" \
    -a tests/fixtures/hello.wav
)"
if [[ "$transcript" != "$EXPECTED_TRANSCRIPT" ]]; then
  echo "离线识别结果不符：$transcript" >&2
  exit 1
fi

hdiutil detach "$mount_dir" >/dev/null
mounted=0
rmdir "$mount_dir"
trap - EXIT

echo "发布验收全部通过"
shasum -a 256 "$DMG"
