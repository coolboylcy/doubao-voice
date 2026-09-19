import AppKit
import AVFoundation
import ApplicationServices

enum PermissionCenter {
    /// 三项权限，按引导顺序排列。
    ///
    /// 顺序不是随便排的：麦克风能在 App 内直接弹系统对话框，点一下「好」就完事；
    /// 另外两项只能把用户送到「系统设置」里自己拨开关。把最省事的放最前面，
    /// 用户第一步就有正反馈，不至于一上来就被丢进系统设置。
    enum Step: String, CaseIterable, Identifiable {
        case microphone
        case inputMonitoring
        case accessibility

        var id: String { rawValue }

        var title: String {
            switch self {
            case .microphone: return "麦克风"
            case .inputMonitoring: return "输入监控"
            case .accessibility: return "辅助功能"
            }
        }

        /// 一句话说清「为什么要这个」。用户在系统设置里犹豫要不要给的时候，
        /// 看的就是这句。
        var reason: String {
            switch self {
            case .microphone: return "听你说话"
            case .inputMonitoring: return "认出全局听写快捷键"
            case .accessibility: return "把文字送到光标处"
            }
        }

        /// 用户得自己去系统设置里拨开关，还是 App 弹个窗就能拿到。
        var needsManualToggle: Bool {
            self != .microphone
        }

        /// 打开开关后必须重启 App 才生效。
        ///
        /// 输入监控是 macOS 里少数几个这样的权限：CGPreflightListenEventAccess
        /// 在当前进程里会一直返回 false，直到进程重启。系统自己弹的提示也是
        /// 「退出并重新打开后才拥有访问权限」。
        var requiresRestart: Bool {
            self == .inputMonitoring
        }

        /// tccutil 的服务名，跟枚举名不是一回事（输入监控叫 ListenEvent）。
        var tccService: String {
            switch self {
            case .microphone: return "Microphone"
            case .inputMonitoring: return "ListenEvent"
            case .accessibility: return "Accessibility"
            }
        }
    }

    enum MicrophoneRequestAction: Equatable {
        case requestAccess
        case openSettings
        case none
    }

    static func granted(_ step: Step) -> Bool {
        switch step {
        case .microphone: return microphoneGranted
        case .inputMonitoring: return inputMonitoringGranted
        case .accessibility: return accessibilityGranted
        }
    }

    static var allGranted: Bool {
        Step.allCases.allSatisfy(granted)
    }

    /// 用户明确拒绝过。
    ///
    /// 只有麦克风分得清「还没问过」和「问过被拒了」——另外两项 App 拿不到这个
    /// 区别，没授权就是没授权。这个区别有用：系统的麦克风弹窗一辈子只弹一次，
    /// 被拒之后再调 requestAccess 什么都不会发生，必须把人送到设置页。
    static func isExplicitlyDenied(_ step: Step) -> Bool {
        guard step == .microphone else { return false }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .denied || status == .restricted
    }

    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    // 使用 Core Graphics 的系统预检，避免把辅助功能状态误当成输入监控状态。
    static var inputMonitoringGranted: Bool {
        CGPreflightListenEventAccess()
    }

    /// 发起某一项的授权请求：能弹窗的弹窗，弹不了的把用户送到对应设置页。
    static func request(_ step: Step) async {
        switch step {
        case .microphone: await requestMicrophone()
        case .inputMonitoring: openInputMonitoringSettings()
        case .accessibility: openAccessibilitySettings()
        }
    }

    static func requestMicrophone() async {
        switch microphoneRequestAction(for: AVCaptureDevice.authorizationStatus(for: .audio)) {
        case .requestAccess:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .openSettings:
            openPrivacyPane(anchor: "Privacy_Microphone")
        case .none:
            break
        }
    }

    static func microphoneRequestAction(for status: AVAuthorizationStatus) -> MicrophoneRequestAction {
        switch status {
        case .notDetermined:
            return .requestAccess
        case .denied, .restricted:
            return .openSettings
        case .authorized:
            return .none
        @unknown default:
            return .openSettings
        }
    }

    static func openAccessibilitySettings() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openPrivacyPane(anchor: "Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }
        openPrivacyPane(anchor: "Privacy_ListenEvent")
    }

    /// 清掉本 App 的 TCC 记录，让系统忘掉之前授过什么。
    ///
    /// 用在「系统设置里开关明明是开的，App 却拿不到权限」这种场合。macOS 的
    /// TCC 是按代码签名记账的，从本地开发签名的版本换成 Developer ID 签名的
    /// 正式版时，签名要求对不上，旧记录就成了一条既占着位置又不生效的僵尸。
    /// 手工解法是去系统设置里把条目删掉再重新添加，这里替用户做掉。
    ///
    /// 返回没能重置成功的项。tccutil 不需要 sudo，正常都会成功。
    @discardableResult
    static func resetAuthorizations() -> [Step] {
        Step.allCases.filter { step in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            task.arguments = ["reset", step.tccService, bundleIdentifier]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                task.waitUntilExit()
                return task.terminationStatus != 0
            } catch {
                return true
            }
        }
    }

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.voicedoggo.app"
    }

    /// 重开一份自己再退出当前这份。
    ///
    /// 输入监控授权完必须走这一遭，否则 CGPreflightListenEventAccess 一直是
    /// false，用户会觉得「我明明开了啊」。
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private static func openPrivacyPane(anchor: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        NSWorkspace.shared.open(url)
    }
}
