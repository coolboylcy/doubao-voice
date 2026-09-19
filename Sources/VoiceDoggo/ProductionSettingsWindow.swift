import AppKit
import SwiftUI

struct ProductionSettingsWindow: View {
    @EnvironmentObject private var model: AppModel
    @State private var section: ProductionSection

    init(initialSection: String? = nil) {
        _section = State(initialValue: ProductionSection(rawValue: initialSection ?? "") ?? .general)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.65)
            HStack(spacing: 0) {
                sidebar
                Divider().opacity(0.55)
                pane
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(DoggoUI.window)
    }

    private var header: some View {
        HStack(spacing: 13) {
            if let icon = NSImage(named: "AppMark") ?? NSImage(named: "AppIcon") {
                Image(nsImage: icon).resizable().frame(width: 42, height: 42)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("语音狗子")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(DoggoUI.title)
                Text("Voice Doggo · 有嘴就能编程")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DoggoUI.secondary)
            }
            Spacer()
            statusPill
        }
        .padding(.horizontal, 24)
        .padding(.top, SettingsLayout.titlebarInset)
        .padding(.bottom, 15)
    }

    private var statusPill: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(model.engineReady ? DoggoUI.success : DoggoUI.warning)
                .frame(width: 7, height: 7)
            Text(model.engineReady ? "本地识别已就绪" : "正在启动本地识别")
                .font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(DoggoUI.text)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(DoggoUI.card, in: Capsule())
        .overlay(Capsule().stroke(DoggoUI.line, lineWidth: 1))
    }

    private var sidebar: some View {
        VStack(spacing: 5) {
            ForEach(ProductionSection.allCases) { item in
                Button { section = item } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.icon)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 20)
                        Text(item.title)
                            .font(.system(size: 13.5, weight: section == item ? .semibold : .regular))
                        Spacer()
                    }
                    .foregroundStyle(section == item ? DoggoUI.blue : DoggoUI.text)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(section == item ? DoggoUI.selection : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("免费 · 无需配置 · 本地识别")
                .font(.system(size: 10.5))
                .foregroundStyle(DoggoUI.tertiary)
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 12)
        .padding(.top, 18)
        .frame(width: 188)
        .background(DoggoUI.sidebar)
    }

    @ViewBuilder
    private var pane: some View {
        switch section {
        case .general: GeneralProductionPane().environmentObject(model)
        case .shortcut: ShortcutProductionPane().environmentObject(model)
        case .speech: SpeechProductionPane().environmentObject(model)
        case .appearance: AppearanceProductionPane().environmentObject(model)
        case .advanced: AdvancedProductionPane().environmentObject(model)
        case .about: AboutProductionPane().environmentObject(model)
        }
    }
}

enum ProductionSection: String, CaseIterable, Identifiable {
    case general, shortcut, speech, appearance, advanced, about

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "通用"
        case .shortcut: return "快捷键"
        case .speech: return "语音识别"
        case .appearance: return "外观"
        case .advanced: return "高级"
        case .about: return "关于"
        }
    }
    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .shortcut: return "keyboard"
        case .speech: return "waveform"
        case .appearance: return "paintbrush"
        case .advanced: return "gearshape.2"
        case .about: return "info.circle"
        }
    }
}

