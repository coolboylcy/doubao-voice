"""取前台终端窗口的工作目录，作为对话模式里 Claude 的干活目录。

你在哪个项目下，说话就在哪个项目里干活——这比写死一个目录符合直觉。

做法：AppleScript 拿 Terminal 前台 tab 的 tty → ps 找该 tty 上的前台进程组
→ lsof 读它的 cwd。前台不是终端（在浏览器里说话）时回退到默认目录。
"""

from __future__ import annotations

import asyncio
import os
import re
from pathlib import Path

FALLBACK = str(Path.home())

_TTY_SCRIPT = 'tell application "Terminal" to get tty of selected tab of front window'
_FRONT_APP_SCRIPT = (
    'tell application "System Events" to name of first process whose frontmost is true'
)

# 这些进程本身不代表用户所在的目录
_SKIP_COMMANDS = {"caffeinate", "lsof", "ps", "osascript"}


async def _run(*cmd: str, timeout: float = 2.0) -> str:
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        out, _ = await asyncio.wait_for(proc.communicate(), timeout)
        return out.decode("utf-8", "replace").strip()
    except (asyncio.TimeoutError, FileNotFoundError, OSError):
        return ""


async def front_app() -> str:
    return await _run("osascript", "-e", _FRONT_APP_SCRIPT)


async def _tty_of_front_terminal() -> str:
    tty = await _run("osascript", "-e", _TTY_SCRIPT)
    m = re.fullmatch(r"/dev/(tty\w+)", tty.strip())
    return m.group(1) if m else ""


async def _foreground_pids(tty: str) -> list[tuple[int, str]]:
    """该 tty 上属于前台进程组（stat 带 +）的进程。"""
    out = await _run("ps", "-t", tty, "-o", "pid=,stat=,comm=")
    found = []
    for raw in out.split("\n"):
        parts = raw.split(None, 2)
        if len(parts) < 3:
            continue
        pid, stat, comm = parts
        if "+" not in stat or not pid.isdigit():
            continue
        if os.path.basename(comm) in _SKIP_COMMANDS:
            continue
        found.append((int(pid), os.path.basename(comm)))
    return found


async def _cwd_of(pid: int) -> str:
    out = await _run("lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn")
    for raw in out.split("\n"):
        if raw.startswith("n"):
            return raw[1:]
    return ""


async def resolve(fallback: str = FALLBACK) -> str:
    """拿到前台终端的 cwd，拿不到就回退。"""
    if await front_app() != "Terminal":
        return fallback

    tty = await _tty_of_front_terminal()
    if not tty:
        return fallback

    for pid, _comm in await _foreground_pids(tty):
        cwd = await _cwd_of(pid)
        if cwd and os.path.isdir(cwd):
            return cwd

    return fallback
