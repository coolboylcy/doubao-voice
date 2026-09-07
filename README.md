# doubao-voice

macOS 全局语音听写。按住右 Option 说话，语音转成文字，自动粘贴到当前焦点 App 的光标处。

任何 App 都能用——Claude Code、终端、飞书、浏览器、微信。热键走系统级事件捕获，与终端无关。

默认走火山引擎豆包流式 ASR（要凭证，按小时计费）。另有一条**实验性的本地后端**，免费离线但尚未验收通过，见「识别后端」。

两个模式，各占一个 Option 键：

| 键 | 作用 |
|---|---|
| **按住右 Option** | 听写——说的话变文字，落到当前光标处 |
| **按住左 Option** | 对话——说完松手，Claude 真去干活，然后念给你听 |

## 听写（右 Option）

- **按住右 Option** 说话，松手上屏（PTT）
- **短按右 Option** 进入持续录音，再按一下结束上屏（toggle）
- 录音中按 **Esc** 取消，什么都不会上屏
- 短按后 3 秒内没说话会自动取消，误触不会白录

录音时屏幕底部出现胶囊浮层：呼吸红点 + 实时音频波形 + 计时。松手后波形收起显示「识别中」，1–2 秒出文字。

## 对话（左 Option）

按住左 Option 说话，松手后 Claude 在**你前台终端的工作目录**里真干活——读文件、跑命令、改代码——然后把结论念给你听。

- **它说话时按一下左 Option = 打断**。打断只停嘴，手上的活继续跑完。跑到一半的 `npm test` 或 git 操作被砍会留下烂摊子，而且你打断多半是想补一句而不是撤销。
- **同一段对话是连着的**，可以说「刚才那个文件再改一下」。菜单栏有「重开一段对话」清空上下文。
- 想指定它在哪个项目干活，把那个终端窗口切到前台再说话。前台不是 Terminal 时回退到 `~`。
- 菜单栏图标：🎙 待命 / 🔴 听写中 / 💬 在听你说 / 🤔 在干活 / 🚫 daemon 掉线

不带 Hammerspoon 的命令行版：`uv run dbvoice chat`，同样的链路，方便调试。

### 成本

对话每一轮都是一次 `claude -p` 调用。实测（Sonnet）：

| | 花费 |
|---|---|
| 新会话第一轮（要载入项目上下文） | ~$0.31 |
| `--resume` 之后每一轮 | ~$0.02 |

**差 14 倍，所以别频繁重开对话。** 默认模型已经是 sonnet；改 `dbvoice chat --model` 或 `agent.DEFAULT_MODEL`。

### 为什么能边干边念

`claude -p --output-format stream-json` 让 Claude 的输出流式出来，它一说话就念一段，不用等整件事干完。但流里混着三类东西，只有第一类能念：

```
assistant.content[].text        → 念
assistant.content[].thinking    → 跳过
assistant.content[].tool_use    → 压成一句提示（"看 config.py"），不念全文
user.content[].tool_result      → 绝对不念，整个文件内容都在里面
```

`speech.py` 还负责把念不出来的东西处理掉：代码块换成「代码我写好了」、表格换成「这里有个表格」、URL 换成「一个链接」、长路径只留文件名、超过四项的列表报总数。`--append-system-prompt` 另外从源头约束 Claude 少输出这些。

## 识别后端

`~/.doubao-voice/config.json` 里的 `backend` 二选一：

| | `doubao`（默认） | `funasr`（实验） |
|---|---|---|
| 跑在哪 | 火山引擎 | 本机 CPU |
| 费用 | 4.5 元/小时音频 | 0 |
| 凭证 | 要 AppID / API Key | 不需要 |
| 联网 | 需要 | 不需要 |
| 首次成本 | 控制台开通服务 | 下 256 MB 模型 |
| 架构 | Apple Silicon + Intel | **仅 Apple Silicon** |
| 状态 | 日常在用 | **未验收通过，见下** |

### 本地后端为什么是「实验」

组件级全绿，真人按键路径上却翻车：

- ✅ 二进制单跑正确：4.24 秒音频 0.15–0.26 秒出结果，比豆包的 1–2 秒还快
- ✅ 经控制 socket 驱动 daemon 全链路正确：播放测试音频经麦克风录入，5.55 秒返回正确文本
- ✅ 127 条测试通过，含 2 条真加载 242 MB 模型跑推理
- ❌ **实际按住右 Option 说话，HUD 停在「识别中」不动**