private struct GeneralProductionPane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneTitle("通用", subtitle: "为 Claude Code 和常用编辑器准备的零打断语音输入")

            ClaudeWorkflowCard(hotkey: model.hotkeyTitle)

            SettingsGroup("启动与权限") {
                SettingLine(title: "登录时自动启动", detail: "随 macOS 启动并常驻菜单栏") {
                    BrandSwitch(isOn: Binding(
                        get: { model.launchAtLogin.isEnabled },
                        set: { model.launchAtLogin.setEnabled($0) }
                    ))
                }
                Hairline()
                PermissionSummary(model: model)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ShortcutProductionPane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneTitle("快捷键", subtitle: "按住说话、松手上屏；短按则进入持续听写")

            SettingsGroup("主快捷键") {
                SettingLine(title: "听写按键", detail: "左右 Option 均可选择，修改后立即生效") {
                    ChoiceStrip(
                        choices: AppPreferences.Hotkey.allCases.map { ($0.title, $0) },
                        selection: Binding(get: { model.preferences.hotkey }, set: { model.preferences.hotkey = $0 })
                    )
                }
            }

            HStack(spacing: 12) {
                InstructionCard(icon: "hand.tap", title: "按住说话", detail: "松开后直接输入光标位置")
                InstructionCard(icon: "record.circle", title: "短按持续", detail: "再按一次结束听写")
                InstructionCard(icon: "escape", title: "Esc 取消", detail: "不识别，也不会上屏")
            }

            InlineNote(icon: "cursorarrow.rays", text: "浮层是 non-activating panel，不会抢走 Claude Code、Cursor 或终端的输入焦点。")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SpeechProductionPane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneTitle("语音识别", subtitle: "SenseVoice 在本机运行；音频不会离开这台 Mac")

            // 这里曾经有「识别语言」下拉和「自动检测语言」开关，删掉了：两者都
            // 接不上任何东西。SenseVoice 是多语言自动识别的，而打包进来的
            // llama-funasr-sensevoice 根本不接受语言参数（usage 里只有
            // -m/-a/-f/--vad/--backend/--srt/--ids/--keep-tags）。摆在那儿切来
            // 切去毫无效果，出了问题还会把人往错的方向引——不如直接说清楚它本来
            // 就不用选。
            SettingsGroup("本地引擎") {
                EngineRow(model: model)
                Hairline()
                SettingLine(title: "识别语言", detail: "中英混说不用切换，模型自己分辨") {
                    Text("自动").font(.system(size: 12.5, weight: .medium)).foregroundStyle(DoggoUI.secondary)
                }
                Hairline()
                SettingLine(title: "单次听写上限", detail: "到达上限时自动结束并输入文字") {
                    Text("2 分钟").font(.system(size: 12.5, weight: .medium)).foregroundStyle(DoggoUI.secondary)
                }
            }

            InlineNote(icon: "lock.shield", text: "免费使用，无账号、无 API Key、无上传、无遥测。")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AppearanceProductionPane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneTitle("外观", subtitle: "克制的蓝白界面，保留一点傻狗的存在感")

            SettingsGroup("听写浮层") {
                HStack(spacing: 18) {
                    DoggoMotionView(phase: .speaking, level: 0.7)
                        .frame(width: 84, height: 84)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("12 帧实时狗子")
                            .font(.system(size: 13.5, weight: .semibold))
                        Text("idle / listening / speaking / finishing\n跟随真实麦克风音量，不播放视频")
                            .font(.system(size: 11.5))
                            .foregroundStyle(DoggoUI.secondary)
                            .lineSpacing(2)
                    }
                    Spacer()
                    BrandSwitch(isOn: Binding(
                        get: { model.preferences.showHUD },
                        set: { model.preferences.showHUD = $0 }
                    ))
                }
                .padding(.vertical, 12)
            }

            SettingsGroup("菜单栏图标") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("模板图标会自动适配深色与浅色菜单栏")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DoggoUI.secondary)
                    HStack(spacing: 10) {
                        ForEach(AppPreferences.MenuIconStyle.allCases) { style in
                            IconStyleButton(
                                style: style,
                                selected: model.preferences.menuIconStyle == style
                            ) { model.preferences.menuIconStyle = style }
                        }
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AdvancedProductionPane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneTitle("高级", subtitle: "控制识别完成后的行为与系统反馈")

            SettingsGroup("输入行为") {
                SettingLine(title: "自动输入到当前光标", detail: "关闭后只复制到剪贴板，不发送按键") {
                    BrandSwitch(isOn: Binding(
                        get: { model.preferences.automaticInsertion },
                        set: { model.preferences.automaticInsertion = $0 }
                    ))
                }
                Hairline()
                SettingLine(title: "启动时提示", detail: "首次启动或缺少权限时显示设置窗口") {
                    BrandSwitch(isOn: Binding(
                        get: { model.preferences.startupHint },
                        set: { model.preferences.startupHint = $0 }
                    ))
                }
                Hairline()
                SettingLine(title: "系统通知", detail: "仅用于权限、识别失败等需要处理的状态") {
                    BrandSwitch(isOn: Binding(
                        get: { model.preferences.systemNotifications },
                        set: { model.setSystemNotifications($0) }
                    ))
                }
            }

            SettingsGroup("权限") {
                PermissionDetailLine(title: "麦克风", granted: model.microphoneGranted, action: { model.requestPermission(.microphone) })
                Hairline()
                PermissionDetailLine(title: "输入监控", granted: model.inputMonitoringGranted, action: { model.requestPermission(.inputMonitoring) })
                Hairline()
                PermissionDetailLine(title: "辅助功能", granted: model.accessibilityGranted, action: { model.requestPermission(.accessibility) })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AboutProductionPane: View {
    @EnvironmentObject private var model: AppModel
    @State private var checking = false
    @State private var upToDate = false

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.1"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneTitle("关于", subtitle: "语音狗子 · Voice Doggo")

            HStack(spacing: 18) {
                if let icon = NSImage(named: "AppMark") ?? NSImage(named: "AppIcon") {
                    Image(nsImage: icon).resizable().frame(width: 76, height: 76)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("有嘴就能编程")
                        .font(.system(size: 19, weight: .semibold))
                    Text("版本 \(version) · Apple Silicon · macOS 13+")
                        .font(.system(size: 12))
                        .foregroundStyle(DoggoUI.secondary)
                    Text("本地语音识别 · 免费 · 无需配置")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DoggoUI.blue)
                }
                Spacer()
            }
            .padding(20)
            .background(DoggoUI.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            SettingsGroup("更新") {
                SettingLine(title: "自动检查更新", detail: "有新版本时狗子会来找你，可以跳过或以后再说") {
                    Button(checking ? "检查中…" : "现在检查") {
                        guard let updater = model.updater else { return }
                        checking = true
                        Task {
                            await updater.check(userInitiated: true)
                            checking = false
                            // 查完还是 idle，说明没有更新——用户是自己点的按钮，
                            // 不能毫无反馈。
                            if case .idle = updater.phase { upToDate = true }
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(checking || model.updater == nil)
                }
                if upToDate {
                    Text("已经是最新版本 v\(version)")
                        .font(.system(size: 12))
                        .foregroundStyle(DoggoUI.success)
                        .padding(.bottom, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            SettingsGroup("隐私与支持") {
                SettingLine(title: "隐私说明", detail: "录音只在本机处理，Voice Doggo 不收集使用数据") { EmptyView() }
                Hairline()
                HStack(spacing: 10) {
                    LinkButton(title: "使用指南", url: "https://github.com/coolboylcy/voice-doggo#readme")
                    LinkButton(title: "常见问题", url: "https://github.com/coolboylcy/voice-doggo#排查")
                    LinkButton(title: "反馈建议", url: "https://github.com/coolboylcy/voice-doggo/issues")
                    Spacer()
                }
                .padding(.vertical, 10)
            }

            HStack(spacing: 10) {
                Button("重置授权…") { confirmReset() }.buttonStyle(.bordered)
                Button("卸载语音狗子…") { confirmUninstall() }.buttonStyle(.bordered)
                Spacer()
                Text("MIT License")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DoggoUI.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = "重置语音狗子的系统授权？"
        alert.informativeText = "App 会重新启动，你需要再次允许麦克风、输入监控和辅助功能。"
        alert.addButton(withTitle: "重置并重开")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { model.resetAuthorizations() }
    }

    private func confirmUninstall() {
        let alert = NSAlert()
        alert.messageText = "卸载语音狗子？"
        alert.informativeText = "将关闭登录启动、清除授权与本机数据，并把 App 移到废纸篓。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "卸载")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { model.uninstall() }
    }
}

// MARK: - Components

private struct PaneTitle: View {
    let title: String
    let subtitle: String
    init(_ title: String, subtitle: String) { self.title = title; self.subtitle = subtitle }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 22, weight: .semibold)).foregroundStyle(DoggoUI.title)
            Text(subtitle).font(.system(size: 12.5)).foregroundStyle(DoggoUI.secondary)
        }
        .padding(.bottom, 2)
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(DoggoUI.tertiary)
            VStack(spacing: 0) { content }
                .padding(.horizontal, 16)
                .background(DoggoUI.card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(DoggoUI.line, lineWidth: 1))
        }
    }
}

private struct SettingLine<Trailing: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let trailing: Trailing
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(DoggoUI.text)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(DoggoUI.secondary)
            }
            Spacer(minLength: 12)
            trailing
        }
        .frame(minHeight: 58)
    }
}

