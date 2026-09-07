# 验收记录

## 听写模式（右 Option）

对应 [听写设计](superpowers/specs/2026-09-04-doubao-voice-input-design.md) 第 16 节。

| # | 验收项 | 结果 | 实测 |
|---|---|---|---|
| 1 | Claude Code / Terminal / 飞书 / Chrome 各验证一次中文长句 | 部分 | 用户在 Terminal 中验证成功；其余三处未逐一走 |
| 2 | 按住右 Option 说话，松手后 1.5 秒内文字上屏 | ✅ | 用户确认「测试我觉得是成功的」 |
| 3 | 短按进入持续录音，HUD 实时滚动，再按一下结束上屏 | 未验 | — |
| 4 | 录音中按 Esc，无文字上屏，剪贴板完好 | 未验 | — |
| 5 | 断网录音，HUD 显示错误码，剪贴板未污染 | 未验 | — |
| 6 | 误触 3 秒内自动取消；<300ms 松手不产生 API 调用 | 未验 | 逻辑有单测覆盖，真机未走 |
| 7 | 重启后 daemon 自动拉起，热键直接可用 | 未验 | launchd `RunAtLoad`+`KeepAlive` 已确认配置；Hammerspoon `autoLaunch` 已置 true。**真正重启验证过才算数** |
| 8 | `git log -p` 全文搜索无凭证明文 | ✅ | 推送前扫描通过，命中的只是字段名 |

**偏离设计之处**：第 3 条的「HUD 实时滚动字幕」做不到——豆包 2.0 只有 `nostream` 模式，整段说完才给文本。已改为实时音频波形，并与用户确认走这条路。

## 对话模式（左 Option）

对应 [对话设计](superpowers/specs/2026-09-04-voice-chat-design.md)。

| # | 验收项 | 结果 | 实测 |
|---|---|---|---|
| 1 | `agent.converse` 能驱动 Claude 真干活并流式返回 | ✅ | 实测调用 Bash 读 README 后念出正确结论 |
| 2 | `--resume` 保住上下文 | ✅ | 第二轮「刚才那个项目的热键」答对，未重读文件 |
| 3 | 成本符合预期 | ✅ | 首轮 $0.3120 / 次轮 $0.0223 |
| 4 | tool_result 绝不被念出来 | ✅ | 单测覆盖 |
| 5 | 代码块不被念出来 | ✅ | 单测覆盖 |
| 6 | 前台终端 cwd 能取到 | ✅ | 实测返回前台终端的真实工作目录 |
| 7 | TTS 挑到中文音色 | ✅ | Tingting |
| 8 | **按住左 Option 说话的完整路径** | **未验** | 各层分别验过，端到端真人未走 |
| 9 | 打断只停嘴、活继续干完 | 未验 | 单测显式断言，真机未走 |
| 10 | 录音中 Esc 丢弃这一句 | 未验 | — |
| 11 | 按住不放满时长自动结束 | 未验 | — |

## 自动化检查

三项，`install.sh` 会跑其中的 Lua 检查：

```
uv run pytest              → 92 passed
lua tests/state_test.lua   → 44 条断言全过
luacheck lua/              → 0 errors
uv run pytest -m live      → 2 passed（真打豆包 API）
```

## 环境实测结论

| 项 | 值 |
|---|---|
| 控制协议传输层 | Unix domain socket（`hs.socket` 支持，无需回退 TCP） |
| daemon 常驻 | launchd，TCC 麦克风授权正常 |
| 右 / 左 Option 位掩码 | `0x40` / `0x20`（完整 flags `0x00080140` / `0x00080120`） |
| 豆包 2.0 可用端点 | 只有 `bigmodel_nostream` |
| 服务端末包 | `flags=0x3` 但 sequence 为正数 |
| 系统输入音量 | 原为 31%，导致识别全空；调至 85% 后正常 |