这个卡死**没能复现，也没定位到**。已排除的方向：daemon 无异常日志；`close_and_collect` 有 30 秒超时，理论最坏也该报错而非永远转圈；Hammerspoon 的控制 socket 连接经 `client:send()` 验证是活的（注意别用 `lsof -U | grep ctl.sock` 判断——它只列监听端，客户端那侧不带路径，会误判成「没连上」）。

所以默认退回 `doubao`。本地这条路代码和测试都留着，谁能定位欢迎开 issue。

### 两条路的体验本来是一样的

都**没有实时字幕**（见下文「没有实时字幕」），HUD 显示的都是波形——豆包 2.0 的 `nostream` 是「流式输入、一次性输出」，中途一个非空结果都没有。所以本地用非流式模型在设计上不损失任何功能，这也是当初值得一试的原因。

`enable_itn` / `enable_punc` 只对 `doubao` 生效；SenseVoiceSmall 自带标点和 ITN（原始输出带 `<|withitn|>` 标记），不需要另挂标点模型。

### `--vad` 是必需的，不是优化项

本地后端永远带 `--vad fsmn-vad.gguf` 跑。不挂 VAD 时，**纯静音会被识别成「我.」这类短词**——PTT 误触就会往你光标处插垃圾字。实测：

| 输入 | 不挂 VAD | 挂 VAD |
|---|---|---|
| 2 秒纯静音 | `我.` | （空） |
| 正常语音 | 正确 | 正确 |

`tests/test_funasr_local.py` 里有两条测试守这个坑（一条查 argv 里有没有 `--vad`，一条真跑模型喂静音）。

### 切换后端

改 `~/.doubao-voice/config.json` 的 `backend`，然后**两个都要重启**——daemon 读配置，Hammerspoon 持有那条控制连接：

```bash
launchctl kickstart -k "gui/$(id -u)/com.doubaovoice.daemon"
pkill -x Hammerspoon && sleep 2 && open -a Hammerspoon
```

只重启 daemon 不重启 Hammerspoon 时，HS 那条连接会被掐断。`client.lua` 有每 3 秒的重连看护，但**别指望它就够**：`hs.socket` 在对端消失时不保证回调空读，所以曾经的实现里缓存标志 `connected` 会永远停在 `true`，重连看护的 `if not self.connected` 永不成立，命令被静默写进死 socket。现在改成直接问 `sock:connected()`，并在 `send` 失败时立刻触发重连、把菜单栏打成 🚫。

命令行临时切换不用改文件也不用重启：

```bash
DBVOICE_BACKEND=funasr uv run dbvoice once -s 6
```

确认 daemon 当前用的哪个：

```bash
grep backend ~/.doubao-voice/daemon.err.log | tail -1
```

## 安装

前置条件（macOS 12+）。**本地后端只有 Apple Silicon**——FunASR 的 GGUF 运行时只发 `macos-arm64` 预编译包；Intel Mac 请把 `backend` 设成 `doubao` 走云端：

