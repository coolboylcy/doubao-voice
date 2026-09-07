"""本地 FunASR（GGUF / llama.cpp 运行时）识别后端。

与 `asr.AsrSession` 同接口——`open` / `send_chunk` / `close_and_collect` /
`abort`——所以 `daemon.Daemon` 不需要知道用的是哪个后端，换后端只改
`asr_factory`。

跟豆包那条路的根本区别：没有服务端。豆包是边说边把 PCM 推上去、末包才
拿到文本；本地这边 `send_chunk` 只往内存缓冲追加，`close_and_collect`
时才落成一个 WAV 交给 `llama-funasr-sensevoice` 转写。

这不是妥协。豆包 2.0 的 `nostream` 本来就是「流式输入、一次性输出」，
中途一个非空结果都没有（见 README「没有实时字幕」），所以两条路给用户
的体验完全一样，而本地这条还省掉一趟网络往返——实测 4.2 秒音频总耗时
0.6 秒，比豆包的 1–2 秒更快。

SenseVoiceSmall 自带标点与 ITN（原始输出带 `<|withitn|>` 标记），不需要
另挂标点模型，`enable_punc` / `enable_itn` 那两个配置项对本地后端无效。
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import os
import re
import tempfile
import wave
from collections.abc import Callable
from pathlib import Path

from .asr import BITS, CHANNELS, RATE, AsrError
from .config import CONFIG_DIR, Config

log = logging.getLogger("dbvoiced")

# 本地失败没有服务端错误码，统一用 -1，好跟豆包的真实错误码区分开
LOCAL_ERROR = -1

# 二进制默认已经剥掉了 `<|zh|><|NEUTRAL|>` 这类富文本标签（要保留得显式
# 传 --keep-tags）。这里再兜一层：万一将来默认行为变了，不至于把标签
# 直接注入到用户的光标处。
_TAG = re.compile(r"<\|[^|]*\|>")

# VAD 分段拼接处会留下重复的句末标点（实测三段音频结尾出现「。。」）。
_DUP_PUNCT = re.compile(r"([。！？，、；：])\1+")


def clean_text(raw: str) -> str:
    """把二进制的 stdout 收拾成可以直接上屏的文本。"""
    text = _TAG.sub("", raw).strip()
    return _DUP_PUNCT.sub(r"\1", text)


def write_wav(path: Path, pcm: bytes) -> None:
    with wave.open(str(path), "wb") as w:
        w.setnchannels(CHANNELS)
        w.setsampwidth(BITS // 8)
        w.setframerate(RATE)
        w.writeframes(pcm)


class LocalAsrSession:
    """一次本地识别：缓冲 PCM → 落 WAV → 跑二进制 → 出文本。"""

    def __init__(
        self,
        cfg: Config,
        on_partial: Callable[[str], None],
        *,
        run=None,
    ):
        self._cfg = cfg
        # 本地后端没有中间结果可报，留着这个参数只为跟 AsrSession 同签名
        self._on_partial = on_partial
        self._run = run or self._run_binary
        self._chunks: list[bytes] = []
        self.closed = False

    async def open(self) -> None:
        """检查二进制与模型在不在。

        故意放在 open 而不是识别时才查：daemon 的 cmd_start 会把 open 的
        异常报成「建连失败」并且不开麦，用户按下键立刻就知道没装好，而不是
        说完一段话才发现白说了。
        """
        for label, path in (
            ("二进制", self._cfg.funasr_bin_path),
            ("模型", self._cfg.funasr_model_path),
            ("VAD 模型", self._cfg.funasr_vad_path),
        ):
            if not path.exists():
                raise AsrError(
                    LOCAL_ERROR,
                    f"FunASR {label} 不存在：{path}——跑 `dbvoice fetch-model` 装",
                )

    async def send_chunk(self, pcm: bytes) -> None:
        self._chunks.append(pcm)

    async def close_and_collect(self, timeout: float | None = None) -> str:
        """转写缓冲里的音频。超时抛 asyncio.TimeoutError（daemon 会处理）。"""
        self.closed = True
        pcm = b"".join(self._chunks)
        self._chunks.clear()
        if not pcm:
            return ""

        limit = timeout if timeout is not None else float(self._cfg.funasr_timeout_s)
        # 音频落在配置目录下（700 权限）而不是 /tmp，别把用户说的话摊在
        # 全局可读的地方
        tmp_dir = CONFIG_DIR / "tmp"
        tmp_dir.mkdir(parents=True, exist_ok=True)
        tmp_dir.chmod(0o700)
        fd, name = tempfile.mkstemp(suffix=".wav", prefix="utter-", dir=str(tmp_dir))
        wav = Path(name)
        try:
            os.close(fd)
            write_wav(wav, pcm)
            return clean_text(await asyncio.wait_for(self._run(wav), limit))
        finally:
            with contextlib.suppress(OSError):
                wav.unlink()

    async def abort(self) -> None:
        self.closed = True
        self._chunks.clear()

    # ---- 内部 ----

    async def _run_binary(self, wav: Path) -> str:
        cfg = self._cfg
        argv = [
            str(cfg.funasr_bin_path),
            "-m",
            str(cfg.funasr_model_path),
            # --vad 是必需的，不是优化项：不挂它，静音输入会幻觉出「我.」
            # 这类短词，PTT 误触就会往光标处插垃圾字。实测见 README。
            "--vad",
            str(cfg.funasr_vad_path),
            "-a",
            str(wav),
        ]
        proc = await asyncio.create_subprocess_exec(
            *argv,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            out, err = await proc.communicate()
        except asyncio.CancelledError:
            proc.kill()
            raise

        if proc.returncode != 0:
            # 诊断信息全在 stderr，只取尾部——前面是逐层的图分配日志，没用
            tail = err.decode("utf-8", "replace").strip().splitlines()[-3:]
            raise AsrError(
                LOCAL_ERROR,
                f"FunASR 退出码 {proc.returncode}：{' / '.join(tail)}",
            )

        log.debug("funasr stderr: %s", err.decode("utf-8", "replace")[-500:])
        return out.decode("utf-8", "replace")
