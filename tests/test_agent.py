import json

from doubao_voice import agent


def line(obj) -> str:
    return json.dumps(obj, ensure_ascii=False)


def assistant(*blocks) -> str:
    return line({"type": "assistant", "message": {"content": list(blocks)}})


# ---- 命令拼装 ----


def test_command_uses_cheap_model_by_default():
    cmd = agent.build_command("你好")
    assert "--model" in cmd
    assert cmd[cmd.index("--model") + 1] == "sonnet"


def test_command_requests_stream_json():
    cmd = agent.build_command("你好")
    assert cmd[cmd.index("--output-format") + 1] == "stream-json"
    assert "--verbose" in cmd, "stream-json 需要 --verbose 才出完整事件"


def test_command_injects_voice_system_prompt():
    cmd = agent.build_command("你好")
    injected = cmd[cmd.index("--append-system-prompt") + 1]
    assert "语音" in injected
    assert "代码块" in injected, "必须明确禁止输出代码块，否则会念给用户听"


def test_resume_is_omitted_on_first_turn():
    assert "--resume" not in agent.build_command("你好")


def test_resume_carries_session_id():
    cmd = agent.build_command("你好", session_id="abc-123")
    assert cmd[cmd.index("--resume") + 1] == "abc-123"


# ---- 流解析：什么该念、什么绝不能念 ----


def test_assistant_text_becomes_speech():
    events = agent.parse_line(assistant({"type": "text", "text": "找到了，在第 42 行。"}))
    assert events == [agent.Speech("找到了，在第 42 行。")]


def test_thinking_block_is_never_spoken():
    assert agent.parse_line(assistant({"type": "thinking", "thinking": "让我想想"})) == []


def test_tool_result_is_never_spoken():
    """整个文件内容都在 tool_result 里，念出来是灾难。"""
    raw = line(
        {
            "type": "user",
            "message": {
                "content": [
                    {"type": "tool_result", "content": "1\thello\n2\tworld\n" * 100}
                ]
            },
        }
    )
    assert agent.parse_line(raw) == []


def test_tool_use_becomes_short_action_not_speech():
    events = agent.parse_line(
        assistant(
            {"type": "tool_use", "name": "Read", "input": {"file_path": "/a/b/conf.py"}}
        )
    )
    assert events == [agent.Action("Read", "看 conf.py")]


def test_mixed_blocks_keep_order():
    events = agent.parse_line(
        assistant(
            {"type": "text", "text": "我看一下。"},
            {"type": "tool_use", "name": "Bash", "input": {"command": "ls -la"}},
            {"type": "thinking", "thinking": "嗯"},
        )
    )
    assert isinstance(events[0], agent.Speech)
    assert isinstance(events[1], agent.Action)
    assert len(events) == 2


def test_code_block_in_text_is_not_read_aloud():
    events = agent.parse_line(
        assistant({"type": "text", "text": "这样写：\n```py\nx = 1\n```\n好了"})
    )
    assert len(events) == 1
    assert "x = 1" not in events[0].text


def test_result_yields_done_with_session_id():
    raw = line(
        {
            "type": "result",
            "subtype": "success",
            "result": "改好了。",
            "session_id": "sess-9",
            "total_cost_usd": 0.012,
            "duration_ms": 4200,
        }
    )
    (done,) = agent.parse_line(raw)
    assert isinstance(done, agent.Done)
    assert done.text == "改好了。"
    assert done.session_id == "sess-9"
    assert done.cost_usd == 0.012


def test_error_result_yields_failed():
    raw = line(
        {"type": "result", "subtype": "error", "is_error": True, "result": "炸了"}
    )
    (failed,) = agent.parse_line(raw)
    assert isinstance(failed, agent.Failed)
    assert "炸了" in failed.message


def test_system_and_hook_noise_is_dropped():
    assert agent.parse_line(line({"type": "system", "subtype": "init"})) == []
    assert agent.parse_line(line({"type": "system", "subtype": "hook_started"})) == []
    assert agent.parse_line(line({"type": "rate_limit_event"})) == []


def test_non_json_line_is_ignored():
    assert agent.parse_line("这不是 JSON") == []
    assert agent.parse_line("") == []
    assert agent.parse_line("{坏掉的") == []
