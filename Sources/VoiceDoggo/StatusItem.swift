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

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        startItem.target = self
        startItem.action = #selector(startDictation)
        menu.addItem(startItem)

        finishItem.target = self
        finishItem.action = #selector(finishDictation)
        menu.addItem(finishItem)

        cancelItem.target = self
        cancelItem.action = #selector(cancelDictation)
        menu.addItem(cancelItem)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "退出语音狗子", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    private func refresh() {
        guard let button = statusItem?.button else { return }

        let symbol: String
        let tint: NSColor?
        switch model.recordingState {
        case .recording:
            symbol = "waveform.circle.fill"
            tint = .systemRed
        case .processing:
            symbol = "ellipsis.circle"
            tint = .secondaryLabelColor
        case .error, .paywall:
            symbol = "exclamationmark.circle.fill"
            tint = .systemOrange
        case .idle:
            symbol = "waveform"
            tint = nil
        }

        // 自己画图标，不用 SF Symbol。
        //
        // NSImage(systemSymbolName:) 配 withSymbolConfiguration 之后，再设
        // .size 不生效——实测菜单栏里拿到的图像尺寸是 1×1：系统按内容给了
        // 32 点宽的位置，却什么都画不出来，看上去就是菜单栏上凭空一块空白，
        // 而且不报任何错。自绘图像尺寸完全可控，也能跟 App 图标的 5 根条
        // 保持一致。
        let image = Self.waveformImage(highlighted: model.isRecording)
        image.isTemplate = (tint == nil)
        button.image = image
        button.imagePosition = .imageOnly
        button.contentTintColor = tint

        statusLine.title = model.statusText
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

    /// 菜单栏用的波形图标，模板图像（单色，由系统按深浅色反色）。
    private static func waveformImage(highlighted: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let bars: [CGFloat] = highlighted
            ? [0.45, 0.85, 1.0, 0.85, 0.45]
            : [0.35, 0.7, 1.0, 0.7, 0.35]
        let image = NSImage(size: size, flipped: false) { rect in
            let slot = rect.width / CGFloat(bars.count)
            let barWidth = slot * 0.5
            NSColor.black.setFill()
            for (index, ratio) in bars.enumerated() {
                let barHeight = rect.height * 0.92 * ratio
                let bar = NSRect(
                    x: slot * CGFloat(index) + (slot - barWidth) / 2,
                    y: (rect.height - barHeight) / 2,
                    width: barWidth,
                    height: barHeight
                )
                NSBezierPath(
                    roundedRect: bar,
                    xRadius: barWidth / 2,
                    yRadius: barWidth / 2
                ).fill()
            }
            return true
        }
        return image
    }

    @objc private func startDictation() { model.startFromMenu() }
    @objc private func finishDictation() { model.stopFromMenu() }
    @objc private func cancelDictation() { model.cancelRecording() }
    @objc private func openSettings() { model.presentSettings() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
