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

        if ProcessInfo.processInfo.arguments.contains("--demo-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.statusItem?.presentMenuForDemo()
            }
        }

        if ProcessInfo.processInfo.arguments.contains("--demo-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { model.presentSettings() }
        }

        renderSettingsIfRequested(model: model)
        renderHUDIfRequested(model: model)
        renderMenuIfRequested(model: model)
    }

    /// `--render-settings <png 路径> [--appearance light|dark] [--section general|shortcut|about]`
    ///
    /// 把设置页离屏渲染成图片再退出。屏幕锁着、没有 Xcode 自动化权限、
    /// 在 CI 里跑——这三种情况下 screencapture 都拿不到东西，但 ImageRenderer
    /// 不需要屏幕。改完布局先渲一张看，比反复开窗截图快得多。
    ///
    /// 已知限制：AppKit 控件（Toggle 的开关、Picker）在离屏渲染里会画成
    /// 一块黄底禁止符。那是渲染器的占位，不是界面坏了，真机上是正常控件。
    private func renderSettingsIfRequested(model: AppModel) {
        let args = ProcessInfo.processInfo.arguments
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), args.index(after: i) < args.endIndex else {
                return nil
            }
            return args[args.index(after: i)]
        }

        guard let path = value(after: "--render-settings") else { return }
        let section = value(after: "--section")

        let dark = value(after: "--appearance") == "dark"
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        // 等一拍让 AppModel.refresh 把权限状态填上，否则渲出来全是「未授权」
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            defer { NSApp.terminate(nil) }
            var png: Data?
            // 两处都得设：NSApp.appearance 管 AppKit 侧，environment 的
            // colorScheme 管 SwiftUI 侧。只设前者，ImageRenderer 会把
            // Palette 的动态色统统按浅色解析，深浅渲出同一张图。
            NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
                let content = SettingsView(initialSection: section)
                    .environmentObject(model)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                if let image = renderer.nsImage,
                   let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff) {
                    png = rep.representation(using: .png, properties: [:])
                }
            }
            guard let png else {
                FileHandle.standardError.write(Data("渲染失败\n".utf8))
                return
            }
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    /// `--render-hud <png>`：离屏导出听写浮层，用于视觉验收。
    private func renderHUDIfRequested(model: AppModel) {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--render-hud"), args.index(after: index) < args.endIndex else { return }
        let path = args[args.index(after: index)]
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            model.presentDemoHUD()
            let renderer = ImageRenderer(content: HUDView(model: model).frame(width: 560, height: 218))
            renderer.scale = 2
            Self.write(renderer: renderer, to: path)
            NSApp.terminate(nil)
        }
    }

    /// `--render-menu <png>`：离屏导出菜单栏面板，用于视觉验收。
    private func renderMenuIfRequested(model: AppModel) {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--render-menu"), args.index(after: index) < args.endIndex else { return }
        let path = args[args.index(after: index)]
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let view = MenuPopover(
                model: model,
                onStart: {}, onFinish: {}, onCancel: {}, onMain: {}, onSettings: {}, onQuit: {}, onOpen: { _ in }
            )
            let renderer = ImageRenderer(content: view.background(Color(nsColor: .windowBackgroundColor)))
            renderer.scale = 2
            Self.write(renderer: renderer, to: path)
            NSApp.terminate(nil)
        }
    }

    private static func write<Content: View>(renderer: ImageRenderer<Content>, to path: String) {
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

/// 设置窗口的尺寸。
///
/// 窗口由 AppModel.presentSettings 创建、内容由 SettingsView 布局，两边必须用
/// 同一个数——分别硬编码过一次，改了内容高度却漏改窗口，内容直接被截掉。
enum SettingsLayout {
    static var width: CGFloat { BuildConfiguration.isLocalDistribution ? 860 : 560 }
    static var height: CGFloat { BuildConfiguration.isLocalDistribution ? 640 : 700 }
    /// 标题栏透明后，内容要自己让出交通灯占的高度。
    static let titlebarInset: CGFloat = 30
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    /// 仅供 --render-settings 指定要渲染哪一页；正常打开总是停在「通用」。
    var initialSection: String?

    var body: some View {
        Group {
            if model.isLocalDistribution {
                ProductionSettingsWindow(initialSection: initialSection)
                    .environmentObject(model)
            } else {
                LegacySettingsWindow()
                    .environmentObject(model)
            }
        }
        .frame(width: SettingsLayout.width, height: SettingsLayout.height)
        .task { await model.refresh() }
    }
}

// MARK: - 本地版设置窗口

/// 左边一列导航，右边一列卡片——照设计稿实现。
///
/// 设计稿上有「语言」「识别设置」「外观」三个导航项和一批开关（识别语言下拉、
/// 自动检测语言、菜单栏图标四选一、启动提示、系统通知）。这些这里一个都没有：
/// 这版只有一个离线模型、菜单栏只有一个图标、粘贴到光标是唯一的上屏方式。
/// 摆上去就是摆一排点了没反应的控件，比少几个入口糟得多。
private struct LocalSettingsWindow: View {
    @EnvironmentObject private var model: AppModel
    @State private var section: SettingsSection

    init(initial: SettingsSection = .general) {
        _section = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(Palette.hairline)
                .frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                sidebar
                // 不套 ScrollView：最长的一页也就 280pt，窗口给得下 460pt。
                // 而且 ImageRenderer 渲不出 ScrollView 里的内容，
                // --render-settings 那条离屏校对的路子会整块变空白。
                VStack(alignment: .leading, spacing: 20) {
                    switch section {
                    case .general: GeneralPane().environmentObject(model)
                    case .shortcut: ShortcutPane()
                    case .about: AboutPane().environmentObject(model)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Palette.window)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            AppIconView(size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text("语音狗子")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Palette.title)
                Text("有嘴就能编程")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.hint)
            }
            Spacer(minLength: 12)
            Text("v\(appVersion)")
                .font(.system(size: 12))
                .foregroundStyle(Palette.hint)
        }
        .padding(.horizontal, 24)
        .padding(.top, SettingsLayout.titlebarInset)
        .padding(.bottom, 16)
    }

    private var sidebar: some View {
        VStack(spacing: 4) {
            ForEach(SettingsSection.allCases) { item in
                SidebarRow(item: item, selected: section == item) { section = item }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 20)
        .frame(width: 186)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, shortcut, about

    var id: String { rawValue }

    init(named name: String?) {
        self = name.flatMap(SettingsSection.init(rawValue:)) ?? .general
    }

    var title: String {
        switch self {
        case .general: return "通用"
        case .shortcut: return "快捷键"
        case .about: return "关于"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .shortcut: return "keyboard"
        case .about: return "info.circle"
        }
    }
}

private struct SidebarRow: View {
    let item: SettingsSection
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 15))
                    .frame(width: 20)
                Text(item.title)
                    .font(.system(size: 14, weight: selected ? .medium : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Palette.accent : Palette.text)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(background)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var background: Color {
        if selected { return Palette.navSelected }
        return hovering ? Palette.navHover : .clear
    }
}

