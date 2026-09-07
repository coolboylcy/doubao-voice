import asyncio
import wave

import pytest

from doubao_voice import config as c
from doubao_voice.asr import AsrError
from doubao_voice.funasr_local import LocalAsrSession, clean_text, write_wav


def make_config(**overrides):
    data = dict(c.DEFAULTS)
    data.update(overrides)
    return c.Config(**data)


def installed(tmp_path, **overrides):
    """一份「二进制与模型都在」的配置——open() 只查存在性，内容无所谓。"""
    for name in ("bin", "model", "vad"):
        (tmp_path / name).write_bytes(b"x")
    fields = {
        "funasr_bin": str(tmp_path / "bin"),
        "funasr_model": str(tmp_path / "model"),
        "funasr_vad": str(tmp_path / "vad"),
    }
    fields.update(overrides)  # 调用方可以覆盖，比如把 bin 换成 shell 桩
    return make_config(**fields)


# ---- 文本清理 ----


def test_strips_rich_transcription_tags():
    raw = "<|zh|><|NEUTRAL|><|Speech|><|withitn|>今天天气不错。"
    assert clean_text(raw) == "今天天气不错。"


def test_collapses_punctuation_duplicated_at_vad_seam():
    # VAD 分段拼接处实测会留下「。。」
    assert clean_text("我正在测试。。") == "我正在测试。"
    assert clean_text("啊？？？") == "啊？"


def test_keeps_legitimate_mixed_punctuation():
    assert clean_text("好了，真的吗？") == "好了，真的吗？"


def test_trims_trailing_newline_from_stdout():
    assert clean_text("你好\n") == "你好"


# ---- WAV 落盘 ----


def test_write_wav_is_16k_mono_16bit(tmp_path):
    path = tmp_path / "a.wav"
    write_wav(path, b"\x01\x02" * 1000)
    with wave.open(str(path)) as w:
        assert w.getframerate() == 16000
        assert w.getnchannels() == 1
        assert w.getsampwidth() == 2
        assert w.getnframes() == 1000


# ---- open() 的前置检查 ----


async def test_open_reports_which_file_is_missing(tmp_path):
    cfg = make_config(
        funasr_bin=str(tmp_path / "nope"),
        funasr_model=str(tmp_path / "m"),
        funasr_vad=str(tmp_path / "v"),
    )
    s = LocalAsrSession(cfg, lambda _: None)
    with pytest.raises(AsrError) as e:
        await s.open()
    # 报出具体缺哪个文件和怎么修，别只说"失败"
    assert "二进制" in str(e.value)
    assert "fetch-model" in str(e.value)


async def test_open_passes_when_everything_installed(tmp_path):
    s = LocalAsrSession(installed(tmp_path), lambda _: None)
    await s.open()  # 不抛即通过


# ---- 缓冲与转写 ----


async def test_buffers_chunks_and_passes_full_audio_to_runner(tmp_path):
    seen = {}

    async def fake_run(wav):
        with wave.open(str(wav)) as w:
            seen["frames"] = w.getnframes()
        return "识别结果"

    s = LocalAsrSession(installed(tmp_path), lambda _: None, run=fake_run)
    await s.open()
    await s.send_chunk(b"\x01\x02" * 500)
    await s.send_chunk(b"\x03\x04" * 500)
    assert await s.close_and_collect() == "识别结果"
    assert seen["frames"] == 1000


async def test_empty_buffer_short_circuits_without_running_binary(tmp_path):
    async def fake_run(wav):
        raise AssertionError("空音频不该跑二进制")

    s = LocalAsrSession(installed(tmp_path), lambda _: None, run=fake_run)
    await s.open()
    assert await s.close_and_collect() == ""


async def test_result_goes_through_clean_text(tmp_path):
    async def fake_run(wav):
        return "<|zh|><|NEUTRAL|>好的。。\n"

    s = LocalAsrSession(installed(tmp_path), lambda _: None, run=fake_run)
    await s.open()
    await s.send_chunk(b"\x01\x02" * 100)
    assert await s.close_and_collect() == "好的。"


async def test_temp_wav_is_removed_even_when_runner_raises(tmp_path):
    captured = {}

    async def fake_run(wav):
        captured["path"] = wav
        raise AsrError(-1, "炸了")

    s = LocalAsrSession(installed(tmp_path), lambda _: None, run=fake_run)
    await s.open()
    await s.send_chunk(b"\x01\x02" * 100)
    with pytest.raises(AsrError):
        await s.close_and_collect()
    assert not captured["path"].exists()


async def test_abort_discards_buffer(tmp_path):
    async def fake_run(wav):
        raise AssertionError("abort 之后不该还去识别")

    s = LocalAsrSession(installed(tmp_path), lambda _: None, run=fake_run)
    await s.open()
    await s.send_chunk(b"\x01\x02" * 100)
    await s.abort()
    assert s.closed
    assert await s.close_and_collect() == ""


