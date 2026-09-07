# 豆包语音全局听写（doubao-voice）设计

日期：2026-09-04
状态：已批准，待实施

## 1. 目标与非目标

### 目标

在 macOS 上按一个热键即可说话，语音经豆包流式语音识别大模型转成文字，自动出现在**当前焦点 App 的光标处**——Claude Code、Terminal.app、飞书、浏览器、微信一视同仁。

必须满足：

- 热键单键触发，同时支持"按住说话"（PTT）与"按一下开、再按一下关"（toggle）两种手感
- 按下到开始采音的延迟不可感知（目标 < 50ms）
- 说话过程中能看到实时识别文字，说错了能当场取消
- 不污染剪贴板（用完恢复原内容）
- 凭证不入 git，不入自动备份仓

### 非目标（明确不做）

- 语音合成（TTS）
- 语音命令词 / 唤醒词
- 多语言自动切换（首版固定中文，语言在配置里可改）
- 图形设置面板（改 JSON 文件）
- 本地离线识别兜底
- 识别历史的记录与检索

## 2. 环境事实

勘查于 2026-09-04，本机 macOS（Darwin 25.5.0，Apple Silicon）：

| 项 | 状态 |
|---|---|
| 终端 | `Apple_Terminal`（Terminal.app） |
| ffmpeg | 已装 `/opt/homebrew/bin/ffmpeg` |
| uv | 已装 `/opt/homebrew/bin/uv` |
| node / pnpm | 已装 |
| python3 | `/usr/bin/python3`（系统自带；项目用 uv 管独立环境） |
| sox / rec | **未装** |
| cliclick | **未装** |
| Hammerspoon | **未装，需安装** |
| Karabiner | 未装 |
| 火山引擎凭证 | **无任何痕迹，需开通** |

## 3. 豆包流式 ASR 接口事实

来源：火山引擎官方文档 `docs.volcengine.com/docs/6561/1354869`，核对于 2026-09-04。

### 端点

> **2026-09-04 实测修正。** 下面这段原本写的是"选双向流式 `bigmodel`，因为它
> 才提供边说边回的增量结果，是 HUD 实时字幕的前提"。实际接通后发现文档与
> 服务端行为不符，结论整个反过来了。

本项目开通的是**豆包流式语音识别模型 2.0（seedasr）**，实测三个端点的行为：

| 端点 | 用 `volc.seedasr.sauc.duration` 的实际行为 |
|---|---|
| `/api/v3/sauc/bigmodel` | **400** `resourceId ... is not allowed`——只服务 1.0（bigasr） |
| `/api/v3/sauc/bigmodel_async` | 握手通过，逐包无响应，**末包也不带 `text`** |
| `/api/v3/sauc/bigmodel_nostream` | **可用** ← 本项目使用 |

`bigmodel_nostream` 对每包音频都回一帧（带累积 `duration`），但**只有末包的
`text` 非空**，中途全是空串。即"流式输入、一次性输出"，名副其实。

**因此 2.0 拿不到增量识别结果，HUD 实时字幕做不到**（见第 9 节的替代方案）。
要实时字幕只能回到 1.0 的 `bigmodel`，但本账号 1.0 的试用包已于 2026-03-04
过期（状态"回收"），重开可能需付费，且其增量能力未经实测。已与用户确认走 2.0。

区分两种错误码很有用：`403 requested resource not granted` 表示端点认识这个
resource_id、只是账号没开通；`400 not allowed` 表示端点根本不接受它。

### 鉴权 header

**存在两种形态，取决于凭证是在新版还是老版控制台签发的：**

- 新版：`X-Api-Key`（单一密钥）
- 老版：`X-Api-App-Key` + `X-Api-Access-Key`（分开）

两种都必须支持。`config.py` 依据配置里出现了哪些字段自动判定走哪套 header，不要求用户手工声明。

公共 header：

- `X-Api-Resource-Id`：见下表
- `X-Api-Request-Id`：UUID
- `X-Api-Sequence`：固定 `-1`

### resource_id

| 模型 | 计费 | resource_id |
|---|---|---|
| 豆包流式 1.0 | 小时版 | `volc.bigasr.sauc.duration` |
| 豆包流式 1.0 | 并发版 | `volc.bigasr.sauc.concurrent` |
| 豆包流式 2.0 | 小时版 | `volc.seedasr.sauc.duration` |
| 豆包流式 2.0 | 并发版 | `volc.seedasr.sauc.concurrent` |

