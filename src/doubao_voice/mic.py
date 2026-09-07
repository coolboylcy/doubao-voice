"""麦克风采集：16kHz / 16bit / 单声道，200ms 一包。

stream 在构造时 open 但不 start。这一点是刻意的：start() 极快，
而 macOS 的麦克风使用指示器只在 start 之后才亮，所以 daemon 可以
常驻而不让菜单栏一直显示"正在使用麦克风"。
"""

from __future__ import annotations

import asyncio

RATE = 16000
CHANNELS = 1
DTYPE = "int16"
CHUNK_MS = 200
BLOCKSIZE = RATE * CHUNK_MS // 1000  # 3200 帧 → 6400 字节


def _default_stream_factory(**kwargs):
    import sounddevice

    return sounddevice.RawInputStream(**kwargs)


class Microphone:
    def __init__(self, loop: asyncio.AbstractEventLoop, *, stream_factory=None):
        self._loop = loop
        self.queue: asyncio.Queue[bytes] = asyncio.Queue()
        factory = stream_factory or _default_stream_factory
        self._stream = factory(
            samplerate=RATE,
            channels=CHANNELS,
            dtype=DTYPE,
            blocksize=BLOCKSIZE,
            callback=self._callback,
        )

    def _callback(self, indata, frames, time_info, status) -> None:
        # 该回调运行在 PortAudio 的音频线程上，必须跨线程投递。
        self._loop.call_soon_threadsafe(self.queue.put_nowait, bytes(indata))

    def start(self) -> None:
        while not self.queue.empty():
            self.queue.get_nowait()
        self._stream.start()

    def stop(self) -> None:
        self._stream.stop()

    def close(self) -> None:
        self._stream.close()