// MARK: - 各页内容

private struct GeneralPane: View {
    @EnvironmentObject private var model: AppModel

    private var pending: [PermissionCenter.Step] {
        PermissionCenter.Step.allCases.filter { !granted($0) }
    }

    private func granted(_ step: PermissionCenter.Step) -> Bool {
        switch step {
        case .microphone: return model.microphoneGranted
        case .inputMonitoring: return model.inputMonitoringGranted
        case .accessibility: return model.accessibilityGranted
        }
    }

    var body: some View {
        SettingsCard("授权") {
            if !pending.isEmpty {
                SetupBanner(pending: pending)
                    .environmentObject(model)
            }
            ForEach(PermissionCenter.Step.allCases) { step in
                PermissionRow(
                    step: step,
                    granted: granted(step),
                    active: model.guidedSetupStep == step
                )
                .environmentObject(model)
            }
        }

        SettingsCard("启动") {
            SettingsRow(label: "登录时自动启动") {
                Toggle("", isOn: Binding(
                    get: { model.launchAtLogin.isEnabled },
                    set: { model.launchAtLogin.setEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Palette.accent)
            }
            if !model.launchAtLogin.errorMessage.isEmpty {
                Text(model.launchAtLogin.errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.warn)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct ShortcutPane: View {
    var body: some View {
        SettingsCard("听写") {
            SettingsRow(label: "按住说话", hint: "松手就把识别结果送到光标处") {
                KeyCap("右 Option")
            }
            SettingsRow(label: "持续录音", hint: "短按开始，再按一下结束") {
                KeyCap("右 Option")
            }
            SettingsRow(label: "取消本次", hint: "录音中按下，不上屏") {
                KeyCap("esc")
            }
        }

        // 设计稿在这一行右侧放了「修改」按钮。这版改不了键：热键是在
        // CGEvent tap 里认右 Option 的设备位判出来的，不走 Carbon 热键注册，
        // 换一个键不是改个常量的事。与其给一个点了弹「暂不支持」的按钮，
        // 不如直接说明。
        Text("这版快捷键是固定的，暂不支持自定义。")
            .font(.system(size: 12))
            .foregroundStyle(Palette.hint)
    }
}

private struct AboutPane: View {
    @EnvironmentObject private var model: AppModel

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var body: some View {
        SettingsCard("关于") {
            SettingsRow(label: "版本") {
                Text("v\(appVersion)")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.hint)
            }
            SettingsRow(label: "识别方式", hint: "本机离线 · 不联网 · 不登记 · 不收费") {
                EmptyView()
            }
            SettingsRow(label: "开源许可") {
                Text("MIT")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.hint)
            }
            SettingsRow(label: "源码与文档") {
                Link("GitHub", destination: URL(string: "https://github.com/coolboylcy/voice-doggo")!)
                    .font(.system(size: 13))
                    .tint(Palette.accent)
            }
        }

        SettingsCard("疑难处理") {
            SettingsRow(label: "重置授权", hint: "开关开着却提示没授权时用") {
                Button("重置并重开") { confirmReset() }
                    .buttonStyle(OutlineButtonStyle())
            }
            SettingsRow(label: "卸载", hint: "连同授权和数据一起清掉") {
                Button("卸载…") { confirmUninstall() }
                    .buttonStyle(OutlineButtonStyle())
            }
        }
    }

    /// 重置授权会让用户重新走一遍授权流程，不该点一下就发生。
    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = "重置语音狗子的授权？"
        alert.informativeText = """
        会清掉系统里记的麦克风、输入监控、辅助功能三项授权，然后重开语音狗子，\
        你需要重新授权一次。

        用在这种情况：系统设置里开关明明是开的，语音狗子却说没授权。多半是\
        换过版本后签名对不上，系统里那条旧记录成了摆设。
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "重置并重开")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            model.resetAuthorizations()
        }
    }

    private func confirmUninstall() {
        let alert = NSAlert()
        alert.messageText = "卸载语音狗子？"
        alert.informativeText = """
        会做这几件事：关掉登录启动、清掉三项系统授权、删除本机数据，\
        然后把语音狗子移到废纸篓。

        没有清空废纸篓，反悔了还能捞回来。
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "卸载")
        alert.addButton(withTitle: "取消")
        // 破坏性操作不该是默认回车项
        alert.buttons.first?.keyEquivalent = ""
        alert.buttons.last?.keyEquivalent = "\r"
        if alert.runModal() == .alertFirstButtonReturn {
            model.uninstall()
        }
    }
}

// MARK: - 组件

/// 分组标题 + 白色卡片。设计稿里标题在卡片外面，不是卡片的一部分。
private struct SettingsCard<Content: View>: View {
    private let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.title)
            VStack(spacing: 0) { content }
                .padding(.horizontal, 20)
                // 行高 44 已经自带呼吸感，但卡片上下再各留 8 才和设计稿的
                // 单行卡片（约 60pt 高）对得上，否则卡片会贴着文字。
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Palette.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Palette.cardLine, lineWidth: 1)
                )
        }
    }
}

