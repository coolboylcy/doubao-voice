#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

APP="dist/Voice Doggo.app"
DMG="dist/Voice Doggo $(./scripts/version.sh).dmg"
EXPECTED_TRANSCRIPT="今天天气不错，我正在测试豆包语音识别。"

for command in uv xcodebuild hdiutil codesign; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "缺少验收工具：$command" >&2
    exit 1
  }
done

test -d "$APP" || { echo "缺少 $APP，请先运行 scripts/build-macos-app.sh" >&2; exit 1; }
test -f "$DMG" || { echo "缺少 $DMG，请先运行 scripts/make-dmg.sh" >&2; exit 1; }

echo "[1/10] Python 测试与静态检查"
uv run pytest -q
uv run --with ruff ruff check src tests packaging

echo "[2/10] Swift 单元测试"
# Xcode 的 TEST_HOST 就是 App 本体。已经有实例在跑时，测试 runner 连不上它要
# 的那个进程，会卡满 120 秒控制会话超时（整步耗时十几分钟）才失败，报错只说
# 「test runner hung before establishing connection」，完全看不出是这个原因。
# 提前拦下来，把十几分钟的无头苍蝇变成一句话。
if pgrep -f "Voice Doggo.app/Contents/MacOS/Voice Doggo" >/dev/null 2>&1; then
  if [[ "${VERIFY_KILL_RUNNING_APP:-0}" == "1" ]]; then
    echo "  停掉正在运行的语音狗子（VERIFY_KILL_RUNNING_APP=1）"
    pkill -f "Voice Doggo.app/Contents/MacOS/Voice Doggo" || true
    sleep 2
  else
    echo "语音狗子正在运行，Swift 测试无法进行。" >&2
    echo "测试的 TEST_HOST 是 App 本体，已有实例会让 runner 连不上并卡到超时。" >&2
    echo "请先退出 App，或改用：" >&2
    echo "  VERIFY_KILL_RUNNING_APP=1 ./scripts/verify-release.sh" >&2
    exit 1
  fi
fi
xcodebuild -quiet \
  -project VoiceDoggo.xcodeproj \
  -scheme VoiceDoggo \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build/ReleaseVerification \
  CODE_SIGN_ENTITLEMENTS=App/VoiceDoggo-local.entitlements \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) LOCAL_DISTRIBUTION' \
  -only-testing:VoiceDoggoTests \
  test

# UI 测试要 Xcode 测试 runner 拿到自动化权限，无人值守时会卡在
# 「Timed out while enabling automation mode」。所以默认不跑，但必须把跳过
# 这件事明说——否则验收全绿会让人以为 UI 也验过了。
if [[ "${VERIFY_UI_TESTS:-0}" == "1" ]]; then
  echo "[2b/10] 原生 UI 测试"
  xcodebuild -quiet \
    -project VoiceDoggo.xcodeproj \
    -scheme VoiceDoggo \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath build/ReleaseVerification \
    CODE_SIGN_ENTITLEMENTS=App/VoiceDoggo-local.entitlements \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) LOCAL_DISTRIBUTION' \
    -only-testing:VoiceDoggoUITests \
    test
else
  echo "  ⚠️  已跳过 UI 测试（设置页与菜单栏可用性未验证）"
  echo "      它需要在系统设置 → 隐私与安全性 → 辅助功能 里授权 Xcode，"
  echo "      授权后用 VERIFY_UI_TESTS=1 ./scripts/verify-release.sh 跑完整版"
fi

echo "[3/10] 属性列表与工作区差异检查"
while IFS= read -r plist; do
  plutil -lint "$plist"
done < <(find App packaging -type f -name '*.plist' -print | sort)
git diff --check

echo "[4/10] App 深层签名与必要资源"
codesign --verify --deep --strict --verbose=2 "$APP"
test -x "$APP/Contents/Helpers/doggo"
test -x "$APP/Contents/Resources/funasr/bin/llama-funasr-sensevoice"
test -f "$APP/Contents/Resources/funasr/gguf/sensevoice-small-q8.gguf"
test -f "$APP/Contents/Resources/funasr/gguf/fsmn-vad.gguf"

