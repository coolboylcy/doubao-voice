from doubao_voice import speech


def test_plain_text_passes_through():
    assert speech.to_speech("找到了，问题在第 42 行。") == "找到了，问题在第 42 行。"


def test_fenced_code_block_is_replaced_not_read_aloud():
    text = "改成这样：\n\n```python\ndef f():\n    return 1\n```\n\n就好了。"
    out = speech.to_speech(text)
    assert "def f" not in out
    assert "return" not in out
    assert "改成这样" in out and "就好了" in out
    assert "代码" in out, "该留一句提示说这里有代码"


def test_inline_code_keeps_content_drops_backticks():
    assert speech.to_speech("改 `config.py` 就行") == "改 config.py 就行"


def test_markdown_emphasis_is_stripped():
    assert speech.to_speech("这是**重点**和*斜体*") == "这是重点和斜体"


def test_headings_lose_their_hashes():
    assert speech.to_speech("## 结论\n没问题") == "结论。没问题"


def test_bullet_list_becomes_flowing_sentence():
    out = speech.to_speech("三点：\n- 第一\n- 第二\n- 第三")
    assert "-" not in out
    assert "第一" in out and "第三" in out


def test_long_list_is_truncated_with_count():
    items = "\n".join(f"- 第{i}项" for i in range(1, 13))
    out = speech.to_speech(f"清单：\n{items}")
    assert "第12项" not in out, "12 项全念出来太长"
    assert "12" in out, "该告诉我一共几项"


def test_urls_are_not_spelled_out():
    out = speech.to_speech("见 https://example.com/a/b/c?x=1 这个页面")
    assert "https" not in out
    assert "example.com" not in out
    assert "链接" in out


def test_file_paths_keep_only_basename():
    out = speech.to_speech("改了 /Users/chris/Projects/foo/src/bar.py 这个文件")
    assert "/Users/chris" not in out
    assert "bar.py" in out


def test_empty_or_whitespace_yields_nothing():
    assert speech.to_speech("") == ""
    assert speech.to_speech("   \n\n  ") == ""
    assert speech.to_speech("```\ncode only\n```") == ""


def test_table_is_summarised_not_read():
    text = "| 名字 | 值 |\n|---|---|\n| a | 1 |\n| b | 2 |"
    out = speech.to_speech(text)
    assert "|" not in out
    assert "表格" in out


# ---- 工具调用摘要 ----


def test_read_tool_says_filename_only():
    assert speech.describe_tool("Read", {"file_path": "/a/b/config.py"}) == "看 config.py"


def test_edit_tool_says_editing():
    assert speech.describe_tool("Edit", {"file_path": "/a/b/main.rs"}) == "改 main.rs"


def test_bash_tool_says_running_command():
    out = speech.describe_tool("Bash", {"command": "npm test -- --watch=false"})
    assert "npm test" in out


def test_bash_long_command_is_truncated():
    out = speech.describe_tool("Bash", {"command": "x" * 200})
    assert len(out) < 60


def test_search_tools_are_generic():
    assert "搜" in speech.describe_tool("Grep", {"pattern": "foo"})
    assert "搜" in speech.describe_tool("Glob", {"pattern": "**/*.py"})


def test_unknown_tool_falls_back_to_its_name():
    assert "Frobnicate" in speech.describe_tool("Frobnicate", {})
