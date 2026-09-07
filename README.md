# doubao-voice

macOS 全局语音听写。按住右 Option 说话，语音转成文字，自动粘贴到当前焦点 App 的光标处。

任何 App 都能用——Claude Code、终端、飞书、浏览器、微信。热键走系统级事件捕获，与终端无关。

默认走火山引擎豆包流式 ASR（要凭证，按小时计费）。另有一条**实验性的本地后端**，免费离线但尚未验收通过，见「识别后端」。

## 怎么用

- **按住右 Option** 说话，松手上屏（PTT）
- **短按右 Option** 进入持续录音，再按一下结束上屏（toggle）
- 录音中按 **Esc** 取消，什么都不会上屏
- 短按后 3 秒内没说话会自动取消，误触不会白录

菜单栏图标：🎙 待命 / 🔴 录音中 / 🚫 daemon 掉线。

录音时屏幕底部出现胶囊浮层：呼吸红点 + 实时音频波形 + 计时。松手后波形收起、红点与计时一并消失，只留「识别中」，1–2 秒出文字。

**红点和计时在不在，就是「还在录」与「已录完」的唯一区别。** 服务端偶尔会在你还在说的时候返回一段中间文本，这时波形位置换成那段文字（太长只显示尾部），但红点继续脉动、计时继续走。早先的实现在这里直接套用了「识别中」那个终态、把红点和计时也收掉，看起来跟录完了一模一样，会让人误以为可以松手了。

## 安装

前置条件（macOS 12+）。**本地后端只有 Apple Silicon**——FunASR 的 GGUF 运行时只发 `macos-arm64` 预编译包；Intel Mac 请把 `backend` 设成 `doubao` 走云端：

| 依赖 | 装法 | 必需？ |
|---|---|---|
| [uv](https://docs.astral.sh/uv/) | `curl -LsSf https://astral.sh/uv/install.sh \| sh` | 是 |
| PortAudio | `brew install portaudio` | 是——`sounddevice` 的动态库 |
| Hammerspoon | `brew install --cask hammerspoon` | 是——热键与注入都靠它 |
| Lua + luacheck | `brew install lua luarocks && luarocks install luacheck` | 否，开发才需要 |

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

2.0 的 `nostream` 是「流式输入、一次性输出」——每包音频都回一帧，但基本只有末包的 `text` 非空，中途几乎全是空串。所以做不到稳定的边说边显示，HUD 主体显示的是实时波形而非字幕。

「基本」是因为实测服务端偶尔也会中途吐一段非空文本。`partial` 事件通道一直留着并会把它显示出来，但**不能假设它一定会来**——静音判定就绝不能依赖它（见 `daemon.py` 的 `peak_amplitude`，那里踩过一次：原设计靠服务端非空结果重置静音定时器，结果每次正常录音都在 3 秒时被误杀）。

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
| 说到一半波形变文字 | 正常——服务端返回了中间结果。红点和计时还在就说明仍在录 |

## 开机与休眠

- daemon 由 launchd 管，`RunAtLoad` + `KeepAlive`：开机自起、崩溃自拉
- Hammerspoon 的开机自启在 `init.lua` 里用 `hs.autoLaunch(true)` 保证
- 合盖唤醒后音频设备会重新枚举，daemon 在开麦失败时会重建 Microphone 再试一次

## 开发

```bash
uv run pytest              # 单元测试（94 条，含真跑本地模型的 2 条）
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
- 右 Option 的 CGEvent 位掩码：**`0x40`**（实测完整 flags `0x00080140`）。必须用这个设备相关位，通用的 `kCGEventFlagMaskAlternate`(`0x00080000`) 区分不了左右——左 Option 是 `0x20`，`DBVOICE.probeFlags()` 可以实测校验
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
