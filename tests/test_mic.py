import asyncio

import pytest

from doubao_voice import mic


class FakeStream:
    """替身 RawInputStream，记录 start/stop 并允许手工投递音频帧。"""

    def __init__(self, **kwargs):
        self.kwargs = kwargs
        self.started = False
        self.closed = False
        self.callback = kwargs["callback"]

    def start(self):
        self.started = True

    def stop(self):
        self.started = False

    def close(self):
        self.closed = True

    def feed(self, data: bytes):
        self.callback(data, len(data) // 2, None, None)


def test_chunk_size_is_200ms_of_16k_mono_16bit():
    assert mic.BLOCKSIZE == 3200
    assert mic.BLOCKSIZE * 2 == 6400


def test_stream_is_opened_but_not_started_on_construction():
    loop = asyncio.new_event_loop()
    try:
        m = mic.Microphone(loop, stream_factory=FakeStream)
        assert m._stream.started is False
        assert m._stream.kwargs["samplerate"] == 16000
        assert m._stream.kwargs["channels"] == 1
        assert m._stream.kwargs["dtype"] == "int16"
        assert m._stream.kwargs["blocksize"] == 3200
    finally:
        loop.close()


async def test_started_stream_delivers_chunks_to_queue():
    m = mic.Microphone(asyncio.get_running_loop(), stream_factory=FakeStream)
    m.start()
    assert m._stream.started is True
    m._stream.feed(b"\x01\x02" * 3200)
    chunk = await asyncio.wait_for(m.queue.get(), timeout=1)
    assert chunk == b"\x01\x02" * 3200


async def test_start_drains_stale_chunks_from_previous_session():
    m = mic.Microphone(asyncio.get_running_loop(), stream_factory=FakeStream)
    m.start()
    m._stream.feed(b"\xaa" * 6400)
    await asyncio.sleep(0)
    m.stop()

    m.start()
    with pytest.raises(asyncio.TimeoutError):
        await asyncio.wait_for(m.queue.get(), timeout=0.2)


async def test_stop_halts_stream_without_closing_it():
    m = mic.Microphone(asyncio.get_running_loop(), stream_factory=FakeStream)
    m.start()
    m.stop()
    assert m._stream.started is False
    assert m._stream.closed is False
