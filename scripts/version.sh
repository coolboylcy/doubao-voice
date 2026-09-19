#!/usr/bin/env bash
# 版本号的唯一来源是 project.yml 的 MARKETING_VERSION——Info.plist 里写的是
# $(MARKETING_VERSION)，App 显示的版本由它来。
#
# 之前版本号硬编码在 4 个脚本里，发一次版要改 5 处；漏掉打包脚本那处，
# 产出的 DMG 文件名和 App 内的版本号就会对不上，而且只有装完打开设置页才
# 看得出来。
#
# 用法：VERSION="$(scripts/version.sh)"
set -euo pipefail

cd "$(dirname "$0")/.."

version="$(awk -F'"' '/^[[:space:]]*MARKETING_VERSION:/ { print $2; exit }' project.yml)"

if [[ -z "$version" ]]; then
  echo "project.yml 里读不到 MARKETING_VERSION" >&2
  exit 1
fi

echo "$version"