个人听写场景是低频、突发、单路，**默认取小时版**（`*.duration`）；并发版按并发路数包月，对单人用没有意义。

模型代次：**开通时优先选 2.0（`volc.seedasr.sauc.duration`）**，识别质量更好；若控制台未提供 2.0 或计价明显更贵，回落 1.0（`volc.bigasr.sauc.duration`）。最终取值在开通环节确认并写入配置，代码不假定任何一代——`resource_id` 与 `model_name` 全部来自配置。

### 二进制帧

4 字节 header：

```
byte0: [protocol version 4bit = 0b0001] [header size 4bit = 0b0001]
byte1: [message type 4bit]              [message type specific flags 4bit]
byte2: [serialization 4bit]             [compression 4bit]
byte3: [reserved 8bit]
```

message type：

| 值 | 含义 |
|---|---|
| `0x1` | full client request（请求参数） |
| `0x2` | audio only request（音频数据） |
| `0x9` | full server response（识别结果） |
| `0xF` | error response |

flags：`0x0` 无序列号 / `0x1` 含正序列号 / `0x2` 末包标识 / `0x3` 负序列号即末包
serialization：`0x0` 无 / `0x1` JSON
compression：`0x0` 无 / `0x1` gzip

### full client request 载荷

```json
{
  "user":  { "uid": "<机器标识>", "platform": "Linux" },
  "audio": { "format": "pcm", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1, "language": "zh-CN" },
  "request": {
    "model_name": "bigmodel",
    "enable_itn": true,
    "enable_punc": true,
    "enable_ddc": false,
    "result_type": "full",
    "end_window_size": 800,
    "show_utterances": true
  }
}
```

`enable_itn` 把"二零二六年"规整成"2026 年"；`enable_punc` 加标点。两者对听写场景都必要，默认开。`show_utterances` 开启才能拿到 `definite` 分句标记。

`user.platform` 的官方枚举只有 `iOS` / `Android` / `Linux`，无 macOS 选项，取最接近的 `Linux`。该字段仅用于服务端统计，不影响识别。

### 音频分片

官方建议单包 100–200ms、间隔 100–200ms，双向流式最优 200ms。**本项目取 200ms**：16000 × 2 字节 × 0.2 秒 = 6400 字节/包。

### 服务端响应

```json
{
  "result": {
    "text": "累积识别文本",
    "utterances": [
      { "text": "分句", "start_time": 0, "end_time": 1705, "definite": true, "words": [...] }
    ]
  },
  "audio_info": { "duration": 3696 }
}
```

`result.text` 是**累积**文本而非增量，HUD 直接整体替换显示即可，不要做拼接。

### 错误码

`20000000` 成功 / `45000001` 参数无效 / `45000002` 空音频 / `45000081` 等包超时 / `45000151` 音频格式错 / `55000031` 服务器繁忙。

## 4. 架构

三个进程，一条 Unix domain socket：

```
右 Option 按下
   │
   ▼
┌──────────────────────────┐   NDJSON over        ┌────────────────────────┐   WSS    ┌──────────┐
│ Hammerspoon (Lua)        │  ~/.doubao-voice/    │ dbvoiced (Python)      │ ───────▶ │ 豆包 ASR │
│ 热键 · HUD · 菜单栏      │ ◀─── ctl.sock ────▶  │ 麦克风 · ASR 会话      │ ◀─────── │          │
│ 文本注入                 │                      │                        │          │          │
└──────────────────────────┘                      └────────────────────────┘          └──────────┘
   前台层（持系统权限）                             后台层（launchd 常驻）
```

**daemon 必须常驻。** PTT 语义要求按下即录，若每次按键才拉起进程，冷启动加 WebSocket 握手要小半秒，前几个字必丢，手感不可用。

### 为什么是这个组合

难写的两件事分给各自最擅长的一方：

- 豆包的自定义二进制协议在 Python 里最好写（官方示例即 Python），Swift 里要从零手写并调试
- 全局热键、长短按判定、菜单栏、浮层 HUD、模拟按键，这五件在 Hammerspoon 里各十几行 Lua，换任何语言都要上百行
- 系统权限只授给 `Hammerspoon.app` 这一个稳定对象。若走纯 Python，辅助功能权限绑在解释器本体上，`uv` 换个 Python 版本就会静默失效

代价是多一个 App 依赖和一层进程间协议，可接受。

## 5. 组件与边界

### Lua 侧 `~/.hammerspoon/doubao-voice/`

