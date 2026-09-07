import asyncio
import json
import struct

import pytest
import websockets

from doubao_voice import asr, config
from doubao_voice import protocol as p


def make_config(**overrides):
    data = dict(config.DEFAULTS)
    data.update({"api_key": "K"})
    data.update(overrides)
    return config.Config(**data)


# ---- 纯函数：请求载荷与结果提取 ----


def test_request_payload_declares_16k_mono_pcm():
    payload = json.loads(asr.build_request_payload(make_config(), uid="u1"))
    assert payload["audio"] == {
        "format": "pcm",
        "codec": "raw",
        "rate": 16000,
        "bits": 16,
        "channel": 1,
        "language": "zh-CN",
    }


def test_request_payload_enables_itn_punc_and_utterances():
    payload = json.loads(asr.build_request_payload(make_config(), uid="u1"))
    req = payload["request"]
    assert req["enable_itn"] is True
    assert req["enable_punc"] is True
    assert req["show_utterances"] is True
    assert req["result_type"] == "full"
    assert req["end_window_size"] == 800


def test_request_payload_platform_is_linux_per_official_enum():
    # 官方 platform 枚举只有 iOS / Android / Linux，没有 macOS
    payload = json.loads(asr.build_request_payload(make_config(), uid="u1"))
    assert payload["user"]["platform"] == "Linux"
    assert payload["user"]["uid"] == "u1"


def test_request_payload_honours_config_overrides():
    cfg = make_config(language="en-US", enable_punc=False, model_name="seedasr")
    payload = json.loads(asr.build_request_payload(cfg, uid="u1"))
    assert payload["audio"]["language"] == "en-US"
    assert payload["request"]["enable_punc"] is False
    assert payload["request"]["model_name"] == "seedasr"


def test_extract_text_reads_cumulative_result():
    body = json.dumps({"result": {"text": "今天天气不错。"}}).encode()
    assert asr.extract_text(body) == "今天天气不错。"


def test_extract_text_tolerates_missing_result():
    assert asr.extract_text(b"{}") == ""
    assert asr.extract_text(json.dumps({"result": None}).encode()) == ""
    assert asr.extract_text(json.dumps({"result": {}}).encode()) == ""


# ---- WebSocket 会话：用假服务端回放，不打真 API ----


def server_response(text: str, sequence: int) -> bytes:
    """构造一个服务端识别结果帧。sequence 为负表示末包。"""
    flags = p.NEG_WITH_SEQUENCE if sequence < 0 else p.POS_SEQUENCE
    payload = json.dumps({"result": {"text": text}}).encode("utf-8")
    return p.build_frame(p.FULL_SERVER_RESPONSE, flags, payload, sequence=sequence)


class FakeServer:
    """回放固定序列的服务端帧，同时记录客户端发来的帧。"""

    def __init__(self, script):
        self.script = list(script)
        self.received = []
        self._server = None

    async def _handler(self, ws):
        try:
            async for raw in ws:
                self.received.append(p.parse_frame(raw))
                if self.script:
                    await ws.send(self.script.pop(0))
        except websockets.ConnectionClosed:
            pass

    async def __aenter__(self):
        self._server = await websockets.serve(self._handler, "127.0.0.1", 0)
        self.port = self._server.sockets[0].getsockname()[1]
        return self

    async def __aexit__(self, *exc):
        self._server.close()
        await self._server.wait_closed()


async def test_session_sends_request_then_audio_then_terminator():
    script = [
        server_response("今天", 2),
        server_response("今天天气", 3),
        server_response("今天天气不错。", -4),
    ]
    async with FakeServer(script) as srv:
        cfg = make_config(endpoint=f"ws://127.0.0.1:{srv.port}")
        partials = []
        session = asr.AsrSession(cfg, on_partial=partials.append)
        await session.open()
        await session.send_chunk(b"\x00" * 6400)
        await session.send_chunk(b"\x00" * 6400)
        text = await session.close_and_collect(timeout=5)

    assert text == "今天天气不错。"
    assert partials == ["今天", "今天天气", "今天天气不错。"]

    kinds = [(f.message_type, f.sequence) for f in srv.received]
    assert kinds[0] == (p.FULL_CLIENT_REQUEST, 1)
    assert kinds[1] == (p.AUDIO_ONLY_REQUEST, 2)
    assert kinds[2] == (p.AUDIO_ONLY_REQUEST, 3)
    assert kinds[3][0] == p.AUDIO_ONLY_REQUEST
    assert kinds[3][1] < 0, "末包必须用负序列号"