/// 卡片里的一行：左边标签，标签后面跟灰色说明，右边控件。
private struct SettingsRow<Trailing: View>: View {
    private let label: String
    private let hint: String?
    private let trailing: Trailing

    init(label: String, hint: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.label = label
        self.hint = hint
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(Palette.text)
            if let hint {
                Text(hint)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.hint)
            }
            Spacer(minLength: 12)
            trailing
        }
        .frame(height: 44)
    }
}

/// 键帽。设计稿里是浅灰底 + 一圈描边的圆角块，跟按钮区分开——它不可点。
private struct KeyCap: View {
    private let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.text)
            // 给最小宽度，否则「esc」那一行的键帽明显比「右 Option」窄，
            // 三行右对齐排下来会参差
            .frame(minWidth: 96, minHeight: 30)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.keyCap)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Palette.keyCapLine, lineWidth: 1)
            )
    }
}

/// 引导条：卡片顶部那块「还差几项 + 一键授权」。
///
/// macOS 不提供一次授全的接口，辅助功能和输入监控只能把人送进系统设置自己拨
/// 开关。所以「一键」的真实含义是：点一次，之后 App 盯着状态，你在设置里拨完
/// 一个它自动跳下一个，不用回来反复点。
private struct SetupBanner: View {
    @EnvironmentObject private var model: AppModel
    let pending: [PermissionCenter.Step]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.warn)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.text)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.hint)
                }
                Spacer(minLength: 12)
                trailingButton
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var trailingButton: some View {
        if model.awaitingRestart {
            Button("重新打开") { model.relaunch() }
                .buttonStyle(PrimaryButtonStyle())
        } else if model.guidedSetupStep == nil {
            Button("一键授权") { model.startGuidedSetup() }
                .buttonStyle(PrimaryButtonStyle())
        } else {
            Button("停止") { model.cancelGuidedSetup() }
                .buttonStyle(OutlineButtonStyle())
        }
    }

    private var headline: String {
        if model.awaitingRestart {
            return "在系统设置里打开「输入监控」，然后重开一次"
        }
        if let step = model.guidedSetupStep {
            return step.needsManualToggle
                ? "正在等你打开「\(step.title)」"
                : "正在请求「\(step.title)」"
        }
        return "还差 \(pending.count) 项授权才能用"
    }

    private var detail: String {
        if model.awaitingRestart {
            return "这一项要重开语音狗子才认，不是没开成功"
        }
        if let step = model.guidedSetupStep {
            return step.needsManualToggle
                ? "已经替你打开系统设置，拨一下开关就会自动继续"
                : "在弹出的对话框里点「好」"
        }
        return pending.map { "\($0.title)（\($0.reason)）" }.joined(separator: " · ")
    }
}

