# 语音狗子 商店发布清单

App Store Connect 文案初稿见：[元数据草案](app-store-metadata.md)。

## 当前本地构建状态

- 原生菜单栏 App：已加入 SwiftUI/AppKit UI、权限引导、StoreKit 2 月订阅入口、Keychain 本地额度缓存、倒计时 HUD 和最后 10 秒警告态。
- 安装形态：App 内置 `doggo` helper 与离线模型，用户不需要安装任何额外依赖，也不联网。
- 生命周期：helper 只在用户真正开始听写且麦克风已授权后启动，App 退出时回收整个 helper 进程组。
- 首次配置：设置页支持录入新版 API Key 或旧版 AppID/Access Token，凭证只通过 Keychain 保存，并由 App 的进程环境传给 helper。
- 架构：Apple Silicon，macOS 13+。当前 helper 是 arm64，因此不发布 Intel 版本。
- 本地验证：Python 100 项测试通过，Lua 状态机和静态检查通过，Xcode Debug/Release 构建通过，Distribution 归档和代码签名通过；归档内 helper 可独立启动。

## Apple 账号侧需要完成

1. 在 Certificates, Identifiers & Profiles 注册 App ID：`com.voicedoggo.app`，启用 App Sandbox、麦克风和网络能力。
2. 在 App Store Connect 创建 macOS App，Bundle ID 选择 `com.voicedoggo.app`。
3. 创建订阅组，并创建自动续订月订阅：`com.voicedoggo.pro.monthly`。这个 ID 必须和 `Sources/VoiceDoggo/SubscriptionStore.swift` 完全一致。
4. 填写隐私政策 URL、支持 URL、分类、年龄分级、价格、税务和银行信息，上传 macOS 截图及审核备注。
5. 在本机安装与 Team ID `KR7SB9VHJZ` 匹配的 **Mac Installer Distribution** 证书。当前导出失败的唯一明确本机原因就是缺少该证书。
6. 创建 App Store Connect API Key，并将 `.p8` 私钥放在仓库之外，再按脚本要求设置环境变量。

## 导出和上传

本地体验包可由 `scripts/make-dmg.sh` 生成；它不替代 App Store Connect 导出，也不包含公证结果。

```bash
export TEAM_ID=KR7SB9VHJZ
export ASC_KEY_ID='你的 Key ID'
export ASC_ISSUER_ID='你的 Issuer ID'
export ASC_KEY_PATH='/仓库之外/AuthKey_XXXXXXXXXX.p8'

./scripts/archive-app-store.sh
```

脚本会重新生成 Xcode 项目、归档并导出 App Store 提交包。导出成功后再在 Xcode Organizer 或 Transporter 中上传，并在 App Store Connect 里完成提交审核。

## 商业化上线前不能省略的后端工作

当前原生 App 已经完成客户端订阅墙和本地额度机制，并提供了用户在设置页录入自己豆包凭证的临时可用路径；它仍然复用项目里的 Python ASR helper。新机器没有用户配置时，helper 不会凭空拥有火山引擎凭证；也不应该把你的长期 ASR 密钥打进 App。

正式商业版需要先部署授权服务：支付回调更新订阅状态，服务端签发短期 entitlement 和短期 ASR token，客户端只保存短期凭证；每次开始录音和录音过程中同步服务端额度，客户端本地额度只做离线缓存。否则用户删除 Keychain 或改本地时间即可绕过额度墙，不适合作为正式收费版本。

也就是说：本仓库现在已经可以产出可签名的原生 App 和完整 UI 骨架，但在 ASR 授权服务上线前，不应把它宣称为可直接面向公众收费的最终版本。