async def test_session_surfaces_server_error():
    payload = json.dumps({"message": "等包超时"}).encode("utf-8")
    frame = (
        p.build_header(
            p.ERROR_RESPONSE, p.NO_SEQUENCE, p.JSON_SERIALIZATION, p.NO_COMPRESSION
        )
        + struct.pack(">I", 45000081)
        + struct.pack(">I", len(payload))
        + payload
    )
    async with FakeServer([frame]) as srv:
        cfg = make_config(endpoint=f"ws://127.0.0.1:{srv.port}")
        session = asr.AsrSession(cfg, on_partial=lambda _: None)
        await session.open()
        await session.send_chunk(b"\x00" * 6400)
        with pytest.raises(asr.AsrError) as exc:
            await session.close_and_collect(timeout=5)

    assert exc.value.code == 45000081
    assert "等包超时" in str(exc.value)


async def test_session_times_out_when_server_never_finalises():
    async with FakeServer([]) as srv:
        cfg = make_config(endpoint=f"ws://127.0.0.1:{srv.port}")
        session = asr.AsrSession(cfg, on_partial=lambda _: None)
        await session.open()
        with pytest.raises(asyncio.TimeoutError):
            await session.close_and_collect(timeout=0.3)
        await session.abort()


async def test_abort_closes_without_waiting_for_final():
    async with FakeServer([server_response("半句", 2)]) as srv:
        cfg = make_config(endpoint=f"ws://127.0.0.1:{srv.port}")
        session = asr.AsrSession(cfg, on_partial=lambda _: None)
        await session.open()
        await session.send_chunk(b"\x00" * 6400)
        await session.abort()
    assert session.closed


async def test_last_packet_is_detected_by_flags_not_sequence_sign():
    """实测服务端末包 flags=0x3 但 sequence 是正数，按符号判定会卡到超时。"""
    payload = json.dumps({"result": {"text": "结束了。"}}).encode("utf-8")
    last = p.build_frame(
        p.FULL_SERVER_RESPONSE, p.NEG_WITH_SEQUENCE, payload, sequence=1
    )
    async with FakeServer([last]) as srv:
        cfg = make_config(endpoint=f"ws://127.0.0.1:{srv.port}")
        session = asr.AsrSession(cfg, on_partial=lambda _: None)
        await session.open()
        await session.send_chunk(b"\x00" * 6400)
        assert await session.close_and_collect(timeout=3) == "结束了。"


async def test_empty_final_packet_does_not_wipe_recognised_text():
    """末包只带 audio_info 不带 result.text 时，前面识别出的整句必须保住。"""
    bare = json.dumps({"audio_info": {"duration": 1000}}).encode("utf-8")
    script = [
        server_response("今天天气不错。", 2),
        p.build_frame(p.FULL_SERVER_RESPONSE, p.NEG_WITH_SEQUENCE, bare, sequence=3),
    ]
    async with FakeServer(script) as srv:
        cfg = make_config(endpoint=f"ws://127.0.0.1:{srv.port}")
        session = asr.AsrSession(cfg, on_partial=lambda _: None)
        await session.open()
        await session.send_chunk(b"\x00" * 6400)
        await session.send_chunk(b"\x00" * 6400)
        assert await session.close_and_collect(timeout=3) == "今天天气不错。"


async def test_server_closing_connection_releases_waiter():
    """服务端正常关连接时 async for 静默退出，不能让调用方卡到超时。"""

    async def handler(ws):
        await ws.recv()
        await ws.close()

    server = await websockets.serve(handler, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    try:
        cfg = make_config(endpoint=f"ws://127.0.0.1:{port}")
        session = asr.AsrSession(cfg, on_partial=lambda _: None)
        await session.open()
        await asyncio.sleep(0.2)
        with pytest.raises(Exception):  # 连接已关，发末包会失败
            await session.close_and_collect(timeout=3)
    finally:
        server.close()
        await server.wait_closed()


async def test_auth_headers_are_sent_on_handshake():
    seen = {}

    async def handler(ws):
        # Headers 是 case-insensitive multidict，直接 dict() 会丢字段
        seen.update(dict(ws.request.headers.raw_items()))
        async for _ in ws:
            pass

    server = await websockets.serve(handler, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    try:
        cfg = make_config(endpoint=f"ws://127.0.0.1:{port}")
        session = asr.AsrSession(cfg, on_partial=lambda _: None)
        await session.open()
        await asyncio.sleep(0.1)
        await session.abort()
    finally:
        server.close()
        await server.wait_closed()

    assert seen["X-Api-Key"] == "K"
    assert seen["X-Api-Sequence"] == "-1"
    assert seen["X-Api-Resource-Id"] == config.DEFAULTS["resource_id"]
