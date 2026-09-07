"""豆包流式 ASR 的 WebSocket 会话。

本模块不知道有麦克风，也不知道有控制 socket——调用方喂 PCM 分片，
它吐识别文本。
"""

from __future__ import annotations

import asyncio
import json
import uuid
from collections.abc import Callable

import websockets

from . import protocol as p
from .config import Config

RATE = 16000
BITS = 16
CHANNELS = 1


def build_request_payload(cfg: Config, uid: str) -> bytes:
    """构造 full client request 的 JSON 载荷。"""
    return json.dumps(
        {
            # 官方 platform 枚举只有 iOS / Android / Linux，无 macOS，
            # 取最接近的 Linux。该字段仅用于服务端统计，不影响识别。
            "user": {"uid": uid, "platform": "Linux"},
            "audio": {
                "format": "pcm",
                "codec": "raw",
                "rate": RATE,
                "bits": BITS,
                "channel": CHANNELS,
                "language": cfg.language,
            },
            "request": {
                "model_name": cfg.model_name,
                "enable_itn": cfg.enable_itn,
                "enable_punc": cfg.enable_punc,
                "enable_ddc": False,
                "result_type": "full",
                "end_window_size": cfg.end_window_size,
                "show_utterances": True,
            },
        },
        ensure_ascii=False,
    ).encode("utf-8")


def extract_text(payload: bytes) -> str:
    """从服务端响应里取识别文本。

    注意 result.text 是**累积**文本而非增量，调用方直接整体替换显示即可，
    不要做拼接。
    """
    data = json.loads(payload)
    result = data.get("result") or {}
    return result.get("text") or ""


def _is_last_packet(frame) -> bool:
    """判断是否服务端的末包。

    只看 flags 的末包位，不看 sequence 的符号。文档把 flags=0x3 描述成
    "负序列号（最后一包）"，但实测服务端末包的 sequence 是正数（例如 1），
    按符号判定会永远判不到末包、每次都等到超时。
    """
    return bool(frame.flags & p.NEG_SEQUENCE)


class AsrError(Exception):
    def __init__(self, code: int, message: str):
        super().__init__(f"[{code}] {message}")
        self.code = code
        self.message = message


class AsrSession:
    """一次识别会话：建连 → 推流 → 收尾。

    序列号从 1 开始，1 号是 full client request，此后每包音频递增。
    末包用负序列号（NEG_WITH_SEQUENCE）标识。
    """

    def __init__(
        self,
        cfg: Config,
        on_partial: Callable[[str], None],
        *,
        uid: str | None = None,
        connect=websockets.connect,
    ):
        self._cfg = cfg
        self._on_partial = on_partial
        self._uid = uid or str(uuid.getnode())
        self._connect = connect
        self._ws = None
        self._seq = 0
        self._text = ""
        self._error: AsrError | None = None
        self._done = asyncio.Event()
        self._recv_task: asyncio.Task | None = None
        self.closed = False

    async def open(self) -> None:
        self._ws = await self._connect(
            self._cfg.endpoint, additional_headers=self._cfg.auth_headers()
        )
        self._seq = 1
        await self._ws.send(
            p.build_frame(
                p.FULL_CLIENT_REQUEST,
                p.POS_SEQUENCE,
                build_request_payload(self._cfg, self._uid),
                sequence=self._seq,
            )
        )
        self._recv_task = asyncio.create_task(self._recv_loop())

    async def send_chunk(self, pcm: bytes) -> None:
        self._seq += 1
        await self._ws.send(
            p.build_frame(
                p.AUDIO_ONLY_REQUEST,
                p.POS_SEQUENCE,
                pcm,
                sequence=self._seq,
                serialization=p.NO_SERIALIZATION,
            )
        )

    async def close_and_collect(self, timeout: float = 10.0) -> str:
        """发末包并等最终结果。超时抛 asyncio.TimeoutError。"""
        self._seq += 1
        await self._ws.send(
            p.build_frame(
                p.AUDIO_ONLY_REQUEST,
                p.NEG_WITH_SEQUENCE,
                b"",
                sequence=-self._seq,
                serialization=p.NO_SERIALIZATION,
            )
        )
        try:
            await asyncio.wait_for(self._done.wait(), timeout)
        finally:
            if self._done.is_set():
                await self._shutdown()
        if self._error:
            raise self._error
        return self._text

    async def abort(self) -> None:
        """丢弃本次会话，不等结果。"""
        await self._shutdown()

    async def _shutdown(self) -> None:
        if self.closed:
            return
        self.closed = True
        if self._recv_task:
            self._recv_task.cancel()
        if self._ws:
            await self._ws.close()

    async def _recv_loop(self) -> None:
        try:
            async for raw in self._ws:
                frame = p.parse_frame(raw)
                if frame.message_type == p.ERROR_RESPONSE:
                    try:
                        message = json.loads(frame.payload).get("message", "")
                    except (json.JSONDecodeError, UnicodeDecodeError):
                        message = frame.payload[:200].decode("utf-8", "replace")
                    self._error = AsrError(frame.error_code or 0, message)
                    self._done.set()
                    return
                if frame.message_type == p.FULL_SERVER_RESPONSE:
                    text = extract_text(frame.payload)
                    # 只在非空时覆盖：末包偶尔只带 audio_info 不带 result.text，
                    # 直接赋值会把前面已识别出的整句清掉。
                    if text:
                        self._text = text
                        self._on_partial(text)
                    if _is_last_packet(frame):
                        self._done.set()
                        return
            # 服务端正常关闭时 async for 是静默退出的，不抛 ConnectionClosed，
            # 这条路径同样要放行等待方，否则调用方一直卡到超时。
            self._done.set()
        except asyncio.CancelledError:
            raise
        except websockets.ConnectionClosed:
            self._done.set()