struct PermissionRow: View {
    @EnvironmentObject private var model: AppModel
    let step: PermissionCenter.Step
    let granted: Bool
    var active = false

    var body: some View {
        SettingsRow(label: step.title, hint: step.reason) {
            if granted {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                    Text("已开启")
                        .font(.system(size: 13))
                }
                .foregroundStyle(Palette.ok)
            } else if active {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("等待中")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.hint)
                }
            } else {
                Button("去授权") { model.requestPermission(step) }
                    .buttonStyle(OutlineButtonStyle())
            }
        }
    }
}

/// 设计稿里的主按钮：蓝底白字，8pt 圆角。
private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .frame(height: 30)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.accent.opacity(configuration.isPressed ? 0.75 : 1))
            )
    }
}

/// 设计稿里的次级按钮：白底、浅描边、8pt 圆角。
private struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(Palette.accent)
            .frame(height: 30)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? Palette.navSelected : Palette.buttonFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Palette.cardLine, lineWidth: 1)
            )
    }
}

/// 设置页顶部的图标。用同一套图稿而不是另找一个 SF Symbol——那样用户在
/// Dock、访达和设置页里会看到三个不一样的东西。
///
/// 但取的是 AppMark 而不是 AppIcon：AppIcon 按 Big Sur 规范在 1024 画布里
/// 只占 824，四周 100px 是留给系统在 Dock 里对齐用的透明边。放进 App 自己
/// 控制尺寸的容器时那圈边不会被消化掉，就成了肉眼可见的一圈留白。
/// AppMark 是同一张图稿去掉规范留白的版本。
private struct AppIconView: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let icon = NSImage(named: "AppMark") ?? NSImage(named: "AppIcon") {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "waveform.circle.fill")
                    .resizable()
                    .foregroundStyle(Palette.accent)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 配色

