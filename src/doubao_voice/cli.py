"""命令行入口。

    dbvoice doctor   自检：配置、凭证、音频设备、权限、daemon 状态
    dbvoice once     录 N 秒并打印识别结果——不依赖 Hammerspoon 验证整条链路
    dbvoice daemon   跑常驻服务
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import shutil
import subprocess
import sys
import time
from pathlib import Path

from . import config as cfgmod
from .asr import AsrError, AsrSession
from .daemon import Daemon
from .mic import Microphone

FAILED_RETENTION_DAYS = 7
LAUNCHD_LABEL = "com.doubaovoice.daemon"


def _ok(msg: str) -> None:
    print(f"  \033[32mok\033[0m   {msg}")


def _bad(msg: str) -> None:
    print(f"  \033[31mFAIL\033[0m {msg}")


def _warn(msg: str) -> None:
    print(f"  \033[33mwarn\033[0m {msg}")


def _purge_failed() -> int:
    if not cfgmod.FAILED_DIR.exists():
        return 0
    cutoff = time.time() - FAILED_RETENTION_DAYS * 86400
    removed = 0
    for f in cfgmod.FAILED_DIR.iterdir():
        if f.is_file() and f.stat().st_mtime < cutoff:
            f.unlink()
            removed += 1
    return removed


def cmd_doctor(_args) -> int:
    failures = 0

    print("配置")
    path = cfgmod.CONFIG_PATH
    if not path.exists():
        _bad(f"{path} 不存在，见 README 的开通步骤")
        return 1
    mode = path.stat().st_mode & 0o777
    if mode == 0o600:
        _ok(f"{path} 权限 600")
    else:
        _bad(f"{path} 权限是 {mode:o}，应为 600：chmod 600 {path}")
        failures += 1

    try:
        cfg = cfgmod.load()
    except cfgmod.ConfigError as exc:
        _bad(str(exc))
        return 1

    print("凭证")
    try:
        style = cfg.auth_style
        _ok(f"鉴权形态：{'新版单 key' if style == 'new' else '老版 AppID + Token'}")
        _ok(f"resource_id：{cfg.resource_id}")
        _ok(f"endpoint：{cfg.endpoint}")
    except cfgmod.ConfigError as exc:
        _bad(str(exc))
        failures += 1

    print("音频")
    try:
        import sounddevice

        inputs = [d for d in sounddevice.query_devices() if d["max_input_channels"] > 0]
        if inputs:
            name = sounddevice.query_devices(kind="input")["name"]
            _ok(f"输入设备 {len(inputs)} 个，默认：{name}")
        else:
            _bad("没有任何输入设备")
            failures += 1
    except Exception as exc:
        _bad(f"PortAudio 不可用：{exc}（brew install portaudio）")
        failures += 1

    print("麦克风权限")
    try:
        # 这里刻意不走 Microphone：它靠 call_soon_threadsafe 往 asyncio 队列
        # 投递，而 doctor 是同步的，没有在跑的 loop，投进去的回调永远不执行，
        # 队列会一直是空的——那是假的"采不到音频"。直接开裸流测。
        import sounddevice

        frames: list[bytes] = []
        stream = sounddevice.RawInputStream(
            samplerate=16000,
            channels=1,
            dtype="int16",
            blocksize=3200,
            callback=lambda indata, n, t, s: frames.append(bytes(indata)),
        )
        stream.start()
        time.sleep(0.5)
        stream.stop()
        stream.close()

        if not frames:
            _bad("采不到音频：系统设置 → 隐私与安全性 → 麦克风，勾上终端")
            failures += 1
        else:
            data = b"".join(frames)
            peak = max(
                abs(int.from_bytes(data[i : i + 2], "little", signed=True))
                for i in range(0, len(data), 2)
            )
            _ok(f"采到 {len(data)} 字节，峰值 {peak}")
            if peak < 50:
                _warn("峰值接近 0，可能采的是静音设备——说话时应到数千")
    except Exception as exc:
        _bad(f"打开麦克风失败：{exc}")
        failures += 1

    print("Hammerspoon")
    if Path("/Applications/Hammerspoon.app").exists():
        _ok("已安装")
    else:
        _bad("未安装：brew install --cask hammerspoon")
        failures += 1

    print("daemon")
    if shutil.which("launchctl"):
        out = subprocess.run(["launchctl", "list"], capture_output=True, text=True).stdout
        if LAUNCHD_LABEL in out:
            _ok(f"{LAUNCHD_LABEL} 已装载")
        else:
            _warn(f"{LAUNCHD_LABEL} 未装载（跑 ./install.sh）")
    if cfgmod.SOCKET_PATH.exists():
        _ok(f"控制 socket 在 {cfgmod.SOCKET_PATH}")
    else:
        _warn(f"控制 socket 不存在：{cfgmod.SOCKET_PATH}")

    print("清理")
    _ok(f"清掉 {_purge_failed()} 个超过 {FAILED_RETENTION_DAYS} 天的失败音频")

    print()
    if failures:
        print(f"\033[31m{failures} 项未通过\033[0m")
    else:
        print("\033[32m全部通过\033[0m")
    return 1 if failures else 0


async def _once(seconds: float) -> int:
    cfg = cfgmod.load()
    loop = asyncio.get_running_loop()
    mic = Microphone(loop)
    session = AsrSession(cfg, on_partial=lambda t: print(f"\r  {t}", end="", flush=True))

    await session.open()
    mic.start()
    print(f"开始说话，录 {seconds} 秒……")

    stats = {"bytes": 0, "peak": 0}

    async def pump():
        while True:
            chunk = await mic.queue.get()
            stats["bytes"] += len(chunk)
            for i in range(0, len(chunk), 2):
                v = abs(int.from_bytes(chunk[i : i + 2], "little", signed=True))
                if v > stats["peak"]:
                    stats["peak"] = v
            await session.send_chunk(chunk)

    task = asyncio.create_task(pump())
    await asyncio.sleep(seconds)
    mic.stop()
    task.cancel()

    peak = stats["peak"]
    print(f"\n推流 {stats['bytes']} 字节，峰值 {peak}", end="")
    if peak < 500:
        print("  \033[33m← 太安静，多半没采到人声\033[0m")
    else:
        print()

    try:
        text = await session.close_and_collect()
    except AsrError as exc:
        print(f"\n\033[31m识别失败 [{exc.code}] {exc.message}\033[0m")
        return 1
    except asyncio.TimeoutError:
        print("\n\033[31m等待识别结果超时\033[0m")
        await session.abort()
        return 1
    finally:
        mic.close()

    print(f"\n\n结果：{text or '（空）'}")
    return 0 if text else 1


def cmd_once(args) -> int:
    return asyncio.run(_once(args.seconds))


async def _listen_once(cfg, seconds: float) -> tuple[str, int]:
    """录一段并识别，返回 (文本, 峰值)。"""
    loop = asyncio.get_running_loop()
    mic = Microphone(loop)
    session = AsrSession(cfg, on_partial=lambda _: None)
    await session.open()
    mic.start()

    peak = 0

    async def pump():
        nonlocal peak
        while True:
            chunk = await mic.queue.get()
            for i in range(0, len(chunk) - 1, 2):
                v = abs(int.from_bytes(chunk[i : i + 2], "little", signed=True))
                if v > peak:
                    peak = v
            await session.send_chunk(chunk)

    task = asyncio.create_task(pump())
    await asyncio.sleep(seconds)
    mic.stop()
    task.cancel()
    try:
        text = await session.close_and_collect(timeout=20)
    except (AsrError, asyncio.TimeoutError):
        text = ""
    finally:
        mic.close()
    return text, peak


async def _chat(seconds: float, model: str, cwd_override: str | None) -> int:
    from . import agent, frontcwd
    from .tts import Speaker

    cfg = cfgmod.load()
    cwd = cwd_override or await frontcwd.resolve()
    speaker = Speaker()
    session_id: str | None = None

    print(f"\033[2m工作目录 {cwd} | 模型 {model} | Ctrl-C 退出\033[0m\n")

    while True:
        print(f"\033[36m▶ 说话（{seconds:.0f} 秒）……\033[0m", flush=True)
        heard, peak = await _listen_once(cfg, seconds)
        if not heard:
            print(f"\033[33m  没听清（峰值 {peak}）\033[0m\n")
            continue
        print(f"\033[36m你：\033[0m{heard}\n")

        async for event in agent.converse(
            heard, cwd=cwd, session_id=session_id, model=model
        ):
            if isinstance(event, agent.Speech):
                print(f"\033[32mClaude：\033[0m{event.text}")
                await speaker.say(event.text)
            elif isinstance(event, agent.Action):
                print(f"\033[2m  · {event.brief}\033[0m")
            elif isinstance(event, agent.Done):
                session_id = event.session_id or session_id
                cost = f"${event.cost_usd:.4f}" if event.cost_usd else "?"
                secs = (event.duration_ms or 0) / 1000
                print(f"\033[2m  [{secs:.1f}s {cost}]\033[0m\n")
            elif isinstance(event, agent.Failed):
                print(f"\033[31m  出错：{event.message}\033[0m\n")


def cmd_chat(args) -> int:
    try:
        return asyncio.run(_chat(args.seconds, args.model, args.cwd)) or 0
    except KeyboardInterrupt:
        print("\n再见")
        return 0


def cmd_daemon(_args) -> int:
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s"
    )
    cfg = cfgmod.load()
    d = Daemon(cfg)
    try:
        asyncio.run(d.serve_forever())
    except KeyboardInterrupt:
        pass
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="dbvoice", description="豆包语音全局听写")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("doctor", help="自检环境与凭证").set_defaults(func=cmd_doctor)

    once = sub.add_parser("once", help="录一段并打印识别结果")
    once.add_argument("-s", "--seconds", type=float, default=5.0)
    once.set_defaults(func=cmd_once)

    chat = sub.add_parser("chat", help="语音对话：说一句，Claude 干活并念结果")
    chat.add_argument("-s", "--seconds", type=float, default=5.0, help="每轮录音时长")
    chat.add_argument("-m", "--model", default="sonnet", help="claude 模型")
    chat.add_argument("--cwd", default=None, help="干活目录，默认取前台终端的")
    chat.set_defaults(func=cmd_chat)

    sub.add_parser("daemon", help="跑常驻服务").set_defaults(func=cmd_daemon)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
