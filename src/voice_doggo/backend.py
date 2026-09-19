"""按配置挑识别后端。

两个后端实现同一套接口（`open` / `send_chunk` / `close_and_collect` /
`abort`），所以这里只需要返回一个类——`daemon.Daemon` 拿它当 `asr_factory`
用，其余代码完全不关心用的是哪条路。

    funasr  本地 GGUF 推理，免费、离线、无额度（默认）
    doubao  火山引擎流式 ASR，要凭证、按小时计费
"""

from __future__ import annotations

from .config import Config


def session_factory(cfg: Config):
    """返回该后端的会话类。签名统一为 (cfg, on_partial) -> session。"""
    if cfg.backend == "funasr":
        from .funasr_local import LocalAsrSession

        return LocalAsrSession

    from .asr import AsrSession

    return AsrSession


def describe(cfg: Config) -> str:
    """给 doctor 和日志用的一句话说明。"""
    if cfg.backend == "funasr":
        return f"funasr（本地，{cfg.funasr_model_path.name}）"
    return f"doubao（{cfg.endpoint}）"
