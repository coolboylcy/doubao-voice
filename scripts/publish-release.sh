#!/usr/bin/env bash
# 把已经签好名、公证过的 DMG 发成一个 GitHub Release。
#
# 关键在于每次都额外传一份**固定文件名**的副本 VoiceDoggo.dmg。GitHub 的
# /releases/latest/download/<资产名> 是按文件名取最新一版的，而带版本号的
# 文件名每次都变，那条链接就永远拼不出来。多传一份同内容、固定名字的资产，
# 官网的下载按钮就可以写死成：
#
#   https://github.com/coolboylcy/voice-doggo/releases/latest/download/VoiceDoggo.dmg
#
# 以后发任何新版本，这个地址自动指过去，官网不用改。
#
# 用法：scripts/publish-release.sh <发布说明 markdown 文件>
set -euo pipefail

cd "$(dirname "$0")/.."

NOTES="${1:-}"
VERSION="$(./scripts/version.sh)"
DMG="dist/Voice Doggo ${VERSION}.dmg"
STABLE_NAME="VoiceDoggo.dmg"
REPO_SLUG="coolboylcy/voice-doggo"

[[ -f "$DMG" ]] || { echo "找不到 $DMG，先跑 scripts/release-dmg.sh" >&2; exit 1; }
[[ -n "$NOTES" && -f "$NOTES" ]] || { echo "用法：$0 <发布说明.md>" >&2; exit 1; }

# 公证票据必须已经装订进 DMG，否则别人下载后离线打开会被 Gatekeeper 拦。
xcrun stapler validate "$DMG" >/dev/null 2>&1 || {
  echo "$DMG 没有装订公证票据，先跑 scripts/release-dmg.sh" >&2
  exit 1
}

STABLE_PATH="$(mktemp -d)/${STABLE_NAME}"
cp "$DMG" "$STABLE_PATH"

if gh release view "v${VERSION}" --repo "$REPO_SLUG" >/dev/null 2>&1; then
  echo "==> v${VERSION} 已存在，替换资产"
  gh release upload "v${VERSION}" "$DMG" "$STABLE_PATH" --repo "$REPO_SLUG" --clobber
else
  echo "==> 创建 v${VERSION}"
  gh release create "v${VERSION}" "$DMG" "$STABLE_PATH" \
    --repo "$REPO_SLUG" \
    --title "语音狗子 v${VERSION}" \
    --notes-file "$NOTES"
fi

rm -rf "$(dirname "$STABLE_PATH")"

LATEST="https://github.com/${REPO_SLUG}/releases/latest/download/${STABLE_NAME}"
echo
echo "永久下载链接（官网写这个，发版后自动指向最新）："
echo "  $LATEST"

echo
echo "==> 验证这条链接真的能下到本次的包"
ACTUAL="$(curl -sIL -o /dev/null -w '%{url_effective}' "$LATEST")"
case "$ACTUAL" in
  *"${VERSION}"*|*release-assets*)
    echo "    解析到：$ACTUAL"
    ;;
  *)
    echo "跳转目标不像本次发布：$ACTUAL" >&2
    exit 1
    ;;
esac
