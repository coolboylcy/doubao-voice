# 语音狗子 · Voice Doggo

macOS 全局语音听写。**按住右 Option 说话，松手文字就落到光标处**——任何 App 都能用：
Claude Code、终端、飞书、浏览器、微信。

识别在本机完成：**离线、免费、音频不出这台电脑**，不需要账号、不需要 API Key、
不消耗任何额度。

- 按住右 Option 说话，松手上屏（PTT）
- 短按右 Option 进入持续录音，再按一下结束
- 录音中按 Esc 取消，什么都不会上屏

## 安装

到 [Releases](https://github.com/coolboylcy/voice-doggo/releases) 下载
`Voice Doggo x.y.z.dmg`，打开后把 App 拖进 Applications，启动它。

要求 **Apple Silicon Mac、macOS 13 或更新**。识别模型只发 arm64 预编译包，
Intel Mac 用不了。

权限没配齐时，设置窗口会自己弹出来，点「一键授权」跟着走完就行：

| 权限 | 用途 | 不给会怎样 |
|---|---|---|
| 麦克风 | 录你说的话 | 完全无法录音 |
| 输入监控 | 全局捕获右 Option 键 | 按键没有任何反应 |
| 辅助功能 | 把识别出的文字粘贴到光标处 | 能识别，但文字上不了屏 |

「一键」是有限度的：麦克风能在 App 里弹个窗点一下就给，另外两项 macOS 只允许
把你送进「系统设置」自己拨开关——没有哪个 App 能替你拨，这是系统设计。能做到的
是你拨完一项它自动跳下一项，不用回来反复点按钮。

**输入监控拨完要重开一次语音狗子才生效**。这一项 macOS 要求进程重启，不是没开
成功；界面上会给一个「重新打开」的按钮。

授权后菜单栏会出现狗头图标，按住右 Option 即可开始。App 启动后需要约 10 秒预热
识别引擎，期间按键无效——这段时间只在刚开机时才会遇到。

## 隐私

音频从麦克风到文字全程在本机完成，App 不发起任何网络请求，也不写任何遥测。
识别用的是随包携带的 FunASR SenseVoice 模型（242 MB，已在 DMG 里）。

仓库里另有一条走火山引擎豆包云端 ASR 的实现，但**它不在你下载的这个版本里**，
需要自己改配置并提供凭证才会启用，见后面的「云端后端」。

## 用起来是什么样

录音时屏幕底部出现深色胶囊浮层：左侧呼吸红点、中间实时波形（40 格 × 50ms =
2 秒可见历史，从右往左滚）、右侧剩余时间倒计时，波形下面单独一行显示识别中的
文本。最后 10 秒整体转为橙红警告态，提示「即将自动结束」。单次录音上限 2 分钟。

松手后波形、红点、倒计时一起收起，只留居中的「识别中」——这两个形态必须一眼
可分，否则会以为已经录完了。

两条视觉规则是踩坑换来的，改 HUD 前先看一眼：

- **录音期间波形永不消失。** 早先让识别文本顶掉波形，说得稍长波形就永久消失、
  再也不回来，看着跟死机一样——其实还在录。所以文字单独占一行，跟波形共存。
- **波形按真实音频时间轴推进，不按渲染帧推进。** 每收到一个电平压入一格，渲染
  只负责画。早先是每帧压一格加指数平滑，等于把波形变成了「音量趋势图」，既有
  延迟又不对应实际说话。

## 排查

App 把三条链路各自记在一个日志里，都在 `~/Library/Application Support/Voice Doggo/`：

| 文件 | 记什么 | 什么时候看 |
|---|---|---|
| `hotkey.log` | event tap 是否启用、每个 flagsChanged 的 keyCode 与 flags、右 Option 的按下/松开 | 按键完全没反应时 |
| `daemon-client.log` | socket 连接状态、发出与收到的每条命令、helper 的启动与重启 | 有波形但没有识别结果时 |
| `session.log` | 每段录音是被 finishRecording、cancelRecording 还是静默超时结束的，以及本段音频峰值 | 录音被莫名其妙中断时 |
| `helper.log` | 识别服务自己的输出（后端选择、socket 路径、麦克风重建） | 上面三个都正常但依然不工作时 |

这几个日志是踩了一串「静默失败」的坑之后加的：NSLog 在 Release + hardened
runtime 下根本不进 unified log，`log show` / `log stream` 全都抓不到，没有落盘
记录就只能靠反复重建二分。

| 症状 | 检查 |
|---|---|
| 按右 Option 完全没反应 | 先看 `hotkey.log` 有没有新增 flagsChanged。**没有**说明事件没进来：`pgrep -f "Voice Doggo.app"` 确认 App 还活着（崩溃后热键会一起失效），再查系统设置里的辅助功能与输入监控 |
| `hotkey.log` 里有 flagsChanged 但 keyCode 不是 61 | 外接/蓝牙键盘的右 Option 键码可能不同，需要按实际键码适配 |
| 有波形，但松手后没有文字 | 看 `daemon-client.log`：`send stop` 之后有没有 `recv final`。停在 `send` 说明识别服务没起来或 socket 断了 |
| 一出声波形就消失 | 看 `session.log` 是不是 `cancelRecording`。这是 Task 取消陷阱的典型症状，见 `Sources/VoiceDoggo/Concurrency.swift` |
| 第一段正常、第二段起按键失灵 | App 多半崩了：`ls -lt ~/Library/Logs/DiagnosticReports/ \| grep -i doggo` |
| 总是提示「没听到内容」 | `session.log` 里有本段峰值。低于 2000 就是系统输入音量太低：`osascript -e "set volume input volume 85"` |
| 菜单栏出现感叹号 | 识别服务反复异常退出，已放弃自动重启。看 `helper.log` 末尾 |
| 后台残留 doggo 进程 | 正常情况下它会在 App 消失后 2 秒内自行退出。若没有，`pkill -f "Helpers/doggo"` 并附上 `helper.log` 提 issue |
| 系统设置里开关是开的，App 却说没授权 | 设置页 → 关于 → 疑难处理 → **重置授权**。见下一节 |

### 换版本之后授权失灵

症状是系统设置里「语音狗子」的开关明明开着，App 却一直提示没授权，得先把那条
记录删掉再重新添加才行。

原因在 macOS 的 TCC：它是**按代码签名记账**的，不是按 App 名字或路径。换了签名
主体——最常见的是从自己构建的版本换成 Releases 里下载的正式版——旧记录的签名
要求对不上新 App，于是成了一条既占着位置又不生效的僵尸记录。

设置页 → 关于 → 疑难处理 → **重置授权** 会替你清掉三项记录并重开 App，等于
「删掉条目重新添加」那一套手工动作。等价的命令行是：

```bash
tccutil reset Microphone com.voicedoggo.app
tccutil reset ListenEvent com.voicedoggo.app
tccutil reset Accessibility com.voicedoggo.app
```

正式版之间升级**不会**有这个问题：Developer ID 签名的 designated requirement
只认 bundle id 和团队，不含版本或哈希，所以覆盖安装授权会留着。

## 卸载

设置页 → 关于 → 疑难处理 → **卸载**。会关掉登录启动、清掉三项系统授权、删除
本机数据，再把 App 移到废纸篓。

之所以给这么个按钮：直接把 App 拖进废纸篓是清不干净的，三项授权会留在「系统
设置 → 隐私与安全性」里。macOS 不给 App 任何「被删除时」的钩子，所以只能在还
活着的时候自己清。

手动清的话：

```bash
rm -rf "/Applications/Voice Doggo.app"
rm -rf ~/Library/"Application Support"/"Voice Doggo"   # 配置与日志
tccutil reset Microphone com.voicedoggo.app
tccutil reset ListenEvent com.voicedoggo.app
tccutil reset Accessibility com.voicedoggo.app
```

---

以下面向开发者。

## 从源码构建

需要 Xcode、[uv](https://docs.astral.sh/uv/)、[xcodegen](https://github.com/yonaskolb/XcodeGen)
和一张 Apple Development 证书：

```bash
brew install xcodegen
./scripts/build-macos-app.sh   # 生成 dist/Voice Doggo.app
./scripts/make-dmg.sh          # 生成本机测试用的 DMG
```

构建脚本会自动用 PyInstaller 打出内置的 `doggo` helper，并把 FunASR 模型
拷进 App。模型来自 `~/.voice-doggo/funasr/`，没有的话先 `uv run doggo fetch-model`。

**本地版不开 App Sandbox，这是硬性要求，不是偷懒。** 沙盒会禁掉 System V 信号量
（`semctl` 返回 EPERM），而 PyInstaller onefile 的 bootloader 启动时必须建一个，
于是内置 helper 每次都死在 `Failed to initialize sync semaphore`，录音链路整条
起不来——外部表现只是「按了没反应」，毫无线索。所以本地版走
`App/VoiceDoggo-local.entitlements`，商店版才用带沙盒的 `App/VoiceDoggo.entitlements`。
`verify-release.sh` 里有一条断言专门防止这两份配置被弄混。

## 发布可分发的 DMG

`make-dmg.sh` 出的镜像用 Apple Development 证书签名，**只能在你自己这台机器上用**，
别人下载会被 Gatekeeper 拦住。要发给别人必须用 Developer ID 签名并经 Apple 公证：

```bash
./scripts/release-dmg.sh
```

首次运行前要准备两样东西，脚本检测不到会指名道姓地告诉你怎么弄：

1. **Developer ID Application 证书**。跟 Apple Development（本机调试）和
   Apple Distribution（提交商店）都不是一回事，要单独创建：Xcode → Settings →
   Accounts → Manage Certificates → + → Developer ID Application。
2. **公证凭据**。去 account.apple.com 生成一个 App 专用密码，然后
   `xcrun notarytool store-credentials`，只需配置一次。

脚本做的事：从内到外重新签名（内嵌可执行文件 → helper → App 本体，顺序不能乱，
先签外层再改内层会让外层失效）、生成 DMG、提交公证、装订票据，最后**给镜像打上
隔离属性再用 Gatekeeper 的安装规则评估一次**——那是唯一能证明「别人下下来能用」
的检查，在自己机器上 `codesign --verify` 通过并不说明问题。

两个容易踩的点已经写进脚本：签名必须带 `--timestamp`（公证要求 secure timestamp，
而本机构建默认是 `--timestamp=none`），helper 需要
`App/Helper.entitlements` 里那两条 entitlement 才能在 hardened runtime 下加载
PyInstaller 解压出来的运行时——少了它们，本机测试一切正常，公证后的 App 在别人
机器上会启动瞬间被杀。

## 开发与测试

```bash
uv run pytest                # Python 测试（106 条；有本地模型时会真跑推理）
uv run pytest -m live        # 豆包云端真 API smoke（要凭证，会消耗额度）
uv run doggo doctor        # 自检配置、音频设备、权限
uv run doggo once -s 6     # 不经过 App，单独验证整条 Python 链路

xcodebuild -project VoiceDoggo.xcodeproj -scheme VoiceDoggo \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGN_ENTITLEMENTS=App/VoiceDoggo-local.entitlements \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) LOCAL_DISTRIBUTION' \
  -only-testing:VoiceDoggoTests test     # Swift 测试（14 条）

./scripts/verify-release.sh  # 10 步发布验收
```

验收脚本依次跑 Python / Swift 测试、签名、**entitlements 里没有 sandbox**、
**识别服务控制链路端到端（ping → start → 音频电平 → stop → 终态）**、
**宿主消失后服务自行退出且退出码为 0**、DMG 完整性，最后直接运行镜像内的离线
模型识别真实音频。

中间那三条是补上去的——此前脚本只验签名和模型，完全不碰 Swift 端与进程通信，
于是一整批「从热键到上屏没有一步是通的」的故障全部漏网，验收却是全绿。

两个注意事项：

- Swift 测试的 `TEST_HOST` 就是 App 本体，**开着 App 跑测试会卡到超时**。脚本
  会提前拦下并提示，或者用 `VERIFY_KILL_RUNNING_APP=1` 让它自动停掉 App。
- UI 测试需要 Xcode 测试 runner 的自动化权限，默认跳过并显式打印。授权后用
  `VERIFY_UI_TESTS=1` 启用。

## 架构

一个原生菜单栏 App 加一个随包携带的 Python 识别服务：

- **Swift 侧**（`Sources/VoiceDoggo/`）持系统权限，管全局热键、HUD、文本注入，
  以及识别服务的启动、预热和崩溃重启。
- **Python 侧**（`src/voice_doggo/`）管麦克风采集与语音识别，打包成单个
  `doggo` 可执行文件放进 App。
- 两者通过 `~/Library/Application Support/Voice Doggo/ctl.sock` 上的换行分隔
  JSON 通信，服务只认识 `start` / `stop` / `cancel` / `ping` 四个命令，**不知道
  当前是 PTT 还是 toggle**——那套状态机完全留在 Swift 侧。

改代码前值得先读的三处注释，都是踩坑换来的因果：

| 文件 | 讲什么 |
|---|---|
| `Concurrency.swift` | 为什么不能直接写 `try? await Task.sleep` |
| `GlobalHotkey.swift` | 为什么不能在 event tap 回调里查 `CGEventSource.keyState` |
| `mic.py` | 为什么 stream 构造时 open、录音时才 start |

**进程生命周期**：

- **启动即预热**。App 一起来就拉起识别服务，不等第一次按键。PyInstaller onefile
  冷启动要十几秒，懒加载会让第一段录音整段丢掉（命令全堆在客户端队列里，等服务
  就绪才发出）。常驻不会点亮麦克风指示灯——stream 是构造时 open、录音时才 start。
- **崩溃自愈**。意外退出后按 1/2/4/8/16 秒退避重启，最多 5 次；连续跑满 60 秒算
  恢复正常，计数归零。超过上限就停手并在菜单栏报错，不无限拉起进程。
- **孤儿自清理**。App 崩溃时 `terminationHandler` 不会执行，所以由服务自己盯着
  宿主：App 通过 `DOGGO_PARENT_PID` 告知 pid，每 2 秒检查一次，宿主没了就清掉
  socket 并退出。这里不能用 `getppid()`——onefile 的 Python 进程父级是 bootloader
  而不是 App，App 崩了那个值也不变。
- 合盖唤醒后音频设备会重新枚举，开麦失败时会重建 Microphone 再试一次。

**采集粒度与 ASR 包大小刻意解耦**：麦克风按 50ms 采（`mic.CHUNK_MS`），每包报一个
`level` 事件——20 格/秒，波形才跟得上说话；服务攒够 200ms 再推给识别后端
（`daemon.ASR_CHUNK_BYTES`），那是官方建议的包大小。停止时不足一整包的尾巴会补发，
否则最后 200ms 内的字会被切掉。

两个识别后端实现同一套四方法接口（`open` / `send_chunk` / `close_and_collect` /
`abort`），`backend.py` 按配置返回其中一个——所以 `daemon.py` 一行都不知道自己在
用哪条路。`funasr_local.py` 是缓冲 PCM 落 WAV 再调二进制，`asr.py` + `protocol.py`
是豆包的 WebSocket 与二进制帧。

设计文档在 `docs/superpowers/specs/`——协议细节、端点选型、状态机推导都在里面。

## 云端后端（可选）

默认的本地识别免费离线，不需要看这节。想改走火山引擎豆包云端 ASR 才需要。

在[火山引擎控制台](https://console.volcengine.com/speech/app)开通「豆包流式语音
识别模型 2.0」，把凭证填进 `~/.voice-doggo/config.json`（权限必须 600），并把
`backend` 改成 `doubao`：

```json
{
  "backend": "doubao",
  "api_key": "你的 API Key",
  "resource_id": "volc.seedasr.sauc.duration",
  "endpoint": "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream"
}
```

老版控制台签发的是 AppID + Access Token，写 `app_id` 和 `access_key` 即可，
新旧形态由代码自动判定。完整可配字段见 `src/voice_doggo/config.py` 的 `DEFAULTS`。

推理定价 **4.5 元/小时**（按实际音频时长计，静默不计）。个人听写一天说满 20 分钟，
一个月约 45 元。参考价：腾讯云约 1.0–1.5 元/小时，阿里云 1.80–3.33 元/小时。但换
云厂商**协议不通用**，`protocol.py` 那套二进制帧编解码是豆包专用的，得整套重写。

### endpoint 千万别改回 `bigmodel`

豆包 2.0（`seedasr`）**只有 `bigmodel_nostream` 能返回文本**。实测：

| 端点 | 行为 |
|---|---|
| `/api/v3/sauc/bigmodel` | 400 `resourceId ... is not allowed`，只服务 1.0 |
| `/api/v3/sauc/bigmodel_async` | 握手通过，但末包不带 `text` |
| `/api/v3/sauc/bigmodel_nostream` | 可用 |

`tests/test_smoke_live.py` 里有一条测试专门守这个坑。顺带一提，
`403 requested resource not granted` 和 `400 not allowed` 含义不同：前者表示端点
认识这个 resource_id、只是账号没开通；后者表示端点根本不接受它。

### 中间结果什么时候会有

`nostream` 这个名字容易误导。实测（连续录 60 秒）：说一两句话时中途全是空串、
只有末包带 `text`；说得较长则**每约 0.2 秒回一次累积文本**。

所以「2.0 完全没有实时字幕」是错的——短句没有，长句一直有。项目早期按「一定没有」
来设计，踩了两个坑：静音判定原本靠服务端非空结果重置定时器，短句下一个非空结果都
没有，每次正常录音都在 3 秒时被误杀（改成本地音量判定 `daemon.peak_amplitude`）；
HUD 拿中间文本去顶替波形，长句下波形永久消失（改成文字独立一行）。

`result.text` 是**累积**文本而非增量，整体替换显示即可，不要拼接。

## 已知环境（实测）

- 右 Option 的 CGEvent 位掩码：**`0x40`**（实测完整 flags `0x00080140`）。必须用
  这个设备相关位，通用的 `kCGEventFlagMaskAlternate`（`0x00080000`）区分不了左右
  ——左 Option 是 `0x20`
- 豆包服务端末包：`flags=0x3` 但 **sequence 是正数**，必须按 flags 判末包，按符号
  判会永远超时
- 系统输入音量低于 50% 时，本地识别大概率返回空——整段峰值只有一千出头，模型拿到
  的基本是底噪

## License

[MIT](LICENSE)。本地识别不涉及任何服务端。若启用云端后端，凭证与额度是你自己的，
本项目不代收也不代理任何请求——所有音频直连火山引擎。
