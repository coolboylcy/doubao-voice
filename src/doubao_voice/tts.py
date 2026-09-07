"""把文字念出来。

首版用 macOS 自带的 say：零成本、零延迟、不用开通任何服务，先把"说→干活
→念→打断"整条链路跑通。声音机械，但链路对了再换豆包语音合成不迟——
Speaker 的接口就是为了那次替换留的。

打断的语义是"只停嘴"：kill 掉播放进程，但不碰 Claude 手上的活。
"""

from __future__ import annotations

import asyncio
import shutil

# 中文音色，装了中文语音包才有；没有就用系统默认
PREFERRED_VOICES = ("Tingting", "Meijia", "Sinji")
DEFAULT_RATE = 190  # 词/分钟，say 默认 175 偏慢


class Speaker:
    """串行播放队列，一次只念一句，可随时掐断。"""

    def __init__(self, *, voice: str | None = None, rate: int = DEFAULT_RATE):
        self._voice = voice
        self._rate = rate
        self._proc: asyncio.subprocess.Process | None = None
        self._lock = asyncio.Lock()

    async def resolve_voice(self) -> str | None:
        if self._voice is not None:
            return self._voice or None
        if not shutil.which("say"):
            self._voice = ""
            return None
        proc = await asyncio.create_subprocess_exec(
            "say", "-v", "?", stdout=asyncio.subprocess.PIPE
        )
        out, _ = await proc.communicate()
        listing = out.decode("utf-8", "replace")
        for name in PREFERRED_VOICES:
            if name in listing:
                self._voice = name
                return name
        self._voice = ""
        return None

    async def say(self, text: str) -> None:
        """念一句，念完才返回。被 stop() 掐断就提前返回。"""
        text = text.strip()
        if not text or not shutil.which("say"):
            return
        voice = await self.resolve_voice()
        async with self._lock:
            cmd = ["say", "-r", str(self._rate)]
            if voice:
                cmd += ["-v", voice]
            cmd.append(text)
            self._proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
            )
            try:
                await self._proc.wait()
            finally:
                self._proc = None

    def stop(self) -> bool:
        """掐断当前播放。返回是否真的掐到了东西。"""
        proc = self._proc
        if proc is None or proc.returncode is not None:
            return False
        try:
            proc.kill()
        except ProcessLookupError:
            return False
        return True

    @property
    def speaking(self) -> bool:
        return self._proc is not None and self._proc.returncode is None
