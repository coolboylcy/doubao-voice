"""配置加载与鉴权 header 形态判定。

鉴权有新旧两种形态（见 spec 第 3 节）：新版控制台签发单个 X-Api-Key，
老版签发 AppID + Access Token 两个值。用户不需要声明自己是哪种，
auth_style 依据配置里出现了哪些字段自动判定。
"""

from __future__ import annotations

import json
import os
import uuid
from dataclasses import dataclass
from pathlib import Path

CONFIG_DIR = Path.home() / ".doubao-voice"
CONFIG_PATH = CONFIG_DIR / "config.json"
SOCKET_PATH = CONFIG_DIR / "ctl.sock"

DEFAULTS: dict[str, object] = {
    # 识别后端。doubao = 火山引擎流式 ASR，要凭证、按小时计费，是默认；
    # funasr = 本地 GGUF 推理，免费离线，但仅 Apple Silicon 且尚未在真人
    # 按键路径上验收通过（作者实测遇到 HUD 停在"识别中"，未能复现定位），
    # 当实验特性用。
    "backend": "doubao",
    # 本地后端：二进制与模型的位置，由 `dbvoice fetch-model` 装到这里
    "funasr_bin": "~/.doubao-voice/funasr/bin/llama-funasr-sensevoice",
    "funasr_model": "~/.doubao-voice/funasr/gguf/sensevoice-small-q8.gguf",
    # VAD 不是可选优化：不挂它，静音输入会幻觉出「我.」之类的短词，
    # 误触就会往光标处插垃圾字。实测见 README。
    "funasr_vad": "~/.doubao-voice/funasr/gguf/fsmn-vad.gguf",
    "funasr_timeout_s": 30,
    "app_id": "",
    "api_key": "",
    "access_key": "",
    # 默认对准 2.0（seedasr）。别改回 1.0 的 volc.bigasr.sauc.duration +
    # /bigmodel——那个端点会 400 拒绝 seedasr，详见 README「endpoint 千万别
    # 改回 bigmodel」一节。
    "resource_id": "volc.seedasr.sauc.duration",
    "endpoint": "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream",
    "language": "zh-CN",
    "model_name": "bigmodel",
    "enable_itn": True,
    "enable_punc": True,
    "end_window_size": 800,
    "long_press_ms": 300,
    "max_recording_seconds": 120,
    "min_recording_ms": 300,
    "silence_cancel_ms": 3000,
    # 16bit 满量程 32767。安静房间底噪实测约 100，正常说话数千。
    "voice_threshold": 500,
    "clipboard_restore_ms": 400,
    "clipboard_backup_max_bytes": 10485760,
}

ENV_OVERRIDES = {
    "DBVOICE_BACKEND": "backend",
    "DOUBAO_APP_ID": "app_id",
    "DOUBAO_API_KEY": "api_key",
    "DOUBAO_ACCESS_KEY": "access_key",
    "DOUBAO_RESOURCE_ID": "resource_id",
    "DOUBAO_ENDPOINT": "endpoint",
}


# 曾经存在、现已删除的字段。照旧忽略而不是报"未知字段"——老用户的
# config.json 里还留着它们，报错会让升级后直接起不来。
#   hotkey: 从来没有代码读它。热键硬编码在 lua/init.lua 的 MASK_RIGHT_ALT，
#           改这个字段是静默无效的，属于误导性配置项。
LEGACY_KEYS = frozenset({"hotkey"})


class ConfigError(Exception):
    pass


VALID_BACKENDS = ("funasr", "doubao")


@dataclass(frozen=True)
class Config:
    backend: str
    funasr_bin: str
    funasr_model: str
    funasr_vad: str
    funasr_timeout_s: int
    app_id: str
    api_key: str
    access_key: str
    resource_id: str
    endpoint: str
    language: str
    model_name: str
    enable_itn: bool
    enable_punc: bool
    end_window_size: int
    long_press_ms: int
    max_recording_seconds: int
    min_recording_ms: int
    silence_cancel_ms: int
    voice_threshold: int
    clipboard_restore_ms: int
    clipboard_backup_max_bytes: int

    @property
    def funasr_bin_path(self) -> Path:
        return Path(self.funasr_bin).expanduser()

    @property
    def funasr_model_path(self) -> Path:
        return Path(self.funasr_model).expanduser()

    @property
    def funasr_vad_path(self) -> Path:
        return Path(self.funasr_vad).expanduser()

    @property
    def auth_style(self) -> str:
        if self.api_key and not self.access_key:
            return "new"
        if self.app_id and self.access_key:
            return "legacy"
        raise ConfigError(
            f"凭证不完整：新版控制台需要 api_key，老版需要 app_id + access_key，"
            f"{CONFIG_PATH} 两者都不满足"
        )

    def auth_headers(self, request_id: str | None = None) -> dict[str, str]:
        style = self.auth_style
        headers = {
            "X-Api-Resource-Id": self.resource_id,
            "X-Api-Request-Id": request_id or str(uuid.uuid4()),
            "X-Api-Sequence": "-1",
        }
        if style == "new":
            headers["X-Api-Key"] = self.api_key
        else:
            headers["X-Api-App-Key"] = self.app_id
            headers["X-Api-Access-Key"] = self.access_key
        return headers


def load(path: Path = CONFIG_PATH) -> Config:
    data = dict(DEFAULTS)
    if path.exists():
        try:
            data.update(json.loads(path.read_text(encoding="utf-8")))
        except json.JSONDecodeError as exc:
            raise ConfigError(f"{path} 不是合法 JSON：{exc}") from exc

    # JSON 没有注释语法，`_` 前缀键是通行的替代约定，config.example.json
    # 就靠它讲解每个字段。丢掉而不是报未知字段——否则照抄示例反而跑不起来。
    for key in [k for k in data if k.startswith("_") or k in LEGACY_KEYS]:
        del data[key]

    for env_name, key in ENV_OVERRIDES.items():
        value = os.environ.get(env_name)
        if value:
            data[key] = value

    unknown = sorted(set(data) - set(DEFAULTS))
    if unknown:
        raise ConfigError(f"{path} 里有未知字段：{unknown}")

    if data["backend"] not in VALID_BACKENDS:
        raise ConfigError(
            f"{path} 的 backend 是 {data['backend']!r}，只能是 "
            f"{' 或 '.join(map(repr, VALID_BACKENDS))}"
        )

    return Config(**data)  # type: ignore[arg-type]
