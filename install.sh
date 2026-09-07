#!/usr/bin/env bash
# 安装：检查前置依赖，软链 Lua 配置到 ~/.hammerspoon/，装载 launchd 服务
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.doubaovoice.daemon"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
# 0.1.0 之前用的是作者个人 label，升级时要先把旧服务卸掉，否则两个 daemon
# 会同时抢 ctl.sock
LEGACY_LABELS=("com.chrisliang.dbvoiced")

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "只支持 macOS（依赖 Hammerspoon 与 launchd）" >&2
  exit 1
fi

echo "==> 检查前置依赖"
missing=()
command -v uv >/dev/null 2>&1 || missing+=("uv（curl -LsSf https://astral.sh/uv/install.sh | sh）")
# portaudio 是 sounddevice 的动态库依赖，缺了要到运行时才报 OSError
if ! (brew list --formula portaudio >/dev/null 2>&1 \
      || ls /usr/local/lib/libportaudio*.dylib /opt/homebrew/lib/libportaudio*.dylib >/dev/null 2>&1); then
  missing+=("portaudio（brew install portaudio）")
fi
[[ -d "/Applications/Hammerspoon.app" ]] \
  || missing+=("Hammerspoon（brew install --cask hammerspoon）")

if (( ${#missing[@]} )); then
  echo "缺少以下依赖，装完再跑一次：" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  exit 1
fi
echo "    uv / portaudio / Hammerspoon 都在"

echo "==> 同步 Python 依赖"
cd "$REPO" && uv sync

# Lua 的 local 只对其后的代码可见，定义在使用之后就静默变成 nil 全局，
# 要到运行时才炸，而 luac -p 查不出来。装了 luacheck 就在这里挡掉。
if command -v luacheck >/dev/null 2>&1; then
  echo "==> 检查 Lua"
  luacheck --quiet lua/ || { echo "Lua 检查未通过，先修再装"; exit 1; }
fi

echo "==> 软链 Lua 到 ~/.hammerspoon/doubao-voice"
mkdir -p "$HOME/.hammerspoon"
rm -rf "$HOME/.hammerspoon/doubao-voice"
ln -s "$REPO/lua" "$HOME/.hammerspoon/doubao-voice"

INITLUA="$HOME/.hammerspoon/init.lua"
LOADLINE='DBVOICE = require("doubao-voice.init").start()'
if ! grep -qF 'doubao-voice.init' "$INITLUA" 2>/dev/null; then
  echo "==> 追加装载行到 $INITLUA"
  echo "$LOADLINE" >> "$INITLUA"
else
  echo "==> $INITLUA 已有装载行，跳过"
fi

echo "==> 准备配置目录"
mkdir -p "$HOME/Library/LaunchAgents"
chmod 700 "$HOME/.doubao-voice"
if [[ ! -f "$HOME/.doubao-voice/config.json" ]]; then
  cp "$REPO/config.example.json" "$HOME/.doubao-voice/config.json"
  chmod 600 "$HOME/.doubao-voice/config.json"
  echo "    已生成 ~/.doubao-voice/config.json，把凭证填进去（见 README「凭证」）"
else
  echo "    ~/.doubao-voice/config.json 已存在，不覆盖"
fi

# 只有显式选了本地后端才下那 254 MB 模型。放在 uv sync 之后：
# fetch-model 本身就是 dbvoice 的子命令。
BACKEND="$(uv run python -c 'from doubao_voice import config; print(config.load().backend)' 2>/dev/null || echo doubao)"
if [[ "$BACKEND" == "funasr" ]]; then
  echo "==> 本地 FunASR 模型"
  uv run dbvoice fetch-model || {
    echo "    模型没装上。国内网络可试镜像：" >&2
    echo "    DBVOICE_HF_HOST=https://hf-mirror.com uv run dbvoice fetch-model" >&2
    echo "    或把 config.json 的 backend 改成 doubao 走云端。" >&2
  }
fi

echo "==> 生成 launchd plist"
sed -e "s|__VENV_BIN__|$REPO/.venv/bin|g" -e "s|__HOME__|$HOME|g" \
  "$REPO/launchd/$LABEL.plist" > "$PLIST"

unload_label() {
  # bootout 是异步的，紧接着 bootstrap 会撞上 "Input/output error"
  local lbl="$1"
  launchctl print "gui/$(id -u)/$lbl" >/dev/null 2>&1 || return 0
  launchctl bootout "gui/$(id -u)/$lbl" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    launchctl print "gui/$(id -u)/$lbl" >/dev/null 2>&1 || break
    sleep 0.5
  done
}

for legacy in "${LEGACY_LABELS[@]}"; do
  if launchctl print "gui/$(id -u)/$legacy" >/dev/null 2>&1; then
    echo "==> 卸载旧服务 $legacy"
    unload_label "$legacy"
    rm -f "$HOME/Library/LaunchAgents/$legacy.plist"
  fi
done

echo "==> 装载服务"
unload_label "$LABEL"
launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 1
launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -E "^\s+(state|pid) " || true

echo "==> 重载 Hammerspoon 配置"
# 重载这件事踩过两个坑，都别再试：
#   1. `hs -c 'hs.reload()'` 会挂住——reload 切断 IPC 端口，CLI 一直等一个
#      永远不会来的回复。改成 doAfter 延迟触发**也会挂**（实测卡满 120 秒），
#      因为 CLI 仍在等这次调用的返回。所以必须整条丢到后台、不等它。
#   2. `osascript -e 'tell application "Hammerspoon" to reload config'` 是错的：
#      Hammerspoon 的 AppleScript 字典里没这条命令，实测报 -2740 语法错误。
# 结论：重启进程最省事也最可靠。
if pgrep -x Hammerspoon >/dev/null 2>&1; then
  if command -v hs >/dev/null 2>&1; then
    ( hs -c 'hs.timer.doAfter(0.3, hs.reload)' >/dev/null 2>&1 & )
    sleep 3
  fi
  # 无论上面那下有没有生效，都以重启兜底——它一定能加载到新的 Lua
  pkill -x Hammerspoon 2>/dev/null || true
  sleep 2
  open -a Hammerspoon && echo "    已重启 Hammerspoon"
else
  open -a Hammerspoon && echo "    已启动 Hammerspoon"
fi

cat <<'EOF'

完成。还差三步：
  1. 系统设置 → 隐私与安全性，给 Hammerspoon 开「辅助功能」与「输入监控」
  2. 把凭证填进 ~/.doubao-voice/config.json（见 README「凭证」）
  3. uv run dbvoice doctor   自检，全绿即可开用

想省掉凭证与费用，可以把 backend 改成 "funasr" 走本地推理——但那条路
是实验特性（仅 Apple Silicon，且真人按键路径未验收通过），见 README。
EOF
