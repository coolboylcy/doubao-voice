import ApplicationServices
import Foundation

final class GlobalHotkeyMonitor {
    enum Event { case down, up, escape }
    var onEvent: ((Event) -> Void)?
    var onUnavailable: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var rightOptionDown = false
    private let rightOptionKeyCode = 61
    /// `NX_DEVICERALTKEYMASK`（IOLLEvent.h）——CGEvent flags 里标记「右 Option
    /// 正被按住」的 device-dependent 位，左 Option 是 0x20。
    private static let rightOptionDeviceMask: UInt64 = 0x40

    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
        let unmanaged = Unmanaged.passUnretained(self)
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<GlobalHotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handle(event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: unmanaged.toOpaque()
        )
        guard let tap else {
            Diagnostics.hotkey("event tap 创建失败——多半缺辅助功能或输入监控权限")
            onUnavailable?()
            return
        }
        Diagnostics.hotkey("event tap 已启用，监听右 Option")
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(_ event: CGEvent) {
        // 回调超时或被用户输入打断时系统会禁用 tap，不重新 enable 热键就永久
        // 失效，且没有任何提示。这两个事件不受 eventsOfInterest 掩码约束。
        if event.type == .tapDisabledByTimeout || event.type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if event.type == .keyDown, keyCode == 53 {
            onEvent?(.escape)
            return
        }

        // flagsChanged 的 keyCode 用来区分左右 Option；按下/松开读事件自带的
        // device-dependent 修饰键位，它随事件同步到达，也天然区分左右，不会
        // 像 `.maskAlternate` 那样在左 Option 按住时始终为 true。
        //
        // 别换回 `CGEventSource.keyState`：headInsert 的 tap 在事件进入系统
        // *之前* 就被调用，那时全局键盘状态还没更新——按下时读到 false、松开
        // 时读到 true，两个分支都判不出来，热键会完全静默。
        guard event.type == .flagsChanged else { return }
        // 诊断打在 keyCode 过滤之前：外接/蓝牙键盘的右 Option 未必发 61，
        // 过滤之后再记录就永远看不到「事件其实来了、只是没匹配上」。
        Diagnostics.hotkey(String(
            format: "flagsChanged keyCode=%ld flags=0x%llx",
            keyCode,
            event.flags.rawValue
        ))
        guard keyCode == rightOptionKeyCode else { return }
        let right = (event.flags.rawValue & Self.rightOptionDeviceMask) != 0
        if right && !rightOptionDown {
            rightOptionDown = true
            Diagnostics.hotkey("右 Option 按下")
            onEvent?(.down)
        } else if !right && rightOptionDown {
            rightOptionDown = false
            Diagnostics.hotkey("右 Option 松开")
            onEvent?(.up)
        }
    }
}
