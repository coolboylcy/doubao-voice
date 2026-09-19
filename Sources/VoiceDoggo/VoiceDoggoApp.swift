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

        if ProcessInfo.processInfo.arguments.contains("--demo-hud") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { model.presentDemoHUD() }
        }
    }
}

/// 设置窗口的尺寸。
///
/// 窗口由 AppModel.presentSettings 创建、内容由 SettingsView 布局，两边必须用
/// 同一个数——分别硬编码过一次，改了内容高度却漏改窗口，内容直接被截掉。
enum SettingsLayout {
    static let width: CGFloat = 560
    static var height: CGFloat { BuildConfiguration.isLocalDistribution ? 468 : 700 }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                AppIconView(size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text("语音狗子")
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text("macOS 全局语音输入 · 离线识别")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.bottom, 22)

            if model.isLocalDistribution {
                LocalSettingsContent()
                    .environmentObject(model)
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
                    CredentialSettingsView()
                        .environmentObject(model)
                        .padding(4)
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
            }

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

/// 本地版设置页只保留真正需要用户处理的三件事：授权、记住快捷键、决定是否
/// 登录启动。离线识别降为一条事实说明，不再占一整块「服务配置」。
private struct LocalSettingsContent: View {
    @EnvironmentObject private var model: AppModel

    private var grantedCount: Int {
        [model.microphoneGranted, model.accessibilityGranted, model.inputMonitoringGranted]
            .filter { $0 }
            .count
    }

    private var allGranted: Bool { grantedCount == 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 权限装完就不该再占版面。三项齐了折叠成一行，缺项时才展开成卡片
            // ——这是这个界面上唯一需要用户「处理」的东西，没问题时不该抢戏。
            if allGranted {
                grantedSummary
            } else {
                permissionCard
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("快捷键")
                    .font(.headline)
                ShortcutRow(keys: ["⌥ 右"], action: "按住说话，松手上屏")
                ShortcutRow(keys: ["⌥ 右"], action: "短按持续录音，再按一下结束")
                ShortcutRow(keys: ["esc"], action: "录音中取消，不上屏")
            }

            Divider()

            Toggle("登录时自动启动", isOn: Binding(
                get: { model.launchAtLogin.isEnabled },
                set: { model.launchAtLogin.setEnabled($0) }
            ))
            .toggleStyle(.switch)
            .tint(AppBrand.moss)
            if !model.launchAtLogin.errorMessage.isEmpty {
                Text(model.launchAtLogin.errorMessage)
                    .font(.caption)
                    .foregroundStyle(AppBrand.brick)
            }

            Spacer(minLength: 0)
        }
    }

    /// 一切就绪时的折叠态：一行说完「能用了」和「在本机跑」两件事。
    private var grantedSummary: some View {
        HStack(spacing: 11) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 17))
                .foregroundStyle(AppBrand.moss)
            VStack(alignment: .leading, spacing: 1) {
                Text("可以用了 · 按住右 Option 就能开口")
                    .font(.callout.weight(.medium))
                Text("本机离线识别 · 不联网 · 不登记 · 不收费")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(AppBrand.cream.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("还差几步")
                    .font(.headline)
                Spacer()
                Text(String(format: "%d / 3 已开启", grantedCount))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppBrand.brick)
            }

            Text("这三项缺一不可，只需要在第一次使用时处理。")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
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
        }
        .padding(18)
        .background(AppBrand.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppBrand.line, lineWidth: 1)
        }
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
                .foregroundStyle(granted ? Color.secondary : AppBrand.brick)
            Text(title)
            Spacer()
            if !granted {
                Button("去授权", action: action)
                    .buttonStyle(.link)
                    .tint(AppBrand.moss)
                    .foregroundStyle(AppBrand.moss)
            }
        }
        .font(.callout)
    }
}

private enum AppBrand {
    static let cream = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 58 / 255, green: 50 / 255, blue: 38 / 255, alpha: 1)
            : NSColor(red: 234 / 255, green: 220 / 255, blue: 197 / 255, alpha: 1)
    })
    static let moss = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 143 / 255, green: 174 / 255, blue: 151 / 255, alpha: 1)
            : NSColor(red: 83 / 255, green: 107 / 255, blue: 90 / 255, alpha: 1)
    })
    static let brick = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 208 / 255, green: 123 / 255, blue: 108 / 255, alpha: 1)
            : NSColor(red: 164 / 255, green: 74 / 255, blue: 62 / 255, alpha: 1)
    })
    static let paper = Color(nsColor: .controlBackgroundColor)
    static let line = Color.primary.opacity(0.12)
}
