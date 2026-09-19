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

    // 菜单项要在状态变化时开关，所以留着引用
    private let startItem = NSMenuItem(title: "开始听写", action: nil, keyEquivalent: "")
    private let finishItem = NSMenuItem(title: "完成听写", action: nil, keyEquivalent: "")
    private let cancelItem = NSMenuItem(title: "取消本次听写", action: nil, keyEquivalent: "")
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    init(model: AppModel) {
        self.model = model
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.toolTip = "语音狗子 · 按住右 Option 说话"
        item.menu = buildMenu()
        statusItem = item
        refresh()
        // 菜单栏位置要等系统布局完才知道，推迟一拍再查。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak item] in
            guard let item else { return }
            Self.reportPlacement(of: item)
        }

        // AppModel 是 ObservableObject，状态一变就刷新图标和菜单文案
        cancellable = model.objectWillChange.sink { [weak self] _ in
            // objectWillChange 在值更新*前*发出，推迟一拍才能读到新值
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    deinit {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    /// 给菜单项配一个 SF Symbol。
    /// 菜单项只有文字时，一列字读起来是平的；加图标后「开始听写」和「退出」
    /// 这类不同性质的操作一眼能分开。
    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.size = NSSize(width: 15, height: 15)
        image?.isTemplate = true
        return image
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        startItem.target = self
        startItem.action = #selector(startDictation)
        startItem.image = Self.symbol("mic")
        menu.addItem(startItem)

        finishItem.target = self
        finishItem.action = #selector(finishDictation)
        finishItem.image = Self.symbol("checkmark.circle")
        menu.addItem(finishItem)

        cancelItem.target = self
        cancelItem.action = #selector(cancelDictation)
        cancelItem.image = Self.symbol("xmark.circle")
        menu.addItem(cancelItem)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        settings.image = Self.symbol("gearshape")
        menu.addItem(settings)

        let quit = NSMenuItem(title: "退出语音狗子", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        quit.image = Self.symbol("power")
        menu.addItem(quit)

        return menu
    }

    private func refresh() {
        guard let button = statusItem?.button else { return }

        let tint: NSColor?
        switch model.recordingState {
        case .recording:
            tint = .systemRed
        case .processing:
            tint = .secondaryLabelColor
        case .error, .paywall:
            tint = .systemOrange
        case .idle:
            tint = nil
        }

        // 使用和 AppIcon 配套的「傻狗 + 麦克风」透明 glyph。资源本身标记为
        // template，系统会自动适配深浅色菜单栏；录音和错误状态仍由 tint 区分。
        let image = Self.statusGlyphImage()
        image.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = tint

        statusLine.title = model.statusText
        statusLine.image = Self.statusDot(for: model.recordingState)
        let recording = model.isRecording
        startItem.isHidden = recording
        finishItem.isHidden = !recording
        cancelItem.isHidden = !recording
        startItem.isEnabled = !recording
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

    @objc private func startDictation() { model.startFromMenu() }
    @objc private func finishDictation() { model.stopFromMenu() }
    @objc private func cancelDictation() { model.cancelRecording() }
    @objc private func openSettings() { model.presentSettings() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