echo "[5/10] 本地版必须没有 App Sandbox"
# 沙盒会禁掉 System V 信号量，而 PyInstaller onefile 的 bootloader 启动时
# 必须建一个——helper 会每次都死在「Failed to initialize sync semaphore」，
# 录音链路整条起不来。这条断言就是为了不让那次事故重演。
if codesign -d --entitlements - --xml "$APP" 2>/dev/null \
  | plutil -p - 2>/dev/null \
  | grep -q "com.apple.security.app-sandbox"; then
  echo "本地版 App 带着 App Sandbox：内置 helper 必然无法启动" >&2
  echo "检查 scripts/build-macos-app.sh 是否用了 App/VoiceDoggo-local.entitlements" >&2
  exit 1
fi

echo "[6/10] daemon 控制链路端到端"
# 只验通信，不验识别内容——识别由离线模型那一步覆盖。本轮多个故障都卡在
# 「App 发的命令到底有没有到 daemon」，这里把那条链路钉死。
e2e_dir="$(mktemp -d /tmp/voice-doggo-e2e.XXXXXX)"
e2e_cleanup() {
  for pid in "${e2e_pid:-}" "${orphan_pid:-}" "${fake_host:-}"; do
    [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null || true
  done
  rm -rf "$e2e_dir"
}
trap e2e_cleanup EXIT

DOGGO_CONFIG_DIR="$e2e_dir" \
DOGGO_BACKEND=funasr \
DOGGO_FUNASR_BIN="$PWD/$APP/Contents/Resources/funasr/bin/llama-funasr-sensevoice" \
DOGGO_FUNASR_MODEL="$PWD/$APP/Contents/Resources/funasr/gguf/sensevoice-small-q8.gguf" \
DOGGO_FUNASR_VAD="$PWD/$APP/Contents/Resources/funasr/gguf/fsmn-vad.gguf" \
  "$APP/Contents/Helpers/doggo" daemon > "$e2e_dir/daemon.log" 2>&1 &
e2e_pid=$!

for _ in $(seq 1 40); do
  [[ -S "$e2e_dir/ctl.sock" ]] && break
  sleep 1
done
test -S "$e2e_dir/ctl.sock" || {
  echo "daemon 未能在 40 秒内建立控制 socket" >&2
  cat "$e2e_dir/daemon.log" >&2
  exit 1
}

python3 - "$e2e_dir/ctl.sock" <<'PY'
import json, socket, sys, threading, time

path = sys.argv[1]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(30)
s.connect(path)

events = []
def reader():
    buf = b""
    try:
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                if line.strip():
                    events.append(json.loads(line))
    except OSError:
        pass

threading.Thread(target=reader, daemon=True).start()

def send(cmd):
    s.sendall((json.dumps({"cmd": cmd}) + "\n").encode())

send("ping")
time.sleep(0.5)
assert any(e.get("event") == "pong" for e in events), f"ping 没有回 pong：{events}"

send("start")
time.sleep(1.5)
assert any(e.get("event") == "started" for e in events), f"start 没有回 started：{events}"
levels = [e for e in events if e.get("event") == "level"]
assert levels, "录音期间没有收到任何音频电平事件，麦克风采集没跑起来"

send("stop")
time.sleep(8)
terminal = [e for e in events if e.get("event") in ("final", "empty", "error")]
assert terminal, f"stop 之后没有收到终态事件：{[e.get('event') for e in events]}"
assert terminal[0]["event"] != "error", f"stop 返回错误：{terminal[0]}"

print(f"  ping/start/stop 往返正常，收到 {len(levels)} 个电平事件，终态 {terminal[0]['event']}")
PY

kill "$e2e_pid" 2>/dev/null || true
wait "$e2e_pid" 2>/dev/null || true
unset e2e_pid

echo "[7/10] daemon 在宿主消失后自行退出"
# App 崩溃时 terminationHandler 不执行，没有这条守护 helper 会变成占着麦克风
# 和 socket 的孤儿，下次启动还会撞上它。
sleep 600 &
fake_host=$!
DOGGO_CONFIG_DIR="$e2e_dir" \
DOGGO_BACKEND=funasr \
DOGGO_PARENT_PID="$fake_host" \
DOGGO_FUNASR_BIN="$PWD/$APP/Contents/Resources/funasr/bin/llama-funasr-sensevoice" \
DOGGO_FUNASR_MODEL="$PWD/$APP/Contents/Resources/funasr/gguf/sensevoice-small-q8.gguf" \
DOGGO_FUNASR_VAD="$PWD/$APP/Contents/Resources/funasr/gguf/fsmn-vad.gguf" \
  "$APP/Contents/Helpers/doggo" daemon > "$e2e_dir/orphan.log" 2>&1 &
orphan_pid=$!

for _ in $(seq 1 40); do
  [[ -S "$e2e_dir/ctl.sock" ]] && break
  sleep 1
done
kill -9 "$fake_host" 2>/dev/null || true

orphan_gone=0
for _ in $(seq 1 15); do
  sleep 1
  # 不能用 kill -0：进程已退出但还没被 wait 回收时是僵尸，kill -0 照样成功
  state="$(ps -o stat= -p "$orphan_pid" 2>/dev/null || true)"
  if [[ -z "$state" || "$state" == Z* ]]; then
    orphan_gone=1
    break
  fi
done
if [[ "$orphan_gone" != 1 ]]; then
  kill -9 "$orphan_pid" 2>/dev/null || true
  echo "宿主进程已消失，但 daemon 仍在运行——孤儿守护失效" >&2
  cat "$e2e_dir/orphan.log" >&2
  exit 1
fi
wait "$orphan_pid" 2>/dev/null
orphan_status=$?
if [[ "$orphan_status" != 0 ]]; then
  echo "daemon 自行退出了，但退出码是 $orphan_status——App 会误报「后台语音服务意外退出」" >&2
  cat "$e2e_dir/orphan.log" >&2
  exit 1
fi
test ! -e "$e2e_dir/ctl.sock" || {
  echo "daemon 退出时没有清理 socket 文件" >&2
  exit 1
}

rm -rf "$e2e_dir"
trap - EXIT

echo "[8/10] DMG 校验"
hdiutil verify "$DMG"

mount_dir="$(mktemp -d /tmp/voice-doggo-release-verify.XXXXXX)"
mounted=0
cleanup() {
  if [[ "$mounted" == 1 ]]; then
    hdiutil detach "$mount_dir" >/dev/null 2>&1 || true
  fi
  rmdir "$mount_dir" 2>/dev/null || true
}
trap cleanup EXIT

echo "[9/10] 从只读 DMG 反向检查 App"
hdiutil attach -readonly -nobrowse -mountpoint "$mount_dir" "$DMG" >/dev/null
mounted=1
mounted_app="$mount_dir/Voice Doggo.app"
codesign --verify --deep --strict --verbose=2 "$mounted_app"
test -L "$mount_dir/Applications"
test -x "$mounted_app/Contents/Helpers/doggo"

echo "[10/10] 直接运行 DMG 内离线模型"
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

# 上一步刚从这个挂载点跑完识别，引擎 mmap 了 2.4GB 的模型文件。进程虽然退了，
# 内核回收映射要一点时间，这期间 detach 会报「资源忙」。重试几次即可，不是
# 镜像有问题——直接上 -force 会掩盖掉真正卡住的情况。
for attempt in 1 2 3 4 5; do
  if hdiutil detach "$mount_dir" >/dev/null 2>&1; then
    break
  fi
  if [[ $attempt -eq 5 ]]; then
    echo "镜像卸载不掉，可能有进程仍在占用：" >&2
    lsof +D "$mount_dir" 2>/dev/null | head -5 >&2 || true
    hdiutil detach "$mount_dir" -force >/dev/null
  fi
  sleep 1
done
mounted=0
rmdir "$mount_dir"
trap - EXIT

echo "发布验收全部通过"
shasum -a 256 "$DMG"
