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
  -project VoiceDoggo.xcodeproj \
  -scheme VoiceDoggo \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "${LOCAL_BUILD_DIR}/DerivedData" \
  DEVELOPMENT_TEAM="${TEAM_ID}" \
  CODE_SIGN_IDENTITY="${LOCAL_CODE_SIGNING_IDENTITY}" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_ENTITLEMENTS=App/VoiceDoggo-local.entitlements \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) LOCAL_DISTRIBUTION' \
  build

mkdir -p dist
rm -rf "dist/Voice Doggo.app"
cp -R "${LOCAL_BUILD_DIR}/DerivedData/Build/Products/Release/Voice Doggo.app" dist/
xattr -cr "dist/Voice Doggo.app"

# 最后把 App 本体重签一次，让资源封印按最终内容重新计算。
#
# Xcode 会给 Resources/ 下未经它签名的可执行文件补签，而那发生在封印算完
# 之后——llama-funasr-sensevoice 被改写，App 签名随即失效：
#   a sealed resource is missing or invalid
# 在 build-helper.sh 里先签好也挡不住（Xcode 照样重签，签名体积都变了）。
# 与其跟它的内部顺序较劲，不如在最后统一收口。
codesign --force --sign "${LOCAL_CODE_SIGNING_IDENTITY}" \
  --options runtime --timestamp=none \
  --entitlements App/VoiceDoggo-local.entitlements \
  "dist/Voice Doggo.app"
codesign --verify --deep --strict "dist/Voice Doggo.app"

echo "已生成并使用开发者证书签名：dist/Voice Doggo.app"
