#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

: "${TEAM_ID:?请设置 TEAM_ID，例如 TEAM_ID=ABCDE12345}"
: "${ASC_KEY_ID:?请设置 ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?请设置 ASC_ISSUER_ID}"
: "${ASC_KEY_PATH:?请设置 ASC_KEY_PATH，指向 App Store Connect API 私钥 .p8}"

command -v xcodegen >/dev/null 2>&1 || {
  echo "缺少 xcodegen：brew install xcodegen" >&2
  exit 1
}

if ! security find-identity -v -p codesigning 2>/dev/null | rg -q 'Mac Installer Distribution'; then
  echo "当前钥匙串缺少 Mac Installer Distribution 证书；请先在 Apple Developer 创建并安装它。" >&2
  exit 1
fi

HELPER_CODESIGN_IDENTITY='Apple Distribution' ./scripts/build-helper.sh
xcodegen generate --spec project.yml
rm -rf build/AppStore.xcarchive build/AppStoreExport

xcodebuild archive \
  -project DoubaoVoice.xcodeproj \
  -scheme DoubaoVoice \
  -archivePath build/AppStore.xcarchive \
  -destination 'generic/platform=macOS' \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY='Apple Distribution' \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  MARKETING_VERSION="${MARKETING_VERSION:-0.2.0}" \
  CURRENT_PROJECT_VERSION="${BUILD_NUMBER:-1}" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

cat > build/ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>signingStyle</key><string>automatic</string>
<key>teamID</key><string>$TEAM_ID</string>
<key>uploadSymbols</key><true/>
<key>manageAppVersionAndBuildNumber</key><true/>
</dict></plist>
EOF

xcodebuild -exportArchive \
  -archivePath build/AppStore.xcarchive \
  -exportPath build/AppStoreExport \
  -exportOptionsPlist build/ExportOptions.plist

echo "已生成 App Store 提交包：build/AppStoreExport"

if [[ "${UPLOAD_TO_APP_STORE:-0}" == "1" ]]; then
  package="$(find build/AppStoreExport -maxdepth 1 -type f -name '*.pkg' -print -quit)"
  if [[ -z "$package" ]]; then
    echo "导出目录中没有找到 .pkg，无法上传" >&2
    exit 1
  fi
  xcrun altool --upload-package "$package" \
    --api-key "$ASC_KEY_ID" \
    --api-issuer "$ASC_ISSUER_ID" \
    --p8-file-path "$ASC_KEY_PATH" \
    --wait
  echo "已提交到 App Store Connect，等待处理完成"
fi
