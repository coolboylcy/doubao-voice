import asyncio
import json

from doubao_voice import config, daemon


def make_config(**overrides):
    data = dict(config.DEFAULTS)
    data.update({"api_key": "K"})
    data.update(overrides)
    return config.Config(**data)


class FakeMic:
    def __init__(self, loop, **_):
        self.queue = asyncio.Queue()
        self.started = False

    def start(self):
        self.started = True

    def stop(self):
        self.started = False

    def close(self):
        pass


class FakeAsr:
    instances = []

    def __init__(self, cfg, on_partial, **_):
        self.on_partial = on_partial
        self.chunks = []
        self.opened = False
        self.aborted = False
        self.final_text = "识别结果"
        self.closed = False
        FakeAsr.instances.append(self)

    async def open(self):
        self.opened = True

    async def send_chunk(self, pcm):
        self.chunks.append(pcm)

    async def close_and_collect(self, timeout=10.0):
        self.closed = True
        return self.final_text

    async def abort(self):
        self.aborted = True


def make_daemon(sock_dir, **cfg_overrides):
    FakeAsr.instances.clear()
    return daemon.Daemon(
        make_config(**cfg_overrides),
        socket_path=sock_dir / "ctl.sock",
        mic_factory=FakeMic,
        asr_factory=FakeAsr,
    )


async def connect(d):
    await d.start_server()
    return await asyncio.open_unix_connection(str(d.socket_path))


async def recv(reader, timeout=2.0):
    line = await asyncio.wait_for(reader.readline(), timeout)
    return json.loads(line)


async def send(writer, obj):
    writer.write((json.dumps(obj) + "\n").encode())
    await writer.drain()


async def test_ping_reports_ready(sock_dir):
    d = make_daemon(sock_dir)
    reader, writer = await connect(d)
    await send(writer, {"cmd": "ping"})
    assert await recv(reader) == {"event": "pong", "ready": True}
    writer.close()
    await d.stop_server()


async def test_start_opens_mic_and_asr_then_acks(sock_dir):
    d = make_daemon(sock_dir)
    reader, writer = await connect(d)
    await send(writer, {"cmd": "start"})
    assert await recv(reader) == {"event": "started"}
    assert d._mic.started is True
    assert FakeAsr.instances[0].opened is True
    writer.close()
    await d.stop_server()


async def test_audio_chunks_are_forwarded_to_asr(sock_dir):
    d = make_daemon(sock_dir)
    reader, writer = await connect(d)
    await send(writer, {"cmd": "start"})
    await recv(reader)
    d._mic.queue.put_nowait(b"\x01" * 6400)
    d._mic.queue.put_nowait(b"\x02" * 6400)
    await asyncio.sleep(0.05)
    assert FakeAsr.instances[0].chunks == [b"\x01" * 6400, b"\x02" * 6400]
    writer.close()
    await d.stop_server()


async def test_stop_emits_final_with_text(sock_dir):
    """录完一段就该把文本发出去，Lua 侧靠 final 触发注入。"""
    d = make_daemon(sock_dir, min_recording_ms=0)
    reader, writer = await connect(d)
    await send(writer, {"cmd": "start"})
    await recv(reader)
    await send(writer, {"cmd": "stop"})
    assert await recv(reader) == {"event": "final", "text": "识别结果"}
    writer.close()
    await d.stop_server()


def test_peak_amplitude_reads_16bit_little_endian():
    assert daemon.peak_amplitude(b"") == 0
    assert daemon.peak_amplitude(b"\x00\x00" * 10) == 0
    # 0x0BB8 = 3000 小端
    assert daemon.peak_amplitude(b"\xb8\x0b") == 3000
    # 负值取绝对值：-3000 = 0xF448
    assert daemon.peak_amplitude(b"\x48\xf4") == 3000
    assert daemon.peak_amplitude(b"\x00\x00\xb8\x0b\x00\x00") == 3000


