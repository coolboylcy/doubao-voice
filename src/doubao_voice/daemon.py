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
        # 对话模式：本轮是否是对话、会话延续 id、正在跑的那轮
        self._is_chat = False
        self._chat_session: str | None = None
        self._chat_task: asyncio.Task | None = None
        self._speaker = None

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
        elif cmd == "chat_start":
            await self.cmd_start(chat=True)
        elif cmd == "chat_stop":
            await self.cmd_stop()
        elif cmd == "chat_interrupt":
            await self.cmd_chat_interrupt()
        elif cmd == "chat_reset":
            self._chat_session = None
            await self._emit({"event": "chat_reset"})
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

    async def cmd_start(self, *, chat: bool = False) -> None:
        async with self._lock:
            self._is_chat = chat
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
                await asr.abort()
                await self._emit({"event": "empty"})
                return

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

            if self._is_chat:
                await self._emit({"event": "chat_heard", "text": text})
                self._chat_task = asyncio.create_task(self._run_chat(text))
            else:
                await self._emit({"event": "final", "text": text})

    async def cmd_chat_interrupt(self) -> None:
        """打断只停嘴，不动 Claude 手上的活。

        跑到一半的 npm test 或 git 操作被砍会留下烂摊子，而且你打断多半是
        想补一句而不是撤销。那轮继续跑完，输出丢掉即可。
        """
        stopped = self._speaker.stop() if self._speaker else False
        await self._emit({"event": "chat_interrupted", "was_speaking": stopped})

    async def _run_chat(self, prompt: str) -> None:
        from . import agent, frontcwd
        from .tts import Speaker

        if self._speaker is None:
            self._speaker = Speaker()

        try:
            cwd = await frontcwd.resolve()
            await self._emit({"event": "chat_thinking", "cwd": cwd})

            async for event in agent.converse(
                prompt, cwd=cwd, session_id=self._chat_session
            ):
                if isinstance(event, agent.Speech):
                    await self._emit({"event": "chat_speech", "text": event.text})
                    await self._speaker.say(event.text)
                elif isinstance(event, agent.Action):
                    await self._emit(
                        {"event": "chat_action", "tool": event.tool, "brief": event.brief}
                    )
                elif isinstance(event, agent.Done):
                    # 会话延续省钱：实测首轮 $0.31，resume 后每轮 $0.02
                    self._chat_session = event.session_id or self._chat_session
                    await self._emit(
                        {
                            "event": "chat_done",
                            "cost_usd": event.cost_usd,
                            "duration_ms": event.duration_ms,
                        }
                    )
                elif isinstance(event, agent.Failed):
                    await self._emit(
                        {"event": "error", "code": "", "message": event.message}
                    )
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            log.exception("对话出错")
            await self._emit({"event": "error", "code": "", "message": str(exc)})
        finally:
            self._chat_task = None

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
                # 每包都报电平：voiced 供状态机做静音判定，peak 供 HUD 画波形。
                await self._emit(
                    {
                        "event": "level",
                        "peak": peak,
                        "voiced": peak >= self.cfg.voice_threshold,
                    }
                )
                await asr.send_chunk(chunk)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            log.warning("推流中断：%s", exc)
            await self._emit(
                {"event": "error", "code": "", "message": f"推流中断：{exc}"}
            )

    def _on_partial(self, text: str) -> None:
        asyncio.create_task(self._emit({"event": "partial", "text": text}))
