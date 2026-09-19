#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

if [[ -z "${APP_PATH:-}" ]]; then
  if [[ -d "dist/Voice Doggo.app" ]]; then
    APP_PATH="dist/Voice Doggo.app"
  else
    APP_PATH="build/AppStore-final.xcarchive/Products/Applications/Voice Doggo.app"
  fi
fi
OUTPUT_PATH="${OUTPUT_PATH:-dist/Voice Doggo 0.2.0.dmg}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "找不到 App：$APP_PATH" >&2
  echo "请先执行归档，或用 APP_PATH 指向已有的 .app" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"
STAGING_DIR="$(mktemp -d /tmp/voice-doggo-dmg.XXXXXX)"
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$APP_PATH" "$STAGING_DIR/Voice Doggo.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "Voice Doggo" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$OUTPUT_PATH"

echo "已生成安装镜像：$OUTPUT_PATH"