async def test_dead_mic_is_rebuilt_on_start(sock_dir):
    """合盖休眠后音频设备重新枚举，握着的 stream 句柄会失效。

    daemon 是常驻的、只在启动时 open 一次麦克风，不重建的话一次休眠就够
    让热键从此哑掉，而且毫无提示。
    """
    built = []

    class DeadFirstMic(FakeMic):
        def __init__(self, loop, **kw):
            super().__init__(loop, **kw)
            self.dead = len(built) == 0
            built.append(self)

        def start(self):
            if self.dead:
                raise OSError("PortAudio: device unavailable")
            super().start()

    FakeAsr.instances.clear()
    d = daemon.Daemon(
        make_config(),
        socket_path=sock_dir / "ctl.sock",
        mic_factory=DeadFirstMic,
        asr_factory=FakeAsr,
    )
    reader, writer = await connect(d)
    await send(writer, {"cmd": "start"})

    assert await recv(reader) == {"event": "started"}
    assert len(built) == 2, "第一个 mic 打不开就该重建一个"
    assert built[1].started is True
    writer.close()
    await d.stop_server()


async def test_mic_failing_twice_reports_error_not_hang(sock_dir):
    class AlwaysDeadMic(FakeMic):
        def start(self):
            raise OSError("PortAudio: device unavailable")

    FakeAsr.instances.clear()
    d = daemon.Daemon(
        make_config(),
        socket_path=sock_dir / "ctl.sock",
        mic_factory=AlwaysDeadMic,
        asr_factory=FakeAsr,
    )
    reader, writer = await connect(d)
    await send(writer, {"cmd": "start"})

    got = await recv(reader)
    assert got["event"] == "error"
    assert "麦克风" in got["message"]
    assert FakeAsr.instances[0].aborted is True, "开麦失败要把已建的会话收掉"

    # 不能卡在半开状态：设备恢复后下一次 start 必须还能用
    d._mic_factory = FakeMic
    await send(writer, {"cmd": "start"})
    assert await recv(reader) == {"event": "started"}
    writer.close()
    await d.stop_server()


async def test_loud_chunk_reports_voiced_level(sock_dir):
    """静音判定必须靠本地音量，不能靠服务端增量——豆包 2.0 整段说完才给文本。"""
    d = make_daemon(sock_dir, voice_threshold=500)
    reader, writer = await connect(d)
    await send(writer, {"cmd": "start"})
    await recv(reader)
    d._mic.queue.put_nowait(b"\xb8\x0b" * 3200)  # 峰值 3000
    assert await recv(reader) == {"event": "level", "peak": 3000, "voiced": True}
    writer.close()
    await d.stop_server()


async def test_quiet_chunk_reports_level_but_not_voiced(sock_dir):
    """静音也要报电平（HUD 波形要贴底），但 voiced 必须是 false。"""
    d = make_daemon(sock_dir, voice_threshold=500)
    reader, writer = await connect(d)
    await send(writer, {"cmd": "start"})
    await recv(reader)
    d._mic.queue.put_nowait(b"\x64\x00" * 3200)  # 峰值 100，底噪水平
    assert await recv(reader) == {"event": "level", "peak": 100, "voiced": False}
    await asyncio.sleep(0.05)
    assert FakeAsr.instances[0].chunks, "静音也要照常推流"
    writer.close()
    await d.stop_server()


async def test_partial_results_are_broadcast(sock_dir):
    d = make_daemon(sock_dir)
    reader, writer = await connect(d)
    await send(writer, {"cmd": "start"})
    await recv(reader)
    FakeAsr.instances[0].on_partial("今天")
    assert await recv(reader) == {"event": "partial", "text": "今天"}
    writer.close()
    await d.stop_server()


async def test_stop_after_enough_audio_yields_final(sock_dir):
    d = make_daemon(sock_dir, min_recording_ms=0)
    reader, writer = await connect(d)
    await send(writer, {"cmd": "start"})
    await recv(reader)
    await send(writer, {"cmd": "stop"})
    assert await recv(reader) == {"event": "final", "text": "识别结果"}
    assert d._mic.started is False
    writer.close()
    await d.stop_server()


