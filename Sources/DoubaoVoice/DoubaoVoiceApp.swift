import AppKit
import SwiftUI

@main
struct DoubaoVoiceApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(model)
        } label: {
            Image(systemName: model.menuIcon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(model.menuColor)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuContent: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Doubao Voice")
                        .font(.headline)
                    Text(model.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            if model.isRecording {
                Button {
                    model.stopFromMenu()
                } label: {
                    Label("完成听写", systemImage: "checkmark.circle")
                }

                Button {
                    model.cancelRecording()
                } label: {
                    Label("取消本次听写", systemImage: "xmark.circle")
                }
            } else {
                Button {
                    model.startFromMenu()
                } label: {
                    Label("开始听写", systemImage: "mic.fill")
                }
                // 未订阅或额度耗尽时仍允许点击，让用户看到明确的订阅墙，
                // 而不是一个看起来像坏掉的灰色按钮。
                .disabled(model.isRecording)
            }

            HStack {
                Text("本周期额度")
                Spacer()
                Text(model.quotaText)
                    .foregroundStyle(model.quotaColor)
            }
            .font(.caption)

            Divider()

            SettingsMenuButton()

            Button("退出 Doubao Voice") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(14)
        .frame(width: 260)
    }
}

struct SettingsMenuButton: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button {
            model.presentSettings()
        } label: {
            Label("设置与订阅", systemImage: "gearshape")
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Doubao Voice")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("macOS 全局语音输入")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.bottom, 26)

            if model.isLocalDistribution {
                GroupBox {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.subscriptionTitle).font(.headline)
                            Text(model.subscriptionDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Label("已激活", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .font(.caption.weight(.semibold))
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
                    Label("FunASR 本地模型已随 App 安装，可离线使用", systemImage: "internaldrive.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    Toggle("登录时自动启动 Doubao Voice", isOn: Binding(
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

            HStack {
                Text("右 Option：按住说话；短按后再次按下结束")
                Spacer()
                Text("v0.2.0")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 560, height: model.isLocalDistribution ? 560 : 700)
        .task { await model.refresh() }
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
