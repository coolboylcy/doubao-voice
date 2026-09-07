"""真实打豆包 API 的 smoke test。

默认跳过（pyproject 里 addopts 有 -m 'not live'）。
显式运行：uv run pytest -m live -v

fixture 用 macOS 自带 TTS 生成而非真人录音，图的是可重现——真人录音的电平
和吐字受当时环境影响，测失败时分不清是代码坏了还是那天说得含糊。重新生成：

    say -v Tingting "今天天气不错，我正在测试豆包语音识别" -o /tmp/tts.aiff
    ffmpeg -i /tmp/tts.aiff -ar 16000 -ac 1 -c:a pcm_s16le -y tests/fixtures/hello.wav
"""

import asyncio
import wave
from pathlib import Path

import pytest

from doubao_voice import config
from doubao_voice.asr import AsrSession

FIXTURE = Path(__file__).parent / "fixtures" / "hello.wav"
CHUNK_BYTES = 6400  # 200ms @ 16k/16bit/mono


def read_pcm(path: Path) -> bytes:
    with wave.open(str(path), "rb") as w:
        assert w.getframerate() == 16000, "fixture 必须是 16kHz"
        assert w.getnchannels() == 1, "fixture 必须是单声道"
        assert w.getsampwidth() == 2, "fixture 必须是 16bit"
        return w.readframes(w.getnframes())


@pytest.mark.live
async def test_recognises_fixture_audio():
    cfg = config.load()
    partials = []
    session = AsrSession(cfg, on_partial=partials.append)
    await session.open()

    pcm = read_pcm(FIXTURE)
    for i in range(0, len(pcm), CHUNK_BYTES):
        await session.send_chunk(pcm[i : i + CHUNK_BYTES])
        await asyncio.sleep(0.02)  # 略微节流，贴近真实推流节奏

    text = await session.close_and_collect(timeout=20)

    assert "天气" in text, f"识别结果里没有「天气」：{text!r}"
    assert "语音识别" in text, f"识别结果里没有「语音识别」：{text!r}"


@pytest.mark.live
async def test_endpoint_in_config_actually_returns_text():
    """守住那次踩过的坑：2.0 只有 bigmodel_nostream 能返回文本。

    bigmodel 会 400 拒绝 seedasr，bigmodel_async 握手通过但末包不带 text。
    配置里的 endpoint 一旦被改回去，这条会立刻红。
    """
    cfg = config.load()
    session = AsrSession(cfg, on_partial=lambda _: None)
    await session.open()
    pcm = read_pcm(FIXTURE)
    for i in range(0, len(pcm), CHUNK_BYTES):
        await session.send_chunk(pcm[i : i + CHUNK_BYTES])
        await asyncio.sleep(0.02)
    assert await session.close_and_collect(timeout=20), "配置的 endpoint 没返回任何文本"