private struct Hairline: View {
    var body: some View { Rectangle().fill(DoggoUI.line).frame(height: 1) }
}

private struct BrandSwitch: View {
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: {
            Capsule()
                .fill(isOn ? DoggoUI.blue : DoggoUI.switchOff)
                .frame(width: 38, height: 22)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 18, height: 18).padding(2).shadow(color: .black.opacity(0.12), radius: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? "开" : "关")
    }
}

private struct ChoiceStrip<Value: Hashable>: View {
    let choices: [(String, Value)]
    @Binding var selection: Value
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                Button(choice.0) { selection = choice.1 }
                    .font(.system(size: 11.5, weight: selection == choice.1 ? .semibold : .regular))
                    .foregroundStyle(selection == choice.1 ? Color.white : DoggoUI.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(selection == choice.1 ? DoggoUI.blue : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(DoggoUI.control, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct ClaudeWorkflowCard: View {
    let hotkey: String
    var body: some View {
        HStack(spacing: 0) {
            WorkflowStep(icon: "terminal", title: "Claude Code", detail: "光标就位")
            FlowArrow()
            WorkflowStep(icon: "option", title: "按住 \(hotkey)", detail: "直接说需求")
            FlowArrow()
            WorkflowStep(icon: "text.cursor", title: "松开完成", detail: "文字原位出现")
        }
        .padding(18)
        .background(DoggoUI.hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(DoggoUI.blue.opacity(0.15), lineWidth: 1))
    }
}

private struct WorkflowStep: View {
    let icon: String; let title: String; let detail: String
    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 17, weight: .medium)).foregroundStyle(DoggoUI.blue)
            Text(title).font(.system(size: 12.5, weight: .semibold))
            Text(detail).font(.system(size: 10.5)).foregroundStyle(DoggoUI.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct FlowArrow: View {
    var body: some View { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(DoggoUI.blue.opacity(0.45)) }
}

private struct InstructionCard: View {
    let icon: String; let title: String; let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(DoggoUI.blue)
            Text(title).font(.system(size: 12.5, weight: .semibold))
            Text(detail).font(.system(size: 10.5)).foregroundStyle(DoggoUI.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(DoggoUI.card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(DoggoUI.line, lineWidth: 1))
    }
}

private struct InlineNote: View {
    let icon: String; let text: String
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon).foregroundStyle(DoggoUI.blue)
            Text(text).font(.system(size: 11.5)).foregroundStyle(DoggoUI.secondary)
        }
        .padding(.top, 2)
    }
}

private struct PermissionSummary: View {
    @ObservedObject var model: AppModel

