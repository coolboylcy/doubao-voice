import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    // 权限和凭证流程发生过升级；使用新 key 让旧版用户也能看到一次完整设置页。
    private static let setupShownKey = "DoubaoVoice.hasShownInitialSetup.v2"

    enum RecordingState {
        case idle
        case recording
        case processing
        case paywall
        case error(String)
    }

    @Published private(set) var recordingState: RecordingState = .idle
    @Published private(set) var remainingSeconds = 120
    @Published private(set) var levels: [Double] = []
    @Published private(set) var partialText = ""
    @Published private(set) var errorText = ""
    @Published private(set) var transientHUDMessage = ""
    @Published private(set) var microphoneGranted = false
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var inputMonitoringGranted = false

    let subscriptions = SubscriptionStore()
    let launchAtLogin = LaunchAtLoginController()
    private let hotkey = GlobalHotkeyMonitor()
    private let daemonProcess = DaemonProcessController()
    private let credentialStore = ASRCredentialStore.shared
    private var subscriptionCancellable: AnyCancellable?
    private lazy var daemon = DaemonClient(socketPath: daemonProcess.socketPath)
    private var hotkeyDownAt: Date?
    private var toggleMode = false
    private var countdownTask: Task<Void, Never>?
    private var meteringTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?
    private var processingTimeoutTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    // 用单调时钟计算录音时长，避免系统时间回拨影响倒计时和额度扣减。
    private var sessionStartedAt: UInt64?
    private var sessionQuotaAtStart: TimeInterval = 0
    private var meteredSeconds: TimeInterval = 0
    // 整段录音的音频峰值，用来区分「真的没说话」和「麦克风增益太低」
    private var sessionPeak = 0
    private var hud: HUDPanelController?
    private var settingsWindow: NSWindow?

    init() {
        // 仅在进程内部读取旧版兼容凭证，绝不将长期密钥绑定到 UI。
        _ = credentialStore.load()
        subscriptionCancellable = subscriptions.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        hotkey.onEvent = { [weak self] event in
            Task { @MainActor in self?.handleHotkey(event) }
        }
        hotkey.onUnavailable = { [weak self] in
            Task { @MainActor in self?.handleHotkeyUnavailable() }
        }
        daemon.onEvent = { [weak self] event in
            Task { @MainActor in self?.handleDaemonEvent(event) }
        }
        daemonProcess.onError = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                self.recordingState = .error(message)
                self.errorText = message
                self.hud?.showError(message)
            }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshPermissionState()
                self.hotkey.stop()
                self.hotkey.start()
            }
        }
        refreshPermissionState()
        hotkey.start()
        // daemon 按常驻设计（见 mic.py：stream 构造时 open 但不 start，所以
        // 常驻也不会点亮麦克风指示灯）。懒到第一次按键才拉起会撞上
        // PyInstaller onefile 十几秒的冷启动：那段时间 start/stop 全堆在
        // DaemonClient.pendingCommands 里，等就绪后才一起发出，整段录音丢光，
        // 外部表现是波形转了一圈然后卡在「识别中」。
        if PermissionCenter.microphoneGranted {
            daemonProcess.start()
        }
        hud = HUDPanelController(model: self)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.presentInitialSetupIfNeeded()
        }
    }

    deinit {
        countdownTask?.cancel()
        meteringTask?.cancel()
        silenceTask?.cancel()
        processingTimeoutTask?.cancel()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        hotkey.stop()
        daemonProcess.stop()
    }

    var isRecording: Bool {
        if case .recording = recordingState { return true }
        return false
    }

    var isLocalDistribution: Bool { BuildConfiguration.isLocalDistribution }
    var isSubscribed: Bool { isLocalDistribution || subscriptions.isSubscribed }
    var canRecord: Bool { isSubscribed && availableRecordingSeconds > 0 && !isRecording }
    var monthlyQuotaHours: Int { subscriptions.monthlyQuotaHours }
    var quotaProgress: Double { isLocalDistribution ? 1 : subscriptions.quotaProgress }
    var quotaText: String { isLocalDistribution ? "本地离线 · 无月度额度" : subscriptions.quotaText }
    var quotaColor: Color { !isLocalDistribution && subscriptions.remainingSeconds <= 600 ? .orange : .secondary }
    var credentialsConfigured: Bool {
        isLocalDistribution || credentialStore.load().isConfigured
    }

    var menuIcon: String {
        switch recordingState {
        case .recording: return "record.circle.fill"
        case .processing: return "ellipsis.circle"
        case .error: return "exclamationmark.circle.fill"
        default: return "waveform.circle"
        }
    }

    var menuColor: Color {
        switch recordingState {
        case .recording: return .red
        case .error: return .orange
        default: return .primary
        }
    }

    var statusText: String {
        switch recordingState {
        case .idle: return isSubscribed ? "已就绪 · 右 Option 开始" : "需要订阅后使用"
        case .recording: return "正在听写 · 剩余 \(formatted(remainingSeconds))"
        case .processing: return "识别中……"
        case .paywall: return "订阅已到期或额度已用完"
        case .error(let message): return message
        }
    }

    var subscriptionTitle: String {
        if isLocalDistribution { return "Doubao Voice 本地版" }
        return isSubscribed ? "Doubao Voice Pro" : "解锁全局语音输入"
    }

    var subscriptionDetail: String {
        if isLocalDistribution { return "离线识别已激活 · 音频不会发送到云端" }
        if isSubscribed { return "订阅有效 · 本周期剩余 \(quotaText)" }
        return "订阅后每月可使用 \(monthlyQuotaHours) 小时语音识别"
    }

    func refresh() async {
        await subscriptions.refresh()
        refreshPermissionState()
        hotkey.stop()
        hotkey.start()
    }

    func purchaseOrRefresh() async {
        if isSubscribed {
            await subscriptions.refresh()
        } else {
            await subscriptions.purchase()
        }
    }

    func restorePurchases() async {
        await subscriptions.restore()
    }

    func startFromMenu() {
        beginRecording()
        guard isRecording else { return }
        toggleMode = true
        armSilenceCancellation()
    }

    func stopFromMenu() { finishRecording() }

    private func handleHotkey(_ event: GlobalHotkeyMonitor.Event) {
        switch event {
        case .down:
            if isRecording && toggleMode {
                finishRecording()
            } else if case .idle = recordingState {
                hotkeyDownAt = Date()
                beginRecording()
            }
        case .up:
            guard isRecording else { return }
            let held = Date().timeIntervalSince(hotkeyDownAt ?? Date())
            if RecordingPolicy.usesToggleMode(heldSeconds: held) {
                toggleMode = true
                armSilenceCancellation()
            } else {
                finishRecording()
            }
            hotkeyDownAt = nil
        case .escape:
            cancelRecording()
        }
    }

    private func handleHotkeyUnavailable() {
        guard !isRecording else { return }
        let message = "右 Option 暂不可用，请在设置中开启输入监控权限"
        errorText = message
        if case .idle = recordingState {
            recordingState = .error(message)
        }
    }

    private func beginRecording() {
        guard RecordingPolicy.hasAccess(
            localDistribution: isLocalDistribution,
            isSubscribed: subscriptions.isSubscribed
        ) else {
            recordingState = .paywall
            hud?.show()
            hud?.showPaywall()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.presentSettings()
            }
            return
        }
        guard availableRecordingSeconds > 0 else {
            recordingState = .paywall
            hud?.show()
            hud?.showQuotaExhausted()
            return
        }
        guard credentialsConfigured else {
            let message = "请先在设置中配置豆包 ASR 凭证"
            recordingState = .error(message)
            errorText = message
            hud?.showError(message)
            return
        }
        guard PermissionCenter.microphoneGranted else {
            let message = "请先允许麦克风权限，然后再开始听写"
            recordingState = .error(message)
            errorText = message
            requestMicrophonePermission()
            hud?.showError(message)
            return
        }
        guard PermissionCenter.accessibilityGranted else {
            let message = "请先允许辅助功能权限，识别文字才能输入到当前 App"
            recordingState = .error(message)
            errorText = message
            hud?.showError(message)
            return
        }

        cancelTasks()
        toggleMode = false
        sessionStartedAt = DispatchTime.now().uptimeNanoseconds
        sessionQuotaAtStart = availableRecordingSeconds
        meteredSeconds = 0
        remainingSeconds = Int(ceil(sessionQuotaAtStart))
        levels = []
        sessionPeak = 0
        partialText = ""
        errorText = ""
        transientHUDMessage = ""
        recordingState = .recording
        hud?.show()
        daemonProcess.start()
        daemon.connectAndStart()
        countdownTask = Task { [weak self] in
            while !Task.isCancelled {
                // 取消后不能再跑一轮循环体：那一轮可能把 remainingSeconds
                // 算到 0 并触发 finishRecording。
                guard await Sleep.completed(for: .milliseconds(100)) else { return }
                guard let self else { return }
                let elapsed = self.elapsedSinceSessionStart()
                let maxRemaining = RecordingPolicy.maximumSessionSeconds - elapsed
                let subscriptionRemaining = self.sessionQuotaAtStart - elapsed
                self.remainingSeconds = max(0, Int(ceil(min(maxRemaining, subscriptionRemaining))))
                if self.remainingSeconds <= 0 {
                    self.finishRecording()
                    return
                }
            }
        }
        meteringTask = Task { [weak self] in
            while !Task.isCancelled {
                guard await Sleep.completed(for: .milliseconds(500)) else { return }
                guard let self, self.isRecording else { return }
                let elapsed = self.elapsedSinceSessionStart()
                let billable = min(self.sessionQuotaAtStart, max(0, elapsed))
                let delta = billable - self.meteredSeconds
                if delta > 0, !self.isLocalDistribution {
                    self.subscriptions.consume(seconds: delta)
                    self.meteredSeconds = billable
                }
            }
        }
    }

    func cancelRecording() {
        guard isRecording else { return }
        Diagnostics.session("cancelRecording")
        cancelTasks()
        daemon.cancel()
        recordingState = .idle
        hud?.hide()
    }

    private func finishRecording() {
        guard isRecording else { return }
        Diagnostics.session("finishRecording")
        cancelTasks()
        let used = elapsedSinceSessionStart()
        let billable = min(used, RecordingPolicy.maximumSessionSeconds)
        if !isLocalDistribution {
            subscriptions.consume(seconds: max(0, billable - meteredSeconds))
        }
        meteredSeconds = billable
        recordingState = .processing
        hud?.showProcessing()
        daemon.stop()
        processingTimeoutTask = Task { [weak self] in
            // 不检查取消就会在识别正常返回、任务刚被取消的瞬间误报超时。
            guard await Sleep.completed(for: .seconds(35)) else { return }
            guard let self, case .processing = self.recordingState else { return }
            self.daemon.cancel()
            let message = "识别服务响应超时，请重试"
            self.recordingState = .error(message)
            self.errorText = message
            self.hud?.showError(message)
        }
    }

    private func armSilenceCancellation() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            // 被取消就必须原地退出：level 事件每 50ms 一个、每个 voiced 都
            // 重新 arm 一次，若让取消掉的 task 继续往下走，它会看到
            // isRecording 仍为 true，把正在进行的录音掐掉。详见 Sleep 的注释。
            guard await Sleep.completed(for: .seconds(3)) else { return }
            guard let self, self.isRecording else { return }
            Diagnostics.session("静默 3 秒，自动取消")
            self.cancelRecording()
        }
    }

    private func handleDaemonEvent(_ event: DaemonClient.Event) {
        switch event {
        case .level(let peak, let voiced):
            sessionPeak = max(sessionPeak, peak)
            levels.append(min(1, Double(peak) / 6000))
            if levels.count > 40 { levels.removeFirst() }
            if voiced { armSilenceCancellation() }
        case .partial(let text):
            partialText = text
        case .final(let text):
            processingTimeoutTask?.cancel()
            Diagnostics.session("final \(text.count) 字（本段峰值 \(sessionPeak)）")
            recordingState = .idle
            paste(text)
            hud?.hide()
        case .empty:
            processingTimeoutTask?.cancel()
            recordingState = .idle
            Diagnostics.session("empty（本段峰值 \(sessionPeak)）")
            if RecordingPolicy.isLikelyLowGain(sessionPeak: sessionPeak) {
                hud?.showMessage("没听到内容 · 系统麦克风输入音量偏低")
            } else {
                hud?.showMessage("没有听到内容")
            }
        case .cancelled:
            processingTimeoutTask?.cancel()
            recordingState = .idle
            hud?.hide()
        case .error(let message):
            processingTimeoutTask?.cancel()
            cancelTasks()
            daemon.cancel()
            recordingState = .error(message)
            errorText = message
            hud?.showError(message)
        case .started:
            break
        }
    }

    private func paste(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        // 必须深拷贝，且必须在 clearContents 之前拷完。
        //
        // NSPasteboardItem 一旦写入过某个 pasteboard 就归它所有，把原对象再
        // writeObjects 回去会抛 NSInternalInconsistencyException——而 ObjC
        // 异常在 Swift 里 catch 不到，直接 SIGABRT。表现极具迷惑性：第一段
        // 识别得又快又准，文字也贴上去了，0.4 秒后恢复剪贴板时 App 才静默
        // 崩溃，于是"第二次按右 Option 没反应"，因为进程已经没了。
        let backup = Self.snapshotPasteboard(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let insertedChangeCount = pasteboard.changeCount
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard !backup.isEmpty else { return }
            guard ClipboardRestorationPolicy.shouldRestore(
                currentChangeCount: pasteboard.changeCount,
                insertedChangeCount: insertedChangeCount
            ) else { return }
            pasteboard.clearContents()
            pasteboard.writeObjects(backup)
        }
    }

    /// 把剪贴板内容复制成一组全新的 NSPasteboardItem。
    ///
    /// 直接留存 `pasteboard.pasteboardItems` 是不行的：那些对象归原 pasteboard
    /// 所有，clearContents 之后既读不到数据，写回去还会抛异常。
    static func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            let copy = NSPasteboardItem()
            var copiedAnything = false
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                copy.setData(data, forType: type)
                copiedAnything = true
            }
            return copiedAnything ? copy : nil
        }
    }

    func loadCredentials() -> ASRCredentialStore.Credentials {
        credentialStore.load()
    }

    func saveCredentials(apiKey: String, appID: String, accessKey: String) {
        credentialStore.save(.init(
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            appID: appID.trimmingCharacters(in: .whitespacesAndNewlines),
            accessKey: accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        daemonProcess.restartIfRunning()
        if credentialsConfigured, case .error = recordingState {
            recordingState = .idle
            errorText = ""
        }
        objectWillChange.send()
    }

    func setTransientHUDMessage(_ message: String) {
        transientHUDMessage = message
    }

    func requestMicrophonePermission() {
        Task {
            await PermissionCenter.requestMicrophone()
            refreshPermissionState()
            if microphoneGranted, case .error = recordingState {
                recordingState = .idle
                errorText = ""
                hud?.hide()
            }
        }
    }

    func openAccessibilitySettings() { PermissionCenter.openAccessibilitySettings() }
    func openInputMonitoringSettings() { PermissionCenter.openInputMonitoringSettings() }
    func openSubscriptionManagement() { subscriptions.openManagement() }
    func presentSettings() {
        if settingsWindow == nil {
            let view = SettingsView().environmentObject(self)
            let window = NSWindow(
                contentRect: NSRect(
                    x: 0,
                    y: 0,
                    width: 560,
                    height: isLocalDistribution ? 560 : 700
                ),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Doubao Voice 设置"
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func refreshPermissionState() {
        microphoneGranted = PermissionCenter.microphoneGranted
        accessibilityGranted = PermissionCenter.accessibilityGranted
        inputMonitoringGranted = PermissionCenter.inputMonitoringGranted
        if microphoneGranted,
           accessibilityGranted,
           inputMonitoringGranted,
           credentialsConfigured,
           case .error = recordingState {
            recordingState = .idle
            errorText = ""
        }
    }

    private func presentInitialSetupIfNeeded() {
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            presentSettings()
            return
        }
        guard !UserDefaults.standard.bool(forKey: Self.setupShownKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.setupShownKey)
        presentSettings()
    }

    private func cancelTasks() {
        countdownTask?.cancel()
        meteringTask?.cancel()
        silenceTask?.cancel()
        processingTimeoutTask?.cancel()
        countdownTask = nil
        meteringTask = nil
        silenceTask = nil
        processingTimeoutTask = nil
    }

    private var availableRecordingSeconds: TimeInterval {
        RecordingPolicy.availableSeconds(
            localDistribution: isLocalDistribution,
            subscriptionRemaining: subscriptions.remainingSeconds
        )
    }

    private func formatted(_ value: Int) -> String {
        String(format: "%02d:%02d", value / 60, value % 60)
    }

    private func elapsedSinceSessionStart() -> TimeInterval {
        guard let sessionStartedAt else { return 0 }
        let now = DispatchTime.now().uptimeNanoseconds
        return Double(now >= sessionStartedAt ? now - sessionStartedAt : 0) / 1_000_000_000
    }
}
