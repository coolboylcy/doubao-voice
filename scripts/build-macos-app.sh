#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

command -v xcodegen >/dev/null 2>&1 || {
  echo "缺少 xcodegen：brew install xcodegen" >&2
  exit 1
}

LOCAL_BUILD_DIR="${LOCAL_BUILD_DIR:-build/Local}"
TEAM_ID="${DEVELOPMENT_TEAM:-KR7SB9VHJZ}"
LOCAL_CODE_SIGNING_IDENTITY="${LOCAL_CODE_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F '\"' '/Apple Development:/ {print $2; exit}')}"
if [[ -z "${LOCAL_CODE_SIGNING_IDENTITY}" ]]; then
  echo "找不到 Apple Development 证书，无法生成可授权全局快捷键的本地版本" >&2
  exit 1
fi
xcodegen generate --spec project.yml
HELPER_CODESIGN_IDENTITY="${LOCAL_CODE_SIGNING_IDENTITY}" INCLUDE_LOCAL_ASR=1 ./scripts/build-helper.sh
xcodebuild \
  -project DoubaoVoice.xcodeproj \
  -scheme DoubaoVoice \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "${LOCAL_BUILD_DIR}/DerivedData" \
  DEVELOPMENT_TEAM="${TEAM_ID}" \
  CODE_SIGN_IDENTITY="${LOCAL_CODE_SIGNING_IDENTITY}" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_ENTITLEMENTS=App/DoubaoVoice-local.entitlements \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) LOCAL_DISTRIBUTION' \
  build

mkdir -p dist
rm -rf "dist/Doubao Voice.app"
cp -R "${LOCAL_BUILD_DIR}/DerivedData/Build/Products/Release/Doubao Voice.app" dist/
xattr -cr "dist/Doubao Voice.app"
echo "已生成并使用开发者证书签名：dist/Doubao Voice.app"