| 依赖 | 装法 | 必需？ |
|---|---|---|
| [uv](https://docs.astral.sh/uv/) | `curl -LsSf https://astral.sh/uv/install.sh \| sh` | 是 |
| PortAudio | `brew install portaudio` | 是——`sounddevice` 的动态库 |
| Hammerspoon | `brew install --cask hammerspoon` | 是——热键与注入都靠它 |
| Lua + luacheck | `brew install lua luarocks && luarocks install luacheck` | 否，开发才需要 |
| `claude` CLI | [Claude Code](https://claude.com/claude-code) | 否——只影响左 Option 的对话模式 |

```bash
brew install portaudio
brew install --cask hammerspoon
git clone https://github.com/coolboylcy/doubao-voice.git ~/Projects/doubao-voice
cd ~/Projects/doubao-voice && ./install.sh
```

`install.sh` 会先检查上面这些依赖（缺了直接报名字），然后同步 Python 依赖、软链 Lua 到 `~/.hammerspoon/`、生成 `~/.doubao-voice/config.json`、装载 launchd 服务、重启 Hammerspoon。只有当 `backend` 已经是 `funasr` 时才会顺带下模型。

装完还差三步：

1. 系统设置 → 隐私与安全性，给 Hammerspoon 开 **辅助功能** 与 **输入监控**
2. 按下面「凭证」一节把 key 填进 `~/.doubao-voice/config.json`
3. `uv run dbvoice doctor` 自检，全绿即可

要试本地后端，把 `backend` 改成 `funasr` 后装模型（换机、断线续装、想强制重下也用它）：

```bash
uv run dbvoice fetch-model          # 已有的跳过
uv run dbvoice fetch-model --force  # 强制重下

# huggingface.co 不通时走社区镜像
DBVOICE_HF_HOST=https://hf-mirror.com uv run dbvoice fetch-model
```

它装两样东西到 `~/.doubao-voice/funasr/`：`llama-funasr-*` 二进制（来自 FunASR 的 `runtime-llamacpp` release，7 MB）和两个 GGUF（`sensevoice-small-q8` 242 MB + `fsmn-vad` 1.7 MB）。

## 凭证

在[火山引擎控制台](https://console.volcengine.com/speech/app)开通「豆包流式语音识别模型 2.0」，点「试用」领免费额度，然后把凭证填进 `~/.doubao-voice/config.json`（`install.sh` 已经从 `config.example.json` 生成了一份，权限必须 600）：

```json
{
  "app_id": "你的 AppID",
  "access_key": "你的 Access Token",
  "resource_id": "volc.seedasr.sauc.duration",
  "endpoint": "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream"
}
```

新版控制台签发的是单个 API Key，则写 `{"api_key": "..."}`，其余同上。新旧形态由代码自动判定，不需要额外声明。`resource_id` 与 `endpoint` 的默认值已经指向 2.0 的可用组合，不填也对。完整可配字段见 `src/doubao_voice/config.py` 的 `DEFAULTS`。

### 免费额度用完之后

豆包流式语音识别 2.0 的推理定价是 **4.5 元/小时**（按实际音频时长计，静默不计）。个人听写一天说满 20 分钟，一个月约 45 元。

参考价——腾讯云约 1.0–1.5 元/小时，阿里云 1.80–3.33 元/小时（阶梯资源包）。但换云厂商**协议不通用**：`protocol.py` 那套二进制帧编解码是豆包专用的，得整套重写。

真想把这笔钱降到 0，那条路是本地后端（`backend: "funasr"`，改一个字段就切），代价是它目前还没验收通过——见「本地后端为什么是『实验』」。

### endpoint 千万别改回 `bigmodel`

豆包 2.0（`seedasr`）**只有 `bigmodel_nostream` 能返回文本**。实测：

| 端点 | 行为 |
|---|---|
| `/api/v3/sauc/bigmodel` | 400 `resourceId ... is not allowed`，只服务 1.0 |
| `/api/v3/sauc/bigmodel_async` | 握手通过，但末包不带 `text` |
| `/api/v3/sauc/bigmodel_nostream` | 可用 |

`tests/test_smoke_live.py` 里有一条测试专门守这个坑。

顺带一提，`403 requested resource not granted` 和 `400 not allowed` 含义不同：前者表示端点认识这个 resource_id、只是账号没开通；后者表示端点根本不接受它。

## 没有实时字幕

2.0 的 `nostream` 是「流式输入、一次性输出」——每包音频都回一帧，但只有末包的 `text` 非空，中途全是空串。所以做不到边说边显示文字，HUD 显示的是实时波形而非字幕。

要实时字幕只能回到 1.0（`volc.bigasr.sauc.duration` + `bigmodel`），代价是识别质量较旧，而且 1.0 的试用额度在新账号上未必还能领。代码里的 `partial` 事件通道仍然留着，日后换回双向流式不用改架构。

## 排查

| 症状 | 检查 |
|---|---|
| 按键没反应 | 菜单栏图标是不是 🚫；`launchctl print "gui/$(id -u)/com.doubaovoice.daemon" \| grep state` |
| 识别不出东西 | `uv run dbvoice once -s 6` 单独验证 Python 链路，它会报后端和推流峰值 |
| 按下键就报「建连失败」 | 本地后端模型没装：`uv run dbvoice fetch-model`。`doctor` 会指出缺哪个文件 |
| 静音也吐出「我.」之类怪字 | VAD 没挂上。`doctor` 的「VAD 已挂」那行必须是 ok；`funasr_vad` 指向的文件要存在 |
| 不确定当前用的哪个后端 | `grep backend ~/.doubao-voice/daemon.err.log \| tail -1`，daemon 每次启动都记 |
| 识别结果总是空 | 十有八九是**系统输入音量太低**。`osascript -e "input volume of (get volume settings)"`，低于 50 就调高：`osascript -e "set volume input volume 85"` |
| 文字不上屏 | 系统设置 → 隐私与安全性 → 辅助功能，确认 Hammerspoon 已勾选 |
| 采不到音 | `uv run dbvoice doctor` 看「麦克风权限」一节，它会报峰值 |
| 合盖唤醒后哑了 | 应该会自愈（daemon 检测到 stream 失效会重建麦克风）；不行就 `launchctl kickstart -k "gui/$(id -u)/com.doubaovoice.daemon"` |
| 全都不对 | `tail -50 ~/.doubao-voice/daemon.err.log` |

## 开机与休眠

- daemon 由 launchd 管，`RunAtLoad` + `KeepAlive`：开机自起、崩溃自拉
- Hammerspoon 的开机自启在 `init.lua` 里用 `hs.autoLaunch(true)` 保证
- 合盖唤醒后音频设备会重新枚举，daemon 在开麦失败时会重建 Microphone 再试一次

## 开发

```bash
uv run pytest              # 单元测试（127 条，含真跑本地模型的 2 条）
uv run pytest -m live      # 豆包真 API smoke（要凭证，会消耗额度）
lua tests/state_test.lua   # Lua 状态机测试（44 条断言）
luacheck lua/              # Lua 静态检查，install.sh 也会跑
```

本地后端那两条集成测试真的加载 242 MB 模型跑推理——不花钱所以默认就跑，没装模型时自动跳过。

`luacheck` 不是可有可无的：Lua 的 `local` 只对其后的代码可见，定义在使用之后会静默变成 nil 全局变量，要到运行时才炸，而 `luac -p` 查不出来。这个坑真踩过一次。

架构：Hammerspoon（Lua）持系统权限管热键/HUD/注入，launchd 常驻的 Python daemon 管麦克风和识别，两者通过 `~/.doubao-voice/ctl.sock` 上的换行分隔 JSON 通信。

两个识别后端实现同一套四方法接口（`open` / `send_chunk` / `close_and_collect` / `abort`），`backend.py` 按配置返回其中一个当 `daemon.Daemon` 的 `asr_factory`——所以 `daemon.py` 一行都不知道用的是哪条路。`asr.py` + `protocol.py` 是豆包的 WebSocket 与二进制帧，`funasr_local.py` 是缓冲 PCM 落 WAV 再调二进制。daemon 只认识 start/stop/cancel/ping，不知道当前是 PTT 还是 toggle——所有状态机复杂度留在 `lua/state.lua`，那是个零依赖纯函数，可以用标准 lua 直接跑测试。

设计文档在 `docs/superpowers/specs/`——协议细节、端点选型、状态机推导都在里面。

## 已知环境（实测）

- 控制协议传输层：**Unix domain socket**（`hs.socket` 实测支持，不需要回退 TCP）
- daemon 常驻方式：**launchd**（TCC 麦克风授权正常）
- 右 Option 的 CGEvent 位掩码：**`0x40`**（左 Option 是 `0x20`；实测右 Option 完整 flags 是 `0x00080140`）
- 服务端末包：`flags=0x3` 但 **sequence 是正数**，必须按 flags 判末包，按符号判会永远超时

## 卸载

```bash
launchctl bootout "gui/$(id -u)/com.doubaovoice.daemon"
rm -f ~/Library/LaunchAgents/com.doubaovoice.daemon.plist
rm -f ~/.hammerspoon/doubao-voice          # 只是个软链
rm -rf ~/.doubao-voice                     # 配置与日志，含凭证
```

再把 `~/.hammerspoon/init.lua` 里那行 `require("doubao-voice.init")` 删掉。

## License

[MIT](LICENSE)。凭证与额度是你自己的，本项目不代收也不代理任何请求——所有音频直连火山引擎。