| 文件 | 职责 |
|---|---|
| `init.lua` | 装载、读配置、串联各模块 |
| `hotkey.lua` | 右 Option 的 `flagsChanged` 监听与状态机 |
| `state.lua` | 纯函数状态机 `step(state, event) -> newState, actions` |
| `client.lua` | Unix socket 客户端，收发 NDJSON |
| `hud.lua` | `hs.canvas` 浮层：状态 + 实时字幕 |
| `inject.lua` | 剪贴板备份 → 写入 → Cmd+V → 恢复 |
| `menubar.lua` | `hs.menubar` 图标：idle / recording / error |

### Python 侧 `~/Projects/doubao-voice/src/doubao_voice/`

| 文件 | 职责 | 依赖 |
|---|---|---|
| `protocol.py` | 二进制帧 build / parse，gzip，序列号 | 无（纯函数） |
| `asr.py` | WebSocket 会话生命周期 | `protocol` |
| `mic.py` | 麦克风采集 → 16k/16bit/mono PCM | 无 |
| `daemon.py` | Unix socket 服务端 + 会话编排 | `asr`, `mic`, `config` |
| `config.py` | 读配置 + 环境变量覆盖 + header 形态判定 | 无 |
| `cli.py` | `dbvoice doctor` / `once` / `daemon` | 全部 |

**边界检验**：`protocol.py` 不知道有麦克风；`asr.py` 不知道有 socket；`daemon.py` 不知道二进制帧长什么样。任一层可脱离其他层单独测试。

## 6. 控制协议（Lua ↔ Python）

Unix domain socket `~/.doubao-voice/ctl.sock`，换行分隔 JSON，双向。

**Lua → daemon**

```json
{"cmd": "start"}
{"cmd": "stop"}
{"cmd": "cancel"}
{"cmd": "ping"}
```

`start` 不带 mode——daemon 不需要知道这次是 PTT 还是 toggle，那是 Lua 侧的语义。这一刀切下去，daemon 就只剩"录/停/丢"三个动作，状态机复杂度全部留在 Lua 一侧。

**daemon → Lua**

```json
{"event": "started"}
{"event": "partial", "text": "今天天气"}
{"event": "final",   "text": "今天天气不错。"}
{"event": "empty"}
{"event": "error",   "code": "45000081", "message": "等包超时"}
{"event": "pong",    "ready": true}
```

## 7. 数据流

1. 右 Option 按下 → `hotkey.lua` 立即发 `{"cmd":"start"}`，同时启 300ms 定时器
2. daemon 开麦、建 WSS、发 full client request（type `0x1`，seq=1）
3. 每 200ms 推一包 6400 字节 PCM（type `0x2`，flags `0x1`，seq 递增）
4. 服务端每包回 `0x9`，daemon 取 `result.text` 发 `{"event":"partial"}`
5. HUD 整体替换显示该文本
6. 松手（PTT）或再次按下（toggle）→ `{"cmd":"stop"}`
7. daemon 发末包（flags `0x3`，负序列号），等最终 `0x9`
8. `{"event":"final"}` → `inject.lua` 粘贴 → HUD 淡出

## 8. 热键状态机

这是整套系统最容易出 bug 的地方，因此抽成纯函数并单独测试。

状态：`IDLE` / `PENDING` / `PTT` / `TOGGLE`

| 当前状态 | 事件 | 新状态 | 动作 |
|---|---|---|---|
| IDLE | `⌥ down` | PENDING | **发 start** + 启 300ms 定时器 |
| PENDING | `timer` | PTT | 取消 silence 定时器（PTT 允许长时间沉默） |
| PENDING | `⌥ up` | TOGGLE | —（继续录） |
| PTT | `⌥ up` | IDLE | 发 stop |
| TOGGLE | `⌥ down` | IDLE | 发 stop |
| PTT | `esc` | IDLE | 发 cancel |
| TOGGLE | `esc` | IDLE | 发 cancel |
| TOGGLE | `silence(3s)` | IDLE | 发 cancel |
| TOGGLE | `timeout(120s)` | IDLE | 发 stop |
| IDLE | `esc` | IDLE | —（不拦截 Esc，透传） |

### 关键决策：按下即录

按下的瞬间无法区分短按与长按。若等 300ms 确认是长按再开始录音，PTT 模式下开头 300ms 的语音必然丢失——而人往往在按下的同时就开口。

因此**两种模式都从按下即刻开始采音**，靠松手时机决定语义。