async def test_timeout_surfaces_as_timeout_error(tmp_path):
    async def slow_run(wav):
        await asyncio.sleep(5)
        return "太慢了"

    # daemon 把 asyncio.TimeoutError 报成「等待识别结果超时」，
    # 所以这里必须是 TimeoutError 而不是 AsrError
    s = LocalAsrSession(
        installed(tmp_path, funasr_timeout_s=1), lambda _: None, run=slow_run
    )
    await s.open()
    await s.send_chunk(b"\x01\x02" * 100)
    with pytest.raises(asyncio.TimeoutError):
        await s.close_and_collect(timeout=0.05)


# ---- 真跑子进程（不依赖模型，用 shell 桩） ----


async def test_nonzero_exit_becomes_asr_error(tmp_path):
    stub = tmp_path / "stub.sh"
    stub.write_text("#!/bin/sh\necho '模型加载失败' >&2\nexit 3\n")
    stub.chmod(0o755)
    cfg = installed(tmp_path, funasr_bin=str(stub))
    s = LocalAsrSession(cfg, lambda _: None)
    await s.open()
    await s.send_chunk(b"\x01\x02" * 100)
    with pytest.raises(AsrError) as e:
        await s.close_and_collect()
    assert "退出码 3" in str(e.value)
    assert "模型加载失败" in str(e.value)


async def test_stdout_is_the_transcript(tmp_path):
    stub = tmp_path / "stub.sh"
    # 诊断信息走 stderr 不该混进结果里
    stub.write_text("#!/bin/sh\necho '[sensevoice] done' >&2\necho '你好世界。'\n")
    stub.chmod(0o755)
    cfg = installed(tmp_path, funasr_bin=str(stub))
    s = LocalAsrSession(cfg, lambda _: None)
    await s.open()
    await s.send_chunk(b"\x01\x02" * 100)
    assert await s.close_and_collect() == "你好世界。"


async def test_stderr_diagnostics_do_not_leak_into_result(tmp_path):
    stub = tmp_path / "stub.sh"
    stub.write_text("#!/bin/sh\necho 'graph allocated' >&2\necho '结果'\n")
    stub.chmod(0o755)
    s = LocalAsrSession(installed(tmp_path, funasr_bin=str(stub)), lambda _: None)
    await s.open()
    await s.send_chunk(b"\x01\x02" * 100)
    text = await s.close_and_collect()
    assert text == "结果"
    assert "graph" not in text


async def test_vad_is_always_passed_to_the_binary(tmp_path):
    """--vad 不是可选优化：缺了它静音会被识别成「我.」，误触就插垃圾字。"""
    stub = tmp_path / "stub.sh"
    stub.write_text('#!/bin/sh\necho "$@"\n')
    stub.chmod(0o755)
    cfg = installed(tmp_path, funasr_bin=str(stub))
    s = LocalAsrSession(cfg, lambda _: None)
    await s.open()
    await s.send_chunk(b"\x01\x02" * 100)
    argv = await s.close_and_collect()
    assert "--vad" in argv
    assert str(cfg.funasr_vad_path) in argv


# ---- 真模型集成（装了就跑；本地推理不花钱，不需要 live 标记） ----

_REAL = c.Config(**c.DEFAULTS)
_HAVE_MODEL = (
    _REAL.funasr_bin_path.exists()
    and _REAL.funasr_model_path.exists()
    and _REAL.funasr_vad_path.exists()
)


@pytest.mark.skipif(not _HAVE_MODEL, reason="没装 FunASR 模型，跑 dbvoice fetch-model")
async def test_real_model_transcribes_the_fixture():
    from pathlib import Path

    fixture = Path(__file__).parent / "fixtures" / "hello.wav"
    with wave.open(str(fixture)) as w:
        pcm = w.readframes(w.getnframes())

    s = LocalAsrSession(_REAL, lambda _: None)
    await s.open()
    for i in range(0, len(pcm), 3200):
        await s.send_chunk(pcm[i : i + 3200])
    text = await s.close_and_collect()

    assert "天气" in text
    assert "语音识别" in text
    # 自带标点，不需要另挂标点模型
    assert text.endswith("。")
    # 富文本标签绝不能上屏
    assert "<|" not in text


@pytest.mark.skipif(not _HAVE_MODEL, reason="没装 FunASR 模型，跑 dbvoice fetch-model")
async def test_real_model_returns_empty_on_silence():
    """守住那个坑：不挂 --vad 时静音会被识别成「我.」，误触就往光标插垃圾字。"""
    s = LocalAsrSession(_REAL, lambda _: None)
    await s.open()
    await s.send_chunk(b"\x00\x00" * 16000 * 2)  # 2 秒纯静音
    assert await s.close_and_collect() == ""