    /// 用 model 上的 @Published 值判断，不要直接去问 PermissionCenter。
    ///
    /// 那边的实时查询每次访问都问一遍系统，但它不是 observable 的——SwiftUI
    /// 不会因为系统权限变了就重绘这个视图。曾经写成读它，于是「完成授权」按钮
    /// 的显隐跟实际权限状态脱钩：三项全缺时按钮压根不出现，恰恰是最需要它的
    /// 时候。有测试钉住这条。
    private var allGranted: Bool {
        model.microphoneGranted && model.inputMonitoringGranted && model.accessibilityGranted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("系统权限").font(.system(size: 13.5, weight: .medium))
                Spacer()
                PermissionBadge(title: "麦克风", granted: model.microphoneGranted)
                PermissionBadge(title: "输入监控", granted: model.inputMonitoringGranted)
                PermissionBadge(title: "辅助功能", granted: model.accessibilityGranted)
                if !allGranted { actionButton }
            }
            .frame(minHeight: 58)

            // 引导跑起来之后必须有话说。macOS 只允许把人送进系统设置自己拨开关，
            // 这中间 App 界面是背景板——没有这行字，用户不知道该去哪、拨完要不要
            // 回来点什么，尤其输入监控那一步是停下来等重启的，不说就像卡死了。
            if let status = guidanceText {
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(model.awaitingRestart ? DoggoUI.warning : DoggoUI.secondary)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if model.awaitingRestart {
            Button("重新打开") { model.relaunch() }
                .buttonStyle(.borderedProminent).controlSize(.small)
        } else if model.guidedSetupStep == nil {
            Button("完成授权") { model.startGuidedSetup() }
                .buttonStyle(.borderedProminent).controlSize(.small)
        } else {
            Button("停止") { model.cancelGuidedSetup() }
                .buttonStyle(.bordered).controlSize(.small)
        }
    }