### 误触的两条防线

按下即录带来一个后果：短按等于进入 TOGGLE 持续录音，而"故意短按开启录音"与"手滑蹭到右 Option"在按键层面完全无法区分。若不处理，一次误触会静默录到 120 秒超时才停，白烧一分钟的识别时长。

两条防线：

1. **PTT 侧**：daemon 对总时长 < `min_recording_ms`（300ms）的音频本地直接丢弃，既不发请求也不计费。仅对松手结束的 PTT 会话生效。
2. **TOGGLE 侧**：Lua 状态机在进入录音时启动 `silence_cancel_ms`（3000ms）定时器，每收到一次非空 `partial` 就重置；定时器到点即发 cancel。真人开启录音后总会在 3 秒内说话；误触则不会。

**silence 判定必须在 Lua 侧而非 daemon 侧**：daemon 按第 6 节的约定不知道当前是 PTT 还是 TOGGLE，而 PTT 下用户按住键思考四五秒再开口完全正常，不能取消。因此状态机在 `PENDING → PTT` 的转移上显式取消 silence 定时器，这条防线只对 TOGGLE 生效。

第 2 条依赖服务端返回，因此误触仍会产生一次约 3 秒的 API 调用——这是为了保住"短按即录"这个手感所付的最小代价。想彻底归零就得把 toggle 改成双击触发，那会显著牺牲日常手感，不划算。

### Esc 的处理

Esc 只在 `PTT` / `TOGGLE` 状态下被消费，其余时刻透传给焦点 App。绝不能在 IDLE 时吞掉 Esc——那会让 vim 用户当场崩溃。

## 9. 文本注入

```lua
local old = hs.pasteboard.readAllData()      -- 全类型备份，非仅纯文本
hs.pasteboard.setContents(text)
hs.eventtap.keyStroke({"cmd"}, "v")
hs.timer.doAfter(0.4, function() hs.pasteboard.writeAllData(old) end)
```

已知取舍：

- **400ms 恢复窗口内用户自己按 Cmd+V 会拿到语音文本。** 窗口足够窄，可接受，不做加锁。
- **剪贴板原内容超 10MB 时跳过备份**，只在 HUD 上提示一次"剪贴板未保留"。备份几十 MB 的图片会造成可感知卡顿，代价大于收益。
- **目标 App 若不响应 Cmd+V**（如 vim 普通模式）粘贴无效。首版不处理，YAGNI；真遇到再加 `paste_prefix` 配置。

## 10. 错误处理

| 场景 | 检测方式 | 处理 |
|---|---|---|
| daemon 未运行 | `client.lua` 连接 socket 失败 | 菜单栏转灰 + 系统通知；launchd `KeepAlive=true` 自动拉起 |
| 麦克风未授权 | `mic.py` 打开设备抛错 | `dbvoice doctor` 检测并打开系统设置对应面板 |
| 网络中断 / WSS 异常 | 连接异常或 `0xF` 帧 | HUD 红字显示错误码。~~PCM 落盘 `~/.doubao-voice/failed/`~~ **未实现，已移除** |
| 识别结果为空 | `result.text` 为空串 | 发 `{"event":"empty"}`；**不粘贴、不动剪贴板**，HUD 显示"没听到" |
| PTT 录音 < 300ms | daemon 本地计时 | 直接丢弃，不发请求 |
| TOGGLE 开启后 3s 无语音 | Lua 侧 silence 定时器（靠本地音量 `voice` 事件重置，**不是** partial——见 `daemon.peak_amplitude`） | 发 `cancel`，不粘贴。PTT 模式下该定时器已取消，不受影响 |
| 凭证失效 | 错误码 `45000001` 一类 | HUD 提示，并指向重新开通/取新 token 的步骤 |
| 单次录音超 120s | Lua 侧定时器 | 自动 stop，防止忘关麦克风持续计费 |

~~失败音频落盘保留 7 天，`dbvoice doctor` 顺带清理过期文件。~~

**2026-09-07 移除**：落盘那一半从来没实现，只有 `doctor` 里的清理代码在管一个
永远为空的目录。清理代码、`FAILED_DIR` 常量、`install.sh` 的建目录都已删掉。
要恢复这个能力得先真的把 PCM 写下去。

## 11. 测试策略

