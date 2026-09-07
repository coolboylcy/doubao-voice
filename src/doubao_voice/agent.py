"""驱动 claude -p，把它的流式输出切成可播报的事件。

为什么要流式：Claude 干一件事常要几十秒（读一堆文件、跑测试）。如果等它
全干完再开口，对话就成了"说完 → 干等半分钟 → 它才吭声"，比打字还难受。
用 --output-format stream-json 就能边干边说：它一说话就念，调工具时给个
短提示，最后念结论。

输出里混着三类东西，只有第一类能念：
    assistant.content[].text        → 念
    assistant.content[].thinking    → 跳过
    assistant.content[].tool_use    → 压成一句提示，不念全文
    user.content[].tool_result      → 绝对不念（整个文件内容都在里面）
"""

from __future__ import annotations

import asyncio
import json
import shutil
from collections.abc import AsyncIterator
from dataclasses import dataclass

from . import speech

# 对话场景绝大多数是短指令，默认模型贵得离谱（实测一次简单调用 $0.47）。
DEFAULT_MODEL = "sonnet"

VOICE_SYSTEM_PROMPT = """你正在通过语音和用户对话，你说的每句话都会被念出来。

- 用口语，短句，像在讲话而不是写文档
- 不要输出代码块、表格、Markdown 标记——它们念不出来
- 需要给代码或长内容，写进文件，然后只说"写好了，在某某文件里"
- 先说结论再说理由，别铺垫
- 一次回答控制在三句话以内，除非用户明确要细节"""


@dataclass(frozen=True)
class Speech:
    """一段该念出来的话。"""

    text: str


@dataclass(frozen=True)
class Action:
    """一次工具调用，给 HUD 显示、给提示音，不念全文。"""

    tool: str
    brief: str


@dataclass(frozen=True)
class Done:
    """本轮结束。"""

    text: str
    session_id: str | None
    cost_usd: float | None
    duration_ms: int | None


@dataclass(frozen=True)
class Failed:
    message: str


Event = Speech | Action | Done | Failed


def build_command(
    prompt: str,
    *,
    session_id: str | None = None,
    model: str = DEFAULT_MODEL,
    claude_bin: str = "claude",
) -> list[str]:
    cmd = [
        claude_bin,
        "-p",
        prompt,
        "--output-format",
        "stream-json",
        "--verbose",
        "--model",
        model,
        "--append-system-prompt",
        VOICE_SYSTEM_PROMPT,
    ]
    if session_id:
        cmd += ["--resume", session_id]
    return cmd


def parse_line(raw: str) -> list[Event]:
    """把一行 stream-json 变成零个或多个事件。"""
    raw = raw.strip()
    if not raw.startswith("{"):
        return []
    try:
        msg = json.loads(raw)
    except json.JSONDecodeError:
        return []

    kind = msg.get("type")

    if kind == "assistant":
        events: list[Event] = []
        for block in msg.get("message", {}).get("content", []) or []:
            btype = block.get("type")
            if btype == "text":
                said = speech.to_speech(block.get("text", ""))
                if said:
                    events.append(Speech(said))
            elif btype == "tool_use":
                name = block.get("name", "?")
                events.append(
                    Action(name, speech.describe_tool(name, block.get("input") or {}))
                )
            # thinking 与其他块一律跳过
        return events

    if kind == "result":
        if msg.get("subtype") != "success" and msg.get("is_error"):
            return [Failed(str(msg.get("result") or "Claude 报错了"))]
        return [
            Done(
                text=speech.to_speech(str(msg.get("result") or "")),
                session_id=msg.get("session_id"),
                cost_usd=msg.get("total_cost_usd"),
                duration_ms=msg.get("duration_ms"),
            )
        ]

    # user(tool_result) / system / rate_limit_event 全部丢弃
    return []


async def converse(
    prompt: str,
    *,
    cwd: str,
    session_id: str | None = None,
    model: str = DEFAULT_MODEL,
    claude_bin: str = "claude",
) -> AsyncIterator[Event]:
    """跑一轮对话，边跑边产出事件。"""
    if not shutil.which(claude_bin):
        yield Failed(f"找不到 {claude_bin} 命令")
        return

    proc = await asyncio.create_subprocess_exec(
        *build_command(
            prompt, session_id=session_id, model=model, claude_bin=claude_bin
        ),
        cwd=cwd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )

    saw_done = False
    try:
        assert proc.stdout is not None
        async for line in proc.stdout:
            for event in parse_line(line.decode("utf-8", "replace")):
                if isinstance(event, (Done, Failed)):
                    saw_done = True
                yield event
    except asyncio.CancelledError:
        # 打断只该停嘴，不该杀掉手上的活——跑到一半的 npm test 或 git 操作
        # 被砍会留下烂摊子。让它自己跑完，输出丢弃即可。
        proc.stdout = None  # 不再读
        raise
    finally:
        if proc.returncode is None:
            with_timeout = asyncio.wait_for(proc.wait(), timeout=0.1)
            try:
                await with_timeout
            except (asyncio.TimeoutError, asyncio.CancelledError):
                pass

    if not saw_done:
        stderr = b""
        if proc.stderr is not None:
            stderr = await proc.stderr.read()
        detail = stderr.decode("utf-8", "replace").strip()[:200]
        yield Failed(detail or f"claude 异常退出（code={proc.returncode}）")
