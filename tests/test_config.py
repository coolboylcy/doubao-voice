import json

import pytest

from doubao_voice import config as c


def write(tmp_path, data):
    path = tmp_path / "config.json"
    path.write_text(json.dumps(data), encoding="utf-8")
    return c.load(path)


def test_defaults_fill_in_unspecified_fields(tmp_path):
    cfg = write(tmp_path, {"api_key": "K"})
    assert cfg.endpoint.startswith("wss://openspeech.bytedance.com")
    assert cfg.language == "zh-CN"
    assert cfg.enable_punc is True
    assert cfg.long_press_ms == 300
    assert cfg.silence_cancel_ms == 3000


def test_new_style_credentials_use_single_header(tmp_path):
    cfg = write(tmp_path, {"api_key": "K"})
    h = cfg.auth_headers("req-1")
    assert h["X-Api-Key"] == "K"
    assert "X-Api-App-Key" not in h
    assert h["X-Api-Sequence"] == "-1"
    assert h["X-Api-Request-Id"] == "req-1"
    assert h["X-Api-Resource-Id"] == c.DEFAULTS["resource_id"]


def test_legacy_credentials_use_two_headers(tmp_path):
    cfg = write(tmp_path, {"app_id": "A", "access_key": "S"})
    h = cfg.auth_headers()
    assert h["X-Api-App-Key"] == "A"
    assert h["X-Api-Access-Key"] == "S"
    assert "X-Api-Key" not in h


def test_request_id_is_generated_when_absent(tmp_path):
    cfg = write(tmp_path, {"api_key": "K"})
    a = cfg.auth_headers()["X-Api-Request-Id"]
    b = cfg.auth_headers()["X-Api-Request-Id"]
    assert a != b
    assert len(a) == 36


def test_missing_credentials_raise(tmp_path):
    cfg = write(tmp_path, {})
    with pytest.raises(c.ConfigError, match="凭证不完整"):
        cfg.auth_headers()


def test_env_overrides_file(tmp_path, monkeypatch):
    monkeypatch.setenv("DOUBAO_API_KEY", "from-env")
    cfg = write(tmp_path, {"api_key": "from-file"})
    assert cfg.api_key == "from-env"


def test_unknown_field_is_rejected_not_ignored(tmp_path):
    with pytest.raises(c.ConfigError, match="未知字段"):
        write(tmp_path, {"api_key": "K", "typo_field": 1})


def test_missing_file_yields_defaults(tmp_path):
    cfg = c.load(tmp_path / "nope.json")
    assert cfg.language == "zh-CN"
    assert cfg.api_key == ""


def test_malformed_json_reports_path(tmp_path):
    path = tmp_path / "config.json"
    path.write_text("{not json", encoding="utf-8")
    with pytest.raises(c.ConfigError, match="不是合法 JSON"):
        c.load(path)
