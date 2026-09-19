#!/usr/bin/env bash
# 把设置页离屏渲染成 PNG，用来校对布局。
#
# 不需要屏幕：锁屏、没有 Xcode 自动化权限、在 CI 里，screencapture 都拿不到
# 东西，ImageRenderer 照样出图。改完布局渲一轮比反复开窗截图快得多。
#
# 用法：scripts/render-settings.sh [输出目录]
#
# 注意：Toggle、Link 这类 AppKit 控件在离屏渲染里画成一块黄底禁止符，
# 那是渲染器的占位符，不是界面坏了。
set -euo pipefail

cd "$(dirname "$0")/.."
APP="dist/Voice Doggo.app/Contents/MacOS/Voice Doggo"
OUT="${1:-build/settings-shots}"

[[ -x "$APP" ]] || { echo "先跑 scripts/build-macos-app.sh" >&2; exit 1; }

mkdir -p "$OUT"
for appearance in light dark; do
  for section in general shortcut about; do
    "$APP" --render-settings "$OUT/$section-$appearance.png" \
           --appearance "$appearance" --section "$section" >/dev/null 2>&1 || true
    [[ -s "$OUT/$section-$appearance.png" ]] || { echo "渲染失败：$section/$appearance" >&2; exit 1; }
  done
done

echo "已渲染 6 张 → $OUT"