async def test_stop_below_min_duration_discards_without_calling_api(sock_dir):
    d = make_daemon(sock_dir, min_recording_ms=10_000)
    reader, writer = await connect(d)
    await send(writer, {"cmd": "start"})
    await recv(reader)
    await send(writer, {"cmd": "stop"})
    assert await recv(reader) == {"event": "empty"}
    assert FakeAsr.instances[0].aborted is True
    assert FakeAsr.instances[0].closed is False
    writer.close()
    await d.stop_server()


async def test_empty_recognition_reports_empty_not_final(sock_dir):
    d = make_daemon(sock_dir, min_recording_ms=0)
    reader, writer = await connect(d)
    await send(writer, {"cmd": "start"})
    await recv(reader)
    FakeAsr.instances[0].final_text = ""
    await send(writer, {"cmd": "stop"})
    assert await recv(reader) == {"event": "empty"}
    writer.close()
    await d.stop_server()


async def test_cancel_aborts_without_emitting_text(sock_dir):
    d = make_daemon(sock_dir, min_recording_ms=0)
    reader, writer = await connect(d)
    await send(writer, {"cmd": "start"})
    await recv(reader)
    await send(writer, {"cmd": "cancel"})
    assert await recv(reader) == {"event": "cancelled"}
    assert FakeAsr.instances[0].aborted is True
    assert d._mic.started is False
    writer.close()
    await d.stop_server()


async def test_start_while_already_recording_is_ignored(sock_dir):
    d = make_daemon(sock_dir)
    reader, writer = await connect(d)
    await send(writer, {"cmd": "start"})
    await recv(reader)
    await send(writer, {"cmd": "start"})
    assert await recv(reader) == {"event": "started"}
    assert len(FakeAsr.instances) == 1, "不得开第二路会话"
    writer.close()
    await d.stop_server()


async def test_stop_when_idle_is_harmless(sock_dir):
    d = make_daemon(sock_dir)
    reader, writer = await connect(d)
    await send(writer, {"cmd": "stop"})
    assert await recv(reader) == {"event": "empty"}
    writer.close()
    await d.stop_server()


async def test_unknown_command_reports_error(sock_dir):
    d = make_daemon(sock_dir)
    reader, writer = await connect(d)
    await send(writer, {"cmd": "explode"})
    got = await recv(reader)
    assert got["event"] == "error"
    assert "explode" in got["message"]
    writer.close()
    await d.stop_server()


async def test_stale_socket_file_is_replaced(sock_dir):
    path = sock_dir / "ctl.sock"
    path.write_text("stale")
    d = make_daemon(sock_dir)
    reader, writer = await connect(d)
    await send(writer, {"cmd": "ping"})
    assert (await recv(reader))["event"] == "pong"
    writer.close()
    await d.stop_server()


async def test_socket_file_is_owner_only(sock_dir):
    d = make_daemon(sock_dir)
    reader, writer = await connect(d)
    assert d.socket_path.stat().st_mode & 0o777 == 0o600
    writer.close()
    await d.stop_server()


async def test_failed_connect_leaves_daemon_recordable(sock_dir):
    """建连失败后不能卡在半开状态，下一次 start 必须还能用。"""

    class FlakyAsr(FakeAsr):
        fail_next = True

        async def open(self):
            if FlakyAsr.fail_next:
                FlakyAsr.fail_next = False
                raise OSError("网络不可达")
            self.opened = True

    FakeAsr.instances.clear()
    d = daemon.Daemon(
        make_config(),
        socket_path=sock_dir / "ctl.sock",
        mic_factory=FakeMic,
        asr_factory=FlakyAsr,
    )
    reader, writer = await connect(d)

    await send(writer, {"cmd": "start"})
    got = await recv(reader)
    assert got["event"] == "error"
    assert "网络不可达" in got["message"]

    await send(writer, {"cmd": "start"})
    assert await recv(reader) == {"event": "started"}

    writer.close()
    await d.stop_server()
