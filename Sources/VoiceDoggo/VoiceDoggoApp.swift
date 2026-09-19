import AppKit
import SwiftUI

@main
struct VoiceDoggoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // App 协议要求至少有一个 Scene，但这个 App 的界面全部由 AppDelegate
        // 里的 NSStatusItem 和按需创建的设置窗口负责，这里放一个空的即可。
        Settings { EmptyView() }
    }
}

/// 用 AppDelegate 而不是 SwiftUI 的 MenuBarExtra 承载菜单栏。
/// 原因见 StatusItem.swift 顶部：MenuBarExtra 在 macOS 26 + LSUIElement 下
/// 不会创建菜单栏项，App 跑着却完全看不见。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        self.model = model
        statusItem = StatusItemController(model: model)
    }
}

/// 设置窗口的尺寸。
///
/// 窗口由 AppModel.presentSettings 创建、内容由 SettingsView 布局，两边必须用
/// 同一个数——分别硬编码过一次，改了内容高度却漏改窗口，内容直接被截掉。
enum SettingsLayout {
    static let width: CGFloat = 560
    static var height: CGFloat { BuildConfiguration.isLocalDistribution ? 545 : 700 }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                AppIconView(size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Voice Doggo")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("macOS 全局语音输入 · 离线识别")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.bottom, 22)

            if model.isLocalDistribution {
                // 本地版没有订阅也没有额度，这个位置换成真正有用的东西：
                // 三个快捷键怎么用。原先这里是订阅卡片改造来的「已激活」状态，
                // 对一个免费离线工具来说纯属噪音。
                GroupBox("快捷键") {
                    VStack(alignment: .leading, spacing: 9) {
                        ShortcutRow(keys: ["⌥ 右"], action: "按住说话，松手上屏")
                        ShortcutRow(keys: ["⌥ 右"], action: "短按进入持续录音，再按一下结束")
                        ShortcutRow(keys: ["esc"], action: "录音中取消，不上屏")
                    }
                    .padding(4)
                }
            } else {
                SubscriptionSettingsView()
                    .environmentObject(model)

                GroupBox("本周期用量") {
                    VStack(alignment: .leading, spacing: 10) {
                        ProgressView(value: model.quotaProgress)
                            .tint(model.quotaColor)
                        HStack {
                            Text(model.quotaText)
                            Spacer()
                            Text("每月 \(model.monthlyQuotaHours) 小时")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                    .padding(4)
                }
                .padding(.top, 14)
            }

            GroupBox("权限状态") {
                VStack(alignment: .leading, spacing: 8) {
                    PermissionRow(title: "麦克风", granted: model.microphoneGranted) {
                        model.requestMicrophonePermission()
                    }
                    PermissionRow(title: "辅助功能", granted: model.accessibilityGranted) {
                        model.openAccessibilitySettings()
                    }
                    PermissionRow(title: "输入监控", granted: model.inputMonitoringGranted) {
                        model.openInputMonitoringSettings()
                    }
                }
                .padding(4)
            }
            .padding(.top, 14)

            GroupBox("识别服务") {
                if model.isLocalDistribution {
                    HStack(spacing: 10) {
                        Image(systemName: "lock.laptopcomputer")
                            .font(.system(size: 20))
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("本机离线识别")
                                .font(.callout.weight(.medium))
                            Text("FunASR SenseVoice 模型随 App 安装，音频不会离开这台电脑，也不消耗任何额度")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(4)
                } else {
                    CredentialSettingsView()
                        .environmentObject(model)
                        .padding(4)
                }
            }
            .padding(.top, 14)

            GroupBox("启动行为") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("登录时自动启动语音狗子", isOn: Binding(
                        get: { model.launchAtLogin.isEnabled },
                        set: { model.launchAtLogin.setEnabled($0) }
                    ))
                    if !model.launchAtLogin.errorMessage.isEmpty {
                        Text(model.launchAtLogin.errorMessage)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(4)
            }
            .padding(.top, 14)

            Spacer()

            HStack(spacing: 6) {
                // 链接不能套 .secondary：那会把它染成和普通文字一样的灰，
                // 看不出可以点
                Link("GitHub", destination: URL(string: "https://github.com/coolboylcy/voice-doggo")!)
                Text("·").foregroundStyle(.secondary)
                Text("MIT").foregroundStyle(.secondary)
                Spacer()
                Text("v\(appVersion)").foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(28)
        .frame(width: SettingsLayout.width, height: SettingsLayout.height)
        .task { await model.refresh() }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"
    }
}

/// 设置页顶部的图标。直接用 App 自己的图标，而不是再找一个 SF Symbol——
/// 那样用户在 Dock、访达和设置页里会看到三个不一样的东西。
private struct AppIconView: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "waveform.circle.fill")
                    .resizable()
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct ShortcutRow: View {
    let keys: [String]
    let action: String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
            }
            Text(action)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

private struct SubscriptionSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.subscriptionTitle).font(.headline)
                        Text(model.subscriptionDetail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isSubscribed {
                        Label("已激活", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .font(.caption.weight(.semibold))
                    }
                }
                HStack(spacing: 10) {
                    Button(model.isSubscribed ? "刷新订阅" : "订阅 Pro") {
                        Task { await model.purchaseOrRefresh() }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("恢复购买") { Task { await model.restorePurchases() } }
                        .buttonStyle(.bordered)
                    if model.isSubscribed {
                        Button("管理订阅") { model.openSubscriptionManagement() }
                            .buttonStyle(.link)
                    }
                }
                if !model.subscriptions.purchaseError.isEmpty {
                    Text(model.subscriptions.purchaseError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(4)
        }
    }
}

private struct CredentialSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var useAPIKey = true
    @State private var apiKey = ""
    @State private var appID = ""
    @State private var accessKey = ""
    @State private var saved = false

    private var complete: Bool {
        useAPIKey ? !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            : !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !accessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("凭证类型", selection: $useAPIKey) {
                Text("新版 API Key").tag(true)
                Text("旧版 AppID + Token").tag(false)
            }
            .pickerStyle(.segmented)

            if useAPIKey {
                SecureField("API Key", text: $apiKey)
            } else {
                TextField("AppID", text: $appID)
                SecureField("Access Token", text: $accessKey)
            }

            HStack {
                Button("保存到钥匙串") {
                    model.saveCredentials(
                        apiKey: useAPIKey ? apiKey : "",
                        appID: useAPIKey ? "" : appID,
                        accessKey: useAPIKey ? "" : accessKey
                    )
                    saved = true
                }
                .disabled(!complete)
                if saved {
                    Label("已保存", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
                Spacer()
                Text("凭证仅保存在本机钥匙串")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            let credentials = model.loadCredentials()
            apiKey = credentials.apiKey
            appID = credentials.appID
            accessKey = credentials.accessKey
            useAPIKey = !credentials.apiKey.isEmpty || credentials.appID.isEmpty
        }
        .onChange(of: apiKey) { _ in saved = false }
        .onChange(of: appID) { _ in saved = false }
        .onChange(of: accessKey) { _ in saved = false }
        .onChange(of: useAPIKey) { _ in saved = false }
    }
}

struct PermissionRow: View {
    let title: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? .green : .orange)
            Text(title)
            Spacer()
            if !granted {
                Button("去授权", action: action)
                    .buttonStyle(.link)
            }
        }
        .font(.callout)
    }
}