/// 浅色值直接取自设计稿；深色是对应映射，不是另一套设计。
///
/// 设置窗口跟随系统主题，不像 HUD 那样锁死浅色——HUD 是悬浮在别人界面上的
/// 品牌层，设置窗口是一个普通 App 窗口，深色模式下强行发白会很刺眼。
private enum Palette {
    private static func dynamic(
        light: (Int, Int, Int, Double),
        dark: (Int, Int, Int, Double)
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                red: CGFloat(c.0) / 255,
                green: CGFloat(c.1) / 255,
                blue: CGFloat(c.2) / 255,
                alpha: CGFloat(c.3)
            )
        })
    }

    static let window = dynamic(light: (244, 246, 250, 1), dark: (30, 32, 36, 1))
    static let card = dynamic(light: (251, 252, 253, 1), dark: (42, 45, 51, 1))
    static let cardLine = dynamic(light: (232, 236, 241, 1), dark: (255, 255, 255, 0.10))
    static let hairline = dynamic(light: (232, 235, 240, 1), dark: (255, 255, 255, 0.08))
    static let accent = dynamic(light: (22, 119, 255, 1), dark: (82, 154, 255, 1))
    static let navSelected = dynamic(light: (217, 233, 252, 1), dark: (82, 154, 255, 0.20))
    static let navHover = dynamic(light: (0, 0, 0, 0.04), dark: (255, 255, 255, 0.06))
    static let title = dynamic(light: (31, 35, 41, 1), dark: (236, 237, 238, 1))
    static let text = dynamic(light: (51, 57, 64, 1), dark: (219, 222, 226, 1))
    static let hint = dynamic(light: (138, 146, 156, 1), dark: (145, 152, 161, 1))
    static let keyCap = dynamic(light: (238, 241, 245, 1), dark: (255, 255, 255, 0.08))
    static let keyCapLine = dynamic(light: (220, 225, 231, 1), dark: (255, 255, 255, 0.12))
    static let buttonFill = dynamic(light: (255, 255, 255, 1), dark: (255, 255, 255, 0.06))
    static let ok = dynamic(light: (52, 168, 83, 1), dark: (108, 201, 131, 1))
    static let warn = dynamic(light: (214, 106, 38, 1), dark: (232, 148, 92, 1))
}

// MARK: - 订阅版（遗留）

/// 云端识别 + 订阅那条分支的设置页。本地版发布用不到，保留是因为订阅相关的
/// 视图还在，删掉要连带拆 AppModel 里的订阅状态。
private struct LegacySettingsWindow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                AppIconView(size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text("语音狗子")
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text("macOS 全局语音输入")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.bottom, 22)

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
                    PermissionRow(step: .microphone, granted: model.microphoneGranted)
                        .environmentObject(model)
                    PermissionRow(step: .accessibility, granted: model.accessibilityGranted)
                        .environmentObject(model)
                    PermissionRow(step: .inputMonitoring, granted: model.inputMonitoringGranted)
                        .environmentObject(model)
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
                Toggle("登录时自动启动语音狗子", isOn: Binding(
                    get: { model.launchAtLogin.isEnabled },
                    set: { model.launchAtLogin.setEnabled($0) }
                ))
                .padding(4)
            }
            .padding(.top, 14)

            Spacer()
        }
        .padding(28)
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
