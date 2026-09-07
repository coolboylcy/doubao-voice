import json

import pytest

from doubao_voice import backend
from doubao_voice import config as c
from doubao_voice.asr import AsrSession
from doubao_voice.daemon import Daemon
from doubao_voice.funasr_local import LocalAsrSession


def make_config(**overrides):
    data = dict(c.DEFAULTS)
    data.update(overrides)
    return c.Config(**data)


def test_default_backend_is_local():
    """默认走本地：新用户不配凭证、不花钱就能用。"""
    assert c.DEFAULTS["backend"] == "funasr"


def test_funasr_selects_local_session():
    assert backend.session_factory(make_config(backend="funasr")) is LocalAsrSession


def test_doubao_selects_websocket_session():
    assert backend.session_factory(make_config(backend="doubao")) is AsrSession


def test_describe_names_the_local_model():
    text = backend.describe(make_config(backend="funasr"))
    assert "funasr" in text
    assert "sensevoice-small-q8.gguf" in text


def test_describe_names_the_remote_endpoint():
    text = backend.describe(make_config(backend="doubao"))
    assert "doubao" in text
    assert "bigmodel_nostream" in text


def test_unknown_backend_is_rejected_at_load(tmp_path):
    path = tmp_path / "config.json"
    path.write_text(json.dumps({"backend": "whisper"}), encoding="utf-8")
    with pytest.raises(c.ConfigError) as e:
        c.load(path)
    # 报出合法取值，别让人去翻源码
    assert "funasr" in str(e.value)
    assert "doubao" in str(e.value)


def test_underscore_keys_are_treated_as_comments(tmp_path):
    """config.example.json 用 _ 前缀键当注释，照抄过来必须能加载。"""
    path = tmp_path / "config.json"
    path.write_text(
        json.dumps({"_comment": "讲解", "_doubao_only": "分组", "backend": "doubao"}),
        encoding="utf-8",
    )
    assert c.load(path).backend == "doubao"


def test_shipped_example_config_actually_loads():
    """曾经真的坏过：示例里的 _comment 被当成未知字段直接报错。"""
    from pathlib import Path

    example = Path(__file__).parent.parent / "config.example.json"
    cfg = c.load(example)
    assert cfg.backend in c.VALID_BACKENDS


def test_env_can_override_backend(tmp_path, monkeypatch):
    path = tmp_path / "config.json"
    path.write_text(json.dumps({"backend": "funasr"}), encoding="utf-8")
    monkeypatch.setenv("DBVOICE_BACKEND", "doubao")
    assert c.load(path).backend == "doubao"


def test_local_backend_needs_no_credentials(tmp_path):
    """backend=funasr 时不该因为没填 key 而无法加载配置。"""
    path = tmp_path / "config.json"
    path.write_text(json.dumps({"backend": "funasr"}), encoding="utf-8")
    cfg = c.load(path)
    assert cfg.backend == "funasr"
    # auth_style 仍会抛——但本地路径根本不碰它
    with pytest.raises(c.ConfigError):
        _ = cfg.auth_style


def test_daemon_picks_factory_from_config(sock_dir):
    d = Daemon(make_config(backend="funasr"), socket_path=sock_dir / "s.sock")
    assert d._asr_factory is LocalAsrSession

    d2 = Daemon(make_config(backend="doubao"), socket_path=sock_dir / "s2.sock")
    assert d2._asr_factory is AsrSession


def test_injected_factory_still_wins(sock_dir):
    """测试注入的假后端不能被配置选路覆盖掉。"""
    sentinel = object()
    d = Daemon(
        make_config(backend="funasr"),
        socket_path=sock_dir / "s.sock",
        asr_factory=sentinel,
    )
    assert d._asr_factory is sentinel