| 层 | 方式 | 是否打真 API |
|---|---|---|
| `protocol.py` | round-trip 单测：build → parse → 断言相等。覆盖 4 种 message type、gzip 开与关、正序列号与负序列号末包 | 否 |
| `asr.py` | 本地假 WebSocket 服务端回放录制好的服务端帧，断言产出的 partial/final 事件序列 | 否 |
| 端到端 | smoke test：喂 `tests/fixtures/hello.wav`，断言识别文本含"你好" | **是**，默认 skip，需显式打标记运行 |
| `daemon.py` | socket 命令解析 + 会话编排单测，`mic`/`asr` 用 fake 替身 | 否 |
| `state.lua` | 纯函数状态机表驱动测试，逐条覆盖第 8 节转移表 | 否 |
| HUD / 注入 / 菜单栏 | 手动验证，写入验收清单 | — |

**TDD 从 `protocol.py` 起步**——它是纯函数、规格明确、最好测，且是整条链路上最容易静默出错的一环（位运算和序列号错了不会报错，只会识别不出东西）。

## 12. 配置

`~/.doubao-voice/config.json`，权限 `600`：

```json
{
  "app_id": "",
  "api_key": "",
  "access_key": "",
  "resource_id": "volc.bigasr.sauc.duration",
  "endpoint": "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel",
  "language": "zh-CN",
  "model_name": "bigmodel",
  "enable_itn": true,
  "enable_punc": true,
  "end_window_size": 800,
  "long_press_ms": 300,
  "max_recording_seconds": 120,
  "min_recording_ms": 300,
  "silence_cancel_ms": 3000,
  "clipboard_restore_ms": 400,
  "clipboard_backup_max_bytes": 10485760
}
```

环境变量 `DOUBAO_APP_ID` / `DOUBAO_API_KEY` / `DOUBAO_ACCESS_KEY` / `DOUBAO_RESOURCE_ID` 覆盖同名字段。

**鉴权 header 形态自动判定**：配置里只有 `api_key` → 走新版单 header；同时有 `app_id` 与 `access_key` → 走老版双 header。

### 凭证隔离

- `~/.doubao-voice/` 不在 git 仓内
- 项目 `.gitignore` 排除 `*.json` 凭证样式文件与 `fixtures/*.wav` 之外的音频
- 如果你有自动备份 home 目录的脚本（Time Machine、rsync 定时任务等），确认
  `~/.doubao-voice/` 在排除列表里——那里面是明文凭证

## 13. 系统权限

| 授予对象 | 权限 | 用途 |
|---|---|---|
| Hammerspoon.app | 辅助功能 | 发送 Cmd+V 模拟按键 |
| Hammerspoon.app | 输入监控 | 全局捕获右 Option |
| Python 解释器（经终端首次触发） | 麦克风 | 采音 |

`dbvoice doctor` 逐项检测并给出直达系统设置面板的指引。

## 14. 凭证开通的分工

用户提供火山引擎账号，由 Claude 用 `playwright` 驱动带界面浏览器协助开通。边界：

- **登录由用户本人完成**——扫码与短信验证码在用户手机上；不接收、不存储账号密码
- **最后一次"确认开通 / 同意协议"的点击由用户本人执行**——该动作产生扣费与签约。Claude 负责把页面推进到该步，并在此前复述价格与计费口径
- Claude 负责：导航、填表、确认所选服务与计费类型正确、开通后抓取 AppID / Token / resource_id 并写入 `~/.doubao-voice/config.json`

## 15. 代码位置

- 主仓：`~/Projects/doubao-voice`
- Lua 部分部署到 `~/.hammerspoon/doubao-voice/`，仓内保留源文件，以符号链接或安装脚本部署

## 16. 验收标准

1. 在 Claude Code、Terminal.app、飞书、Chrome 四处各验证一次，中文长句正确落到光标处
2. 按住右 Option 说话，松手后 1.5 秒内文字上屏
3. 短按右 Option 进入持续录音，HUD 实时滚动显示识别中的文字，再按一下结束并上屏
4. 录音中按 Esc，无任何文字上屏，剪贴板原内容完好
5. 拔网线后录音，HUD 显示错误码，剪贴板未被污染（~~音频落盘~~ 见第 10 节，该能力未实现且已移除）
6. 误触（按一下立即松开且不说话）在 3 秒内自动取消，无文字上屏，剪贴板未被污染；按住不到 300ms 就松手的误触完全不产生 API 调用
7. 重启电脑后 daemon 由 launchd 自动拉起，热键直接可用
8. `git log -p` 全文搜索无任何凭证明文
