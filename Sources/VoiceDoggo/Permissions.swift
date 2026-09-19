import AppKit
import AVFoundation
import ApplicationServices

enum PermissionCenter {
    enum MicrophoneRequestAction: Equatable {
        case requestAccess
        case openSettings
        case none
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

    private static func openPrivacyPane(anchor: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        NSWorkspace.shared.open(url)
    }
}
