"""控制 socket 服务端与录音会话编排。

daemon 只认识 start / stop / cancel / ping 四个命令，**不知道当前是
PTT 还是 TOGGLE**——那是 Lua 侧的语义（见 spec 第 6 节）。它唯一的
自主判断是"录音不足 min_recording_ms 就丢弃"，用于挡掉 PTT 误触。
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import time
from pathlib import Path

from . import backend
from .asr import AsrError
from .config import SOCKET_PATH, Config
from .mic import Microphone

log = logging.getLogger("dbvoiced")

# 推给 ASR 的单包大小：200ms × 16000 × 2 字节。麦克风按 50ms 采（见
# mic.CHUNK_MS）好让 HUD 波形跟得上说话，这里攒够 200ms 再发一包——
# 官方建议的 100–200ms 是给 ASR 的，跟采集粒度是两件事。
ASR_CHUNK_BYTES = 6400


def peak_amplitude(pcm: bytes) -> int:
    """一包 16bit 小端 PCM 的峰值幅度。

    用于本地判断"有没有人在说话"。原设计靠服务端返回的非空识别结果来
    重置静音定时器，但豆包 2.0 只有 nostream 模式——整段说完才给文本，
    中途一个非空结果都没有，那条防线会把每一次正常的 TOGGLE 录音都在
    3 秒时误杀。本地判音量既修掉这个 bug，又让误触彻底不产生 API 调用。
    """
    return max(
        (
            abs(int.from_bytes(pcm[i : i + 2], "little", signed=True))
            for i in range(0, len(pcm) - 1, 2)
        ),
        default=0,
    )


class Daemon:
    def __init__(
        self,
        cfg: Config,
        *,
        socket_path: Path = SOCKET_PATH,
        mic_factory=Microphone,
        asr_factory=None,
    ):
        self.cfg = cfg
        self.socket_path = Path(socket_path)
        self._mic_factory = mic_factory
        # 不传就按 cfg.backend 选路；测试仍可直接注入一个假的
        self._asr_factory = asr_factory or backend.session_factory(cfg)
        self._mic = None
        self._asr = None
        self._pump: asyncio.Task | None = None
        self._started_at: float | None = None
        self._writers: set[asyncio.StreamWriter] = set()
        self._server: asyncio.AbstractServer | None = None
        self._lock = asyncio.Lock()
        # 50ms 采样攒到 200ms 再推给 ASR 的暂存区
        self._pcm_buf = bytearray()

    # ---- 生命周期 ----

    async def start_server(self) -> None:
        self.socket_path.parent.mkdir(parents=True, exist_ok=True)
        # 上次非正常退出会留下 socket 文件，直接顶掉
        with contextlib.suppress(FileNotFoundError):
            self.socket_path.unlink()
        self._mic = self._mic_factory(asyncio.get_running_loop())
        self._server = await asyncio.start_unix_server(
            self._handle_client, path=str(self.socket_path)
        )
        self.socket_path.chmod(0o600)
        log.info("listening on %s", self.socket_path)

    async def stop_server(self) -> None:
        if self._server:
            self._server.close()
            await self._server.wait_closed()
        if self._mic:
            self._mic.close()
        with contextlib.suppress(FileNotFoundError):
            self.socket_path.unlink()

    async def serve_forever(self) -> None:
        await self.start_server()
        assert self._server is not None
        async with self._server:
            await self._server.serve_forever()

    # ---- 客户端连接 ----

    async def _handle_client(self, reader, writer) -> None:
        self._writers.add(writer)
        try:
            while line := await reader.readline():
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    await self._emit({"event": "error", "message": "非法 JSON"})
                    continue
                await self._dispatch(msg.get("cmd", ""))
        except (ConnectionResetError, asyncio.IncompleteReadError):
            pass
        finally:
            self._writers.discard(writer)
            with contextlib.suppress(Exception):
                writer.close()

    async def _dispatch(self, cmd: str) -> None:
        if cmd == "ping":
            await self._emit({"event": "pong", "ready": True})
        elif cmd == "start":
            await self.cmd_start()
        elif cmd == "stop":
            await self.cmd_stop()
        elif cmd == "cancel":
            await self.cmd_cancel()
        else:
            await self._emit({"event": "error", "message": f"未知命令 {cmd!r}"})

    async def _emit(self, event: dict) -> None:
        line = (json.dumps(event, ensure_ascii=False) + "\n").encode("utf-8")
        for writer in list(self._writers):
            try:
                writer.write(line)
                await writer.drain()
            except Exception:
                self._writers.discard(writer)

    # ---- 命令 ----

    async def cmd_start(self) -> None:
        async with self._lock:
            if self._asr is not None:
                # 已在录音，重复 start 是幂等的
                await self._emit({"event": "started"})
                return
            asr = self._asr_factory(self.cfg, self._on_partial)
            try:
                await asr.open()
            except Exception as exc:
                await self._emit(
                    {"event": "error", "code": "", "message": f"建连失败：{exc}"}
                )
                return
            self._asr = asr
            try:
                self._start_mic()
            except Exception as exc:
                self._asr = None
                await asr.abort()
                await self._emit(
                    {"event": "error", "code": "", "message": f"麦克风打开失败：{exc}"}
                )
                return
            self._started_at = time.monotonic()
            self._pcm_buf.clear()
            self._pump = asyncio.create_task(self._pump_audio())
            await self._emit({"event": "started"})

    async def cmd_stop(self) -> None:
        async with self._lock:
            if self._asr is None:
                await self._emit({"event": "empty"})
                return
            asr, self._asr = self._asr, None
            elapsed_ms = (time.monotonic() - (self._started_at or 0)) * 1000
            await self._teardown_capture()

            if elapsed_ms < self.cfg.min_recording_ms:
                # PTT 误触：本地丢弃，不发请求也就不计费
                self._pcm_buf.clear()
                await asr.abort()
                await self._emit({"event": "empty"})
                return

            # 把不足一整包的尾巴补发出去，否则最后 200ms 内的字会被切掉
            if self._pcm_buf:
                tail = bytes(self._pcm_buf)
                self._pcm_buf.clear()
                try:
                    await asr.send_chunk(tail)
                except Exception as exc:
                    log.warning("补发尾包失败：%s", exc)

            try:
                text = await asr.close_and_collect()
            except AsrError as exc:
                await self._emit(
                    {"event": "error", "code": str(exc.code), "message": exc.message}
                )
                return
            except asyncio.TimeoutError:
                await asr.abort()
                await self._emit(
                    {"event": "error", "code": "", "message": "等待识别结果超时"}
                )
                return

            if not text:
                await self._emit({"event": "empty"})
                return

            await self._emit({"event": "final", "text": text})

    async def cmd_cancel(self) -> None:
        async with self._lock:
            if self._asr is None:
                await self._emit({"event": "cancelled"})
                return
            asr, self._asr = self._asr, None
            await self._teardown_capture()
            await asr.abort()
            await self._emit({"event": "cancelled"})

    # ---- 内部 ----

    def _start_mic(self) -> None:
        """开麦，失败则重建一次再试。

        daemon 是常驻的，麦克风在启动时 open 一次就一直held 着。合盖休眠、
        插拔耳机、切换输入设备都会让 PortAudio 重新枚举设备，握着的 stream
        句柄可能就此失效——不重建的话，一次休眠就够让热键从此哑掉，而且
        毫无提示。
        """
        try:
            self._mic.start()
            return
        except Exception as exc:
            log.warning("麦克风 start 失败，重建后重试：%s", exc)

        with contextlib.suppress(Exception):
            self._mic.close()
        self._mic = self._mic_factory(asyncio.get_running_loop())
        self._mic.start()
        log.info("麦克风已重建")

    async def _teardown_capture(self) -> None:
        self._mic.stop()
        if self._pump:
            self._pump.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._pump
            self._pump = None
        self._started_at = None

    async def _pump_audio(self) -> None:
        asr = self._asr
        try:
            while True:
                chunk = await self._mic.queue.get()
                if asr is None or asr is not self._asr:
                    return
                peak = peak_amplitude(chunk)
                # 每包（50ms）都报电平：voiced 供状态机做静音判定，
                # peak 供 HUD 画波形——一包一格，横轴即真实时间。
                await self._emit(
                    {
                        "event": "level",
                        "peak": peak,
                        "voiced": peak >= self.cfg.voice_threshold,
                    }
                )
                # 攒够 200ms 再推给 ASR
                self._pcm_buf += chunk
                while len(self._pcm_buf) >= ASR_CHUNK_BYTES:
                    block = bytes(self._pcm_buf[:ASR_CHUNK_BYTES])
                    del self._pcm_buf[:ASR_CHUNK_BYTES]
                    await asr.send_chunk(block)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            log.warning("推流中断：%s", exc)
            await self._emit(
                {"event": "error", "code": "", "message": f"推流中断：{exc}"}
            )

    def _on_partial(self, text: str) -> None:
        asyncio.create_task(self._emit({"event": "partial", "text": text}))
