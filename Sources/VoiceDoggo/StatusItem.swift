import AppKit
import Combine
import SwiftUI

/// 菜单栏图标与下拉菜单。
///
/// 这里用 AppKit 的 NSStatusItem 而不是 SwiftUI 的 MenuBarExtra。后者在
/// macOS 26 + LSUIElement 的组合下**根本不创建菜单栏项**：App 正常跑着、
/// AppModel 也初始化了（全局热键都注册成功），但 CGWindowList 里 layer 25
/// 一个本 App 的窗口都没有——对照组 UniFi Endpoint 就在那一层。
/// 于是用户完全看不到这个 App 的存在，也没法点开设置。
///
/// NSStatusItem 没有这个问题，而且能精确控制图标与状态着色。
@MainActor
final class StatusItemController {
    private let model: AppModel
    private var statusItem: NSStatusItem?
    private var cancellable: AnyCancellable?

    private var popover: NSPopover?

    init(model: AppModel) {
        self.model = model
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.toolTip = "语音狗子 · 按住\(model.hotkeyTitle)说话"
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item
        refresh()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak item] in
            guard let item else { return }
            Self.reportPlacement(of: item)
        }

        cancellable = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    deinit {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    /// 调试用：直接把面板弹出来，免得为了截一张图去跟刘海和鼠标权限较劲。
    func presentMenuForDemo() { togglePopover() }

    @objc private func togglePopover() {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem?.button else { return }
        let content = MenuPopover(
            model: model,
            onStart: { [weak self] in self?.dismissThen { $0.model.startFromMenu() } },
            onFinish: { [weak self] in self?.dismissThen { $0.model.stopFromMenu() } },
            onCancel: { [weak self] in self?.dismissThen { $0.model.cancelRecording() } },
            onMain: { [weak self] in self?.dismissThen { $0.model.presentSettings() } },
            onSettings: { [weak self] in self?.dismissThen { $0.model.presentSettings() } },
            onQuit: { NSApplication.shared.terminate(nil) },
            onOpen: { [weak self] url in
                self?.dismissThen { _ in NSWorkspace.shared.open(url) }
            }
        )
        let pop = NSPopover()
        pop.contentViewController = NSHostingController(rootView: content)
        // transient：点面板外任意处自动收起，行为跟系统菜单一致。
        // demo 模式例外——.transient 会在失焦瞬间关掉，根本来不及截图。
        pop.behavior = ProcessInfo.processInfo.arguments.contains("--demo-menu")
            ? .applicationDefined
            : .transient
        pop.animates = false
        popover = pop
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // 让面板能接收键盘，Tab/回车才能走通
        pop.contentViewController?.view.window?.makeKey()
    }

    /// 先收面板再执行动作。
    /// 反过来的话，presentSettings 弹出的窗口会被随后收起的 popover 抢回焦点。
    private func dismissThen(_ action: @escaping (StatusItemController) -> Void) {
        popover?.performClose(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            action(self)
        }
    }

    private func refresh() {
        guard let button = statusItem?.button else { return }

        let state: DoggoMenuIconState
        switch model.recordingState {
        case .recording: state = .listening
        case .processing: state = .thinking
        case .error, .paywall: state = .error
        case .idle: state = .idle
        }

        let image = Self.statusImage(style: model.preferences.menuIconStyle, state: state)
        image.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
        button.contentTintColor = nil
        button.toolTip = "语音狗子 · \(model.statusText)"
    }

    /// 记录图标最终落在菜单栏的哪个位置，并在被刘海挡住时明确告警。
    ///
    /// 刘海屏上这是个真实且极难自查的故障：菜单栏图标一多，系统会把靠左的项
    /// 排到刘海下面——status item 照样创建、isVisible 为 true、图像尺寸也正常，
    /// 就是一个像素都看不见。本机实测 1470 点宽的屏幕上刘海占 646..825，而图标
    /// 恰好被放在 x=798。没有这条日志，只能一路怀疑代码。
    private static func reportPlacement(of item: NSStatusItem) {
        guard let frame = item.button?.window?.frame else {
            Diagnostics.session("status item 没有窗口，菜单栏图标可能未能创建")
            return
        }
        var message = "status item 位置 x=\(Int(frame.minX)) 宽=\(Int(frame.width))"
        if let screen = NSScreen.main,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           frame.minX < right.minX, frame.maxX > left.maxX {
            message += " ⚠️ 落在刘海区（\(Int(left.maxX))..\(Int(right.minX))）下方，图标不可见"
            message += " — 菜单栏图标过多，需按住 ⌘ 拖动整理"
        }
        Diagnostics.session(message)
    }

    private enum DoggoMenuIconState {
        case idle
        case listening
        case thinking
        case error
    }

    private static func statusImage(
        style: AppPreferences.MenuIconStyle,
        state: DoggoMenuIconState
    ) -> NSImage {
        switch style {
        case .dogAndMic:
            return dogAndMicImage(state: state)
        case .dog:
            return doggoImage(state: state)
        case .waveform:
            let name = state == .listening ? "waveform.badge.mic" : "waveform"
            let image = NSImage(systemSymbolName: name, accessibilityDescription: "语音狗子")
                ?? statusGlyphImage()
            image.size = NSSize(width: 18, height: 18)
            return image
        }
    }

    /// 22pt 模板图标：左边保留傻狗的大耳朵轮廓，右下叠一支麦克风。
    /// 只画实心几何形，交给 macOS 自动反转深浅色，避免小尺寸渐变糊成一团。
    private static func dogAndMicImage(state: DoggoMenuIconState) -> NSImage {
        let size = NSSize(width: 22, height: 18)
        return NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()

            let lift: CGFloat = state == .listening ? 1.4 : 0
            NSBezierPath(roundedRect: NSRect(x: 2.4, y: 5.0 + lift, width: 3.6, height: 9.2), xRadius: 1.8, yRadius: 1.8).fill()
            NSBezierPath(roundedRect: NSRect(x: 9.6, y: 5.0 + lift, width: 3.6, height: 9.2), xRadius: 1.8, yRadius: 1.8).fill()
            NSBezierPath(ovalIn: NSRect(x: 4.6, y: 6.0, width: 6.5, height: 7.8)).fill()
            NSBezierPath(roundedRect: NSRect(x: 6.1, y: 3.8, width: 3.5, height: 5.6), xRadius: 1.7, yRadius: 1.7).fill()

            // 麦克风胶囊与支架在 18pt 下仍保留至少 1.4pt 的笔画。
            NSBezierPath(roundedRect: NSRect(x: 15.0, y: 7.1, width: 3.8, height: 7.0), xRadius: 1.9, yRadius: 1.9).fill()
            let cradle = NSBezierPath()
            cradle.lineWidth = 1.4
            cradle.lineCapStyle = .round
            cradle.move(to: NSPoint(x: 13.8, y: 10.3))
            cradle.curve(to: NSPoint(x: 20.0, y: 10.3), controlPoint1: NSPoint(x: 13.8, y: 5.8), controlPoint2: NSPoint(x: 20.0, y: 5.8))
            cradle.stroke()
            NSBezierPath(roundedRect: NSRect(x: 16.2, y: 3.2, width: 1.4, height: 3.5), xRadius: 0.7, yRadius: 0.7).fill()
            NSBezierPath(roundedRect: NSRect(x: 14.4, y: 2.7, width: 5.0, height: 1.3), xRadius: 0.65, yRadius: 0.65).fill()

            if state == .thinking {
                for index in 0..<3 {
                    NSBezierPath(ovalIn: NSRect(x: 2.4 + CGFloat(index) * 1.8, y: 15.2, width: 1.1, height: 1.1)).fill()
                }
            } else if state == .error {
                NSBezierPath(roundedRect: NSRect(x: 7.2, y: 8.0, width: 1.3, height: 3.3), xRadius: 0.6, yRadius: 0.6).fill()
                NSBezierPath(ovalIn: NSRect(x: 7.2, y: 5.8, width: 1.3, height: 1.3)).fill()
            }
            return true
        }
    }

    /// 从 Asset Catalog 加载菜单栏 glyph，并把逻辑尺寸稳定在 18pt。
    /// 若资源意外缺失，仍回退到原来的程序绘制图标，避免菜单栏出现空白。
    private static func statusGlyphImage() -> NSImage {
        guard let source = NSImage(named: "StatusGlyph") else {
            return doggoImage(state: .idle)
        }
        let size = NSSize(width: 18, height: 18)
        return NSImage(size: size, flipped: false) { rect in
            source.draw(
                in: rect,
                from: NSRect(origin: .zero, size: source.size),
                operation: .sourceOver,
                fraction: 1
            )
            return true
        }
    }

    /// 菜单栏用的极简腊肠狗模板图像。
    ///
    /// 16–18pt 画不了 3D 细节，只保留大垂耳、小头和向下伸的长口吻。录音时
    /// 耳根向外抬，识别时歪头并带三点，错误时加叹号；即使不看颜色也能区分。
    private static func doggoImage(state: DoggoMenuIconState) -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()

            let tilt: CGFloat = state == .thinking ? -1.0 : 0
            let earLift: CGFloat = state == .listening ? 2.1 : 0
            let head = NSBezierPath(
                roundedRect: NSRect(x: 5.2, y: 4.0 + tilt, width: 7.6, height: 9.2),
                xRadius: 3.6,
                yRadius: 3.6
            )
            head.fill()

            // 在听时耳朵向两侧抬开；其余状态保持两块细长下垂轮廓。
            let leftEar = NSBezierPath(
                roundedRect: NSRect(x: 1.9 - earLift * 0.45, y: 3.0 + earLift, width: 4.2, height: 9.8),
                xRadius: 2.1,
                yRadius: 2.1
            )
            let rightEar = NSBezierPath(
                roundedRect: NSRect(x: 11.9 + earLift * 0.45, y: 3.0 + earLift, width: 4.2, height: 9.8),
                xRadius: 2.1,
                yRadius: 2.1
            )
            leftEar.fill()
            rightEar.fill()

            // 向下伸的一笔是腊肠狗长口吻，也是这一套 16pt 轮廓的识别中心。
            NSBezierPath(
                roundedRect: NSRect(x: 7.3, y: 1.6 + tilt, width: 3.4, height: 6.0),
                xRadius: 1.7,
                yRadius: 1.7
            ).fill()

            if state == .thinking {
                for index in 0..<3 {
                    NSBezierPath(ovalIn: NSRect(x: 13.6 + CGFloat(index) * 1.3, y: 12.6, width: 1.0, height: 1.0)).fill()
                }
            } else if state == .error {
                NSBezierPath(roundedRect: NSRect(x: 8.3, y: 7.1, width: 1.4, height: 3.8), xRadius: 0.7, yRadius: 0.7).fill()
                NSBezierPath(ovalIn: NSRect(x: 8.3, y: 4.9, width: 1.4, height: 1.4)).fill()
            }
            return true
        }
        return image
    }

    /// 状态行左侧的小圆点：绿=就绪、红=录音中、黄=识别中、橙=出错。
    private static func statusDot(for state: AppModel.RecordingState) -> NSImage {
        let color: NSColor
        switch state {
        case .recording: color = .systemRed
        case .processing: color = .systemYellow
        case .error, .paywall: color = .systemOrange
        case .idle: color = .systemGreen
        }
        let d: CGFloat = 8
        return NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }

}
