# 验收记录

## 2026-09-18 原生本地版发布验收

产物：`dist/Doubao Voice 0.2.0.dmg`（Apple Silicon、macOS 13+，FunASR 离线模型随 App 打包）。

| 验收项 | 结果 |
|---|---|
| Python 单元/集成测试 | ✅ 101 passed，2 个云端 live 测试因本机无豆包凭证未执行 |
| Lua 状态机 | ✅ 56 条断言全部通过 |
| Swift 单元测试 | ✅ 5/5 |
| 原生 UI 自动化 | ✅ 首次设置页、离线状态、权限项目、菜单栏入口、退出流程 1/1 |
| Python 静态检查 | ✅ Ruff 通过 |
| Lua 静态检查 | ✅ 0 errors（测试文件 4 个 unused-assignment warnings） |
| Xcode 静态分析 | ✅ 通过 |
| helper 控制协议 | ✅ `ping/start/cancel` 实际进程通信通过，结束后无残留进程 |
| DMG 完整性 | ✅ `hdiutil verify` 校验有效；镜像内 App 深层签名有效 |
| 镜像内离线识别 | ✅ 真模型识别 `tests/fixtures/hello.wav`，输出“今天天气不错，我正在测试豆包语音识别。” |
| 本机安装 | ✅ 已安装到 `/Applications/Doubao Voice.app`，旧版保留为 `.pre-codex-backup` |

说明：macOS 的麦克风、辅助功能和输入监控必须由用户在“系统设置 → 隐私与安全性”中亲自授权，无法在构建或测试脚本中静默开启。云端 live 测试不影响本地 DMG；本地版不读取云端凭证，也不上传音频。

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

## 自动化检查

旧版开发入口的自动化检查：

```
uv run pytest              → 101 passed，2 deselected（无云端凭证）
lua tests/state_test.lua   → 56 条断言全过
luacheck lua/              → 0 errors
uv run pytest -m live      → 需要豆包凭证，会产生真实 API 请求
```

## 环境实测结论

| 项 | 值 |
|---|---|
| 控制协议传输层 | Unix domain socket（`hs.socket` 支持，无需回退 TCP） |
| daemon 常驻 | launchd，TCC 麦克风授权正常 |
| 右 Option 位掩码 | `0x40`（完整 flags `0x00080140`；左 Option 是 `0x20`，用于确认没误匹配） |
| 豆包 2.0 可用端点 | 只有 `bigmodel_nostream` |
| 服务端末包 | `flags=0x3` 但 sequence 为正数 |
| 系统输入音量 | 原为 31%，导致识别全空；调至 85% 后正常 |