    private var guidanceText: String? {
        if model.awaitingRestart {
            return "在系统设置里打开「输入监控」，然后点「重新打开」——这一项要重开语音狗子才认，不是没开成功。"
        }
        guard let step = model.guidedSetupStep else { return nil }
        return step.needsManualToggle
            ? "已替你打开系统设置，拨一下「\(step.title)」的开关就会自动继续。"
            : "正在请求「\(step.title)」，在弹出的对话框里点「好」。"
    }
}

private struct PermissionBadge: View {
    let title: String; let granted: Bool
    var body: some View {
        Label(title, systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(granted ? DoggoUI.success : DoggoUI.warning)
    }
}

private struct PermissionDetailLine: View {
    let title: String; let granted: Bool; let action: () -> Void
    var body: some View {
        HStack {
            Text(title).font(.system(size: 13.5, weight: .medium))
            Spacer()
            if granted {
                Label("已开启", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(DoggoUI.success)
            } else {
                Button("去授权", action: action).buttonStyle(.bordered).controlSize(.small)
            }
        }
        .frame(minHeight: 49)
    }
}

private struct EngineRow: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(DoggoUI.blue.opacity(0.1)).frame(width: 34, height: 34)
                Image(systemName: "bolt.horizontal.circle.fill").foregroundStyle(DoggoUI.blue)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("SenseVoice 离线模型").font(.system(size: 13.5, weight: .medium))
                Text("随 App 安装，不需要下载或配置 API").font(.system(size: 11.5)).foregroundStyle(DoggoUI.secondary)
            }
            Spacer()
            Text(model.engineReady ? "已就绪" : "预热中…")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(model.engineReady ? DoggoUI.success : DoggoUI.warning)
        }
        .frame(minHeight: 62)
    }
}

private struct IconStyleButton: View {
    let style: AppPreferences.MenuIconStyle; let selected: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).frame(height: 22)
                Text(style.title).font(.system(size: 10.5, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? DoggoUI.blue : DoggoUI.secondary)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(selected ? DoggoUI.selection : DoggoUI.control, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(selected ? DoggoUI.blue.opacity(0.35) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
    private var symbol: String {
        switch style { case .dogAndMic: return "microphone.fill"; case .dog: return "pawprint.fill"; case .waveform: return "waveform" }
    }
}

private struct LinkButton: View {
    let title: String; let url: String
    var body: some View {
        Button(title) { if let url = URL(string: url) { NSWorkspace.shared.open(url) } }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(DoggoUI.blue).buttonStyle(.plain)
    }
}

enum DoggoUI {
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static let blue = Color(red: 22 / 255, green: 119 / 255, blue: 1)
    static let window = dynamic(light: NSColor(red: 246/255, green: 248/255, blue: 252/255, alpha: 1), dark: NSColor(red: 27/255, green: 29/255, blue: 34/255, alpha: 1))
    static let sidebar = dynamic(light: NSColor(red: 241/255, green: 245/255, blue: 251/255, alpha: 0.9), dark: NSColor(red: 23/255, green: 25/255, blue: 30/255, alpha: 1))
    static let card = dynamic(light: .white, dark: NSColor(red: 40/255, green: 43/255, blue: 49/255, alpha: 1))
    static let title = dynamic(light: NSColor(red: 26/255, green: 31/255, blue: 39/255, alpha: 1), dark: .white)
    static let text = dynamic(light: NSColor(red: 48/255, green: 55/255, blue: 65/255, alpha: 1), dark: NSColor(red: 225/255, green: 228/255, blue: 234/255, alpha: 1))
    static let secondary = dynamic(light: NSColor(red: 114/255, green: 124/255, blue: 138/255, alpha: 1), dark: NSColor(red: 158/255, green: 166/255, blue: 177/255, alpha: 1))
    static let tertiary = dynamic(light: NSColor(red: 146/255, green: 155/255, blue: 167/255, alpha: 1), dark: NSColor(red: 127/255, green: 135/255, blue: 147/255, alpha: 1))
    static let line = dynamic(light: NSColor(red: 226/255, green: 232/255, blue: 240/255, alpha: 1), dark: NSColor(white: 1, alpha: 0.09))
    static let selection = dynamic(light: NSColor(red: 224/255, green: 237/255, blue: 1, alpha: 1), dark: NSColor(red: 22/255, green: 119/255, blue: 1, alpha: 0.18))
    static let control = dynamic(light: NSColor(red: 241/255, green: 244/255, blue: 248/255, alpha: 1), dark: NSColor(white: 1, alpha: 0.06))
    static let switchOff = dynamic(light: NSColor(red: 190/255, green: 197/255, blue: 207/255, alpha: 1), dark: NSColor(red: 92/255, green: 98/255, blue: 108/255, alpha: 1))
    static let hero = LinearGradient(colors: [blue.opacity(0.10), Color.cyan.opacity(0.045), card], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let success = Color(red: 52/255, green: 176/255, blue: 91/255)
    static let warning = Color(red: 231/255, green: 143/255, blue: 55/255)
}
