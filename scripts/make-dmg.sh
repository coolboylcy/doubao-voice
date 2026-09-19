#!/usr/bin/env bash
# 打安装镜像。
#
# 比 `hdiutil create` 一条命令多做的事：给卷装上图标、铺好背景图、把 App 和
# Applications 快捷方式摆到该在的位置。没这些的话用户双击下载来的镜像，看到的
# 是一个通用白磁盘图标和两个随便堆着的文件——能装，但像是谁临时打包扔过来的。
#
# 布局要靠 AppleScript 指挥访达，而这需要「自动化」权限。拿不到权限时不硬来：
# 跳过布局，照样产出一个功能完整的镜像，只是朴素一点。CI 上就是这条路。
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
OUTPUT_PATH="${OUTPUT_PATH:-dist/Voice Doggo $(./scripts/version.sh).dmg}"
VOLUME_NAME="Voice Doggo"
ASSETS="App/DMGAssets"

# 图标坐标必须跟 make-dmg-assets.py 里画背景时用的一致，
# 否则箭头会指到空处。
APP_X=170; APP_Y=205
LINK_X=490; LINK_Y=205
WIN_W=660; WIN_H=420

if [[ ! -d "$APP_PATH" ]]; then
  echo "找不到 App：$APP_PATH" >&2
  echo "请先执行归档，或用 APP_PATH 指向已有的 .app" >&2
  exit 1
fi

if [[ ! -f "$ASSETS/VolumeIcon.icns" || ! -f "$ASSETS/dmg-background.png" ]]; then
  echo "缺少 DMG 素材，正在生成…"
  uv run --with pillow python3 scripts/make-dmg-assets.py
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"
STAGING_DIR="$(mktemp -d /tmp/voice-doggo-dmg.XXXXXX)"
MOUNT_POINT=""
RW_DMG=""
cleanup() {
  [[ -n "$MOUNT_POINT" ]] && hdiutil detach "$MOUNT_POINT" -quiet -force 2>/dev/null || true
  rm -rf "$STAGING_DIR"
  [[ -n "$RW_DMG" ]] && rm -f "$RW_DMG" || true
}
trap cleanup EXIT

ditto "$APP_PATH" "$STAGING_DIR/Voice Doggo.app"
ln -s /Applications "$STAGING_DIR/Applications"

# 背景图和卷图标都放进隐藏目录/隐藏文件，用户打开窗口时不该看见它们
mkdir -p "$STAGING_DIR/.background"
cp "$ASSETS/dmg-background.png" "$STAGING_DIR/.background/background.png"
cp "$ASSETS/VolumeIcon.icns" "$STAGING_DIR/.VolumeIcon.icns"

# 先造一个可写镜像。布局信息（图标位置、窗口大小、背景图）存在卷的 .DS_Store
# 里，只读镜像写不进去，所以必须先 UDRW 再转 UDZO。
RW_DMG="$(mktemp -u /tmp/voice-doggo-rw.XXXXXX).dmg"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov -format UDRW \
  "$RW_DMG" >/dev/null

MOUNT_POINT="$(mktemp -d /tmp/voice-doggo-mount.XXXXXX)"
hdiutil attach "$RW_DMG" -mountpoint "$MOUNT_POINT" -nobrowse -noverify -quiet

# 让访达认这个卷的自定义图标：目录要带 C(ustom icon) 标志
if command -v SetFile >/dev/null 2>&1; then
  SetFile -a C "$MOUNT_POINT" 2>/dev/null || true
fi

# 指挥访达摆好窗口。失败不致命——多半是没有自动化权限（CI 上必然如此）。
layout_script=$(cat <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 140, $((200 + WIN_W)), $((140 + WIN_H))}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 108
    set background picture of viewOptions to file ".background:background.png"
    set position of item "Voice Doggo.app" of container window to {$APP_X, $APP_Y}
    set position of item "Applications" of container window to {$LINK_X, $LINK_Y}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
)

if osascript -e "$layout_script" >/dev/null 2>&1; then
  echo "已设置窗口布局与背景"
else
  echo "跳过窗口布局（访达自动化权限不可用），镜像内容不受影响" >&2
fi

sync
hdiutil detach "$MOUNT_POINT" -quiet -force
MOUNT_POINT=""

hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$OUTPUT_PATH" >/dev/null

# 给 .dmg 文件本身也套上图标，这样它躺在「下载」文件夹里一眼能认出来。
#
# 走 NSWorkspace.setIcon 而不是 Rez：Rez 那套是往文件的资源分支里塞 'icns'
# 资源，对现在的 APFS 和公证流程都不再可靠，实测执行了也不生效。setIcon 是
# 普通 Cocoa API，不需要任何额外权限，写完 SetFile 的 C 标志会自动置上。
ICON_ABS="$REPO/$ASSETS/VolumeIcon.icns"
DMG_ABS="$(cd "$(dirname "$OUTPUT_PATH")" && pwd)/$(basename "$OUTPUT_PATH")"
osascript >/dev/null 2>&1 <<APPLESCRIPT || echo "未能给 DMG 文件设置图标（不影响安装）" >&2
use framework "AppKit"
use scripting additions
set ws to current application's NSWorkspace's sharedWorkspace()
set img to current application's NSImage's alloc()'s initWithContentsOfFile:"$ICON_ABS"
ws's setIcon:img forFile:"$DMG_ABS" options:0
APPLESCRIPT

echo "已生成安装镜像：$OUTPUT_PATH"
