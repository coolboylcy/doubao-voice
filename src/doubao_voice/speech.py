"""把 Claude 的输出转成能念出来的话。

这一层决定语音对话好不好用。Claude 的回复是写给眼睛看的：代码块、
Markdown 标记、长列表、完整路径、URL——原样念出来全是灾难。这里把它
压成人话，只保留听得进去的部分。

纯函数，无依赖，方便单测。
"""

from __future__ import annotations

import os
import re

# 念到第几项就该收口，剩下的报个总数
MAX_LIST_ITEMS = 4
MAX_BASH_ECHO = 40


def _strip_code_blocks(text: str) -> tuple[str, bool]:
    """摘掉围栏代码块，返回剩余文本和"是否有过代码"。"""
    had = bool(re.search(r"```", text))
    text = re.sub(r"```[\s\S]*?```", "\n", text)
    # 没闭合的围栏：后面全是代码，直接砍掉
    text = re.sub(r"```[\s\S]*$", "\n", text)
    return text, had


def _shorten_paths(text: str) -> str:
    """长路径只留文件名——念一串目录没有任何意义。"""

    def repl(m: re.Match) -> str:
        return os.path.basename(m.group(0).rstrip("/")) or m.group(0)

    return re.sub(r"(?:~|\.{0,2})?/[\w.\-/]{4,}", repl, text)


def _collapse_lists(text: str) -> str:
    """列表项拉平成一句话；太长就报总数。"""
    lines = text.split("\n")
    out: list[str] = []
    buf: list[str] = []

    def flush() -> None:
        if not buf:
            return
        if len(buf) > MAX_LIST_ITEMS:
            shown = "，".join(buf[:MAX_LIST_ITEMS])
            out.append(f"{shown}，等 {len(buf)} 项")
        else:
            out.append("，".join(buf))
        buf.clear()

    for line in lines:
        m = re.match(r"\s*(?:[-*+]|\d+[.)])\s+(.*)", line)
        if m:
            item = m.group(1).strip()
            if item:
                buf.append(item)
        else:
            flush()
            out.append(line)
    flush()
    return "\n".join(out)


def _summarise_tables(text: str) -> str:
    """Markdown 表格念不了，换成一句提示。"""
    lines = text.split("\n")
    out: list[str] = []
    in_table = False
    for line in lines:
        if line.strip().startswith("|") and line.strip().endswith("|"):
            if not in_table:
                out.append("这里有个表格。")
                in_table = True
            continue
        in_table = False
        out.append(line)
    return "\n".join(out)


def to_speech(text: str) -> str:
    if not text or not text.strip():
        return ""

    text, had_code = _strip_code_blocks(text)
    text = _summarise_tables(text)

    # URL 整条替掉，念 h-t-t-p-s 冒号斜杠斜杠是酷刑
    text = re.sub(r"https?://\S+", "一个链接", text)

    text = _shorten_paths(text)

    # 行内代码留内容去反引号
    text = re.sub(r"`([^`]*)`", r"\1", text)
    # 加粗与斜体
    text = re.sub(r"\*{1,3}([^*]+)\*{1,3}", r"\1", text)
    text = re.sub(r"_{2}([^_]+)_{2}", r"\1", text)
    # 标题：去掉井号，补个句号让语气断开
    text = re.sub(r"^#{1,6}\s*(.+?)\s*$", r"\1。", text, flags=re.MULTILINE)

    text = _collapse_lists(text)

    # 收拢空白
    text = re.sub(r"\n{2,}", "\n", text)
    text = "\n".join(line.strip() for line in text.split("\n") if line.strip())
    text = text.replace("\n", " ")
    text = re.sub(r"\s{2,}", " ", text).strip()
    # 标题补的句号后面若紧跟内容，读起来会有个自然停顿，不再额外加空格
    text = text.replace("。 ", "。")

    if had_code and text:
        text += " 代码我写好了。"
    elif had_code:
        return ""

    return text


_TOOL_VERBS = {
    "Read": "看",
    "Write": "写",
    "Edit": "改",
    "NotebookEdit": "改",
}


def describe_tool(name: str, tool_input: dict) -> str:
    """把一次工具调用压成一句能念的话（或显示在 HUD 上）。"""
    tool_input = tool_input or {}

    if name in _TOOL_VERBS:
        path = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
        base = os.path.basename(str(path)) or "文件"
        return f"{_TOOL_VERBS[name]} {base}"

    if name == "Bash":
        cmd = str(tool_input.get("command", "")).strip()
        first = cmd.split("\n")[0]
        if len(first) > MAX_BASH_ECHO:
            first = first[:MAX_BASH_ECHO] + "…"
        return f"跑 {first}" if first else "跑命令"

    if name in ("Grep", "Glob"):
        return "搜一下"

    if name in ("WebFetch", "WebSearch"):
        return "查一下网上"

    if name == "Task":
        return "派了个子任务"

    if name == "TodoWrite":
        return "记一下待办"

    return f"用 {name}"
