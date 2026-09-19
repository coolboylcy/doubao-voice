import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    /// 单项授权最多等多久。超时不是失败——用户可能中途去干别的了，
    /// 回来再点一次按钮就接着走。
    private static let guidedSetupStepTimeout: TimeInterval = 180

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
    /// 授权引导正在处理哪一项；nil 表示没在引导。
    @Published private(set) var guidedSetupStep: PermissionCenter.Step?
    /// 引导卡在「等用户重开 App」这一步（输入监控开完才生效）。
    @Published private(set) var awaitingRestart = false
    /// 识别引擎是否已就绪。冷启动要十几秒，这期间按热键只会录到空音频。
    @Published private(set) var engineReady = false

    let subscriptions = SubscriptionStore()
    let launchAtLogin = LaunchAtLoginController()
    let preferences = AppPreferences()
    private let hotkey = GlobalHotkeyMonitor()
    private let daemonProcess = DaemonProcessController()
    private let credentialStore = ASRCredentialStore.shared
    private var subscriptionCancellable: AnyCancellable?
    private var preferencesCancellable: AnyCancellable?
    private lazy var daemon = DaemonClient(socketPath: daemonProcess.socketPath)
    private var hotkeyDownAt: Date?
    private var toggleMode = false
    private var countdownTask: Task<Void, Never>?
    private var meteringTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?
    private var guidedSetupTask: Task<Void, Never>?
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
        hotkey.trigger = preferences.hotkey
        preferencesCancellable = preferences.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.hotkey.trigger = self.preferences.hotkey
                self.objectWillChange.send()
            }
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
                SystemNotifier.post(title: "语音狗子需要处理", body: message, enabled: self.preferences.systemNotifications)
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
            daemon.probeUntilReady()
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
        guidedSetupTask?.cancel()
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
    // 下面几个只服务商店订阅版。本地版用的是随包携带的离线模型，既没有
    // 月度额度也没有计费，相关 UI 一律不展示——留着「本地离线 · 无月度额度」
    // 这种占位文案只会让人以为存在某种限制。
    var monthlyQuotaHours: Int { subscriptions.monthlyQuotaHours }
    var quotaProgress: Double { subscriptions.quotaProgress }
    var quotaText: String { subscriptions.quotaText }
    var quotaColor: Color { subscriptions.remainingSeconds <= 600 ? .orange : .secondary }
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
        case .idle:
            if isLocalDistribution { return "已就绪 · 按住\(preferences.hotkey.title)说话" }
            return isSubscribed ? "已就绪 · \(preferences.hotkey.title)开始" : "需要订阅后使用"
        case .recording: return "正在听写 · 剩余 \(formatted(remainingSeconds))"
        case .processing: return "识别中……"
        case .paywall: return "订阅已到期或额度已用完"
        case .error(let message): return message
        }
    }

    var hotkeyTitle: String { preferences.hotkey.title }

    var subscriptionTitle: String {
        isSubscribed ? "语音狗子 Pro" : "解锁全局语音输入"
    }

    var subscriptionDetail: String {
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

    /// 用固定假数据把录音浮层摆出来，只为调样式。
    ///
    /// 浮层只在真实录音时出现，每调一次间距都要按住热键说句话，既慢又不稳定
    /// （每次波形都不一样，没法对比前后差异）。用 --demo-hud 启动即可。
    func presentDemoHUD() {
        recordingState = .recording
        remainingSeconds = 88
        partialText = "把这段话写进登录页面的注释里"
        // 直接用设计稿上量出来的那组条高（40,60,90,50,30,60,35,25,55,90,45,30
        // 归一化后），这样演示出来的波形跟设计稿逐根对得上。
        // 每个值铺满 samplesPerSlot 个样本，否则聚合取最大会把相邻格合并、抹平高低差。
        let shape: [Double] = [0.44, 0.67, 1.0, 0.56, 0.33, 0.67, 0.39, 0.28, 0.61, 1.0, 0.5, 0.33]
        levels = (0..<36).map { shape[($0 / 3) % shape.count] }
        hud?.show()
    }

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
        let message = "\(preferences.hotkey.title)暂不可用，请在设置中开启输入监控权限"
        errorText = message
        if case .idle = recordingState {
            recordingState = .error(message)
        }
        SystemNotifier.post(title: "听写快捷键暂不可用", body: message, enabled: preferences.systemNotifications)
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
        // 引擎没就绪时直接说明，而不是让人对着麦克风说完一整段才发现是空的。
        // 这是真实踩过的坑：启动后 14 秒内按键，命令全堆在客户端队列里，
        // 等就绪后才一起发出，结果录到峰值为 0 的空音频。
        guard engineReady else {
            let message = "识别引擎还在启动，大约十几秒，稍后再试"
            recordingState = .error(message)
            errorText = message
            hud?.showError(message)
            daemon.probeUntilReady()
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
        if preferences.showHUD { hud?.show() }
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
        if preferences.showHUD { hud?.showProcessing() }
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
            SystemNotifier.post(title: "识别超时", body: message, enabled: self.preferences.systemNotifications)
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
            deliver(text)
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
            SystemNotifier.post(title: "识别失败", body: message, enabled: preferences.systemNotifications)
        case .pong:
            if !engineReady {
                engineReady = true
                Diagnostics.session("识别引擎已就绪")
            }
        case .started:
            break
        }
    }

    private func deliver(_ text: String) {
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
        guard preferences.automaticInsertion else {
            hud?.showMessage("已复制到剪贴板")
            return
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        hud?.showDelivered()
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

    func setSystemNotifications(_ enabled: Bool) {
        preferences.systemNotifications = enabled
        SystemNotifier.setEnabled(enabled)
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

    // MARK: - 授权引导

    /// 一路走完三项授权。
    ///
    /// macOS 没有「一次全给」的接口——辅助功能和输入监控只能把用户送进系统
    /// 设置自己拨开关，这是系统设计，绕不过去。所以这里能做到的是：点一次，
    /// 剩下的由 App 盯着。每项发起请求后就开始轮询，用户在设置里拨完开关，
    /// App 立刻自动进入下一项，不用回来再点一次按钮。
    /// 单独请求某一项，给「去授权」按钮用。
    func requestPermission(_ step: PermissionCenter.Step) {
        Task {
            await PermissionCenter.request(step)
            refreshPermissionState()
            if microphoneGranted, case .error = recordingState {
                recordingState = .idle
                errorText = ""
                hud?.hide()
            }
        }
    }

    func startGuidedSetup() {
        guard guidedSetupStep == nil else { return }
        awaitingRestart = false
        guidedSetupTask?.cancel()
        guidedSetupTask = Task { [weak self] in
            await self?.runGuidedSetup()
        }
    }

    func cancelGuidedSetup() {
        guidedSetupTask?.cancel()
        guidedSetupTask = nil
        guidedSetupStep = nil
        awaitingRestart = false
    }

    private func runGuidedSetup() async {
        defer {
            guidedSetupStep = nil
            guidedSetupTask = nil
            refreshPermissionState()
        }

        for step in PermissionCenter.Step.allCases {
            if Task.isCancelled { return }
            guard !PermissionCenter.granted(step) else { continue }

            guidedSetupStep = step
            await PermissionCenter.request(step)

            // 输入监控必须在这里断开。
            //
            // CGPreflightListenEventAccess 在当前进程里会一直返回 false，
            // 哪怕用户刚在设置里把开关拨开了——这一项要等进程重启才认。所以
            // 既没法在这里等它变 true，也不能直接跳下一项：那会紧接着再弹一次
            // 系统设置，两个窗口叠在一起，谁也说不清该拨哪个。
            //
            // 重启本身就是引导的一步。停在这里，让界面把「重新打开」这个动作
            // 交给用户；重开之后权限仍不齐，设置窗口会自动再迎上来。
            if step.requiresRestart {
                awaitingRestart = true
                return
            }

            if await waitUntilGranted(step) == false { return }
            refreshPermissionState()
        }
    }

    /// 轮询等这一项被打开。
    ///
    /// 没有用 KVO/通知：TCC 状态变化不发通知，系统设置里的开关拨动也不会回调
    /// 到这个进程，只能自己问。0.4 秒一次，人从窗口切到系统设置再拨开关至少
    /// 也要几秒，这个频率既不会让人觉得卡顿，也不至于空转太凶。
    private func waitUntilGranted(_ step: PermissionCenter.Step) async -> Bool {
        var sentToSettings = false
        let deadline = Date().addingTimeInterval(Self.guidedSetupStepTimeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            if PermissionCenter.granted(step) { return true }

            // 用户在系统弹窗上点了「不允许」。那个弹窗一辈子只弹一次，再调
            // requestAccess 不会有任何反应，干等只会等到超时——得把人送到
            // 设置页去改。
            if !sentToSettings, PermissionCenter.isExplicitlyDenied(step) {
                sentToSettings = true
                await PermissionCenter.request(step)
            }

            guard await Sleep.completed(for: .milliseconds(400)) else { return false }
        }
        // 等超时不算失败：用户可能去干别的了，回来再点一次按钮即可。
        return false
    }

    /// 重置本 App 的 TCC 记录，然后重开。
    ///
    /// 给「系统设置里开关是开的，App 却说没授权」这种情况用——多半是换了签名
    /// 主体（本地构建版 → Developer ID 正式版）导致旧记录对不上。
    func resetAuthorizations() {
        let failed = PermissionCenter.resetAuthorizations()
        if failed.isEmpty {
            PermissionCenter.relaunch()
        } else {
            let names = failed.map(\.title).joined(separator: "、")
            errorText = "这几项没能重置：\(names)。请到「系统设置 → 隐私与安全性」里手动删掉「语音狗子」再重新添加。"
        }
    }

    func relaunch() { PermissionCenter.relaunch() }

    /// 卸载：把这个 App 在系统里留下的东西一并清掉，再把自己丢进废纸篓。
    ///
    /// 光把 App 拖进废纸篓是清不干净的——三项 TCC 授权会留在「系统设置 → 隐私
    /// 与安全性」里，登录项也还挂着。留着的授权条目除了碍眼，重装时还会因为
    /// 签名要求对不上变成一条既占位又不生效的僵尸记录，用户得先手动删了才能
    /// 重新授权。所以卸载必须连着清。
    ///
    /// 顺序有讲究：先停服务、再清授权、最后才移动 App 包。反过来的话，App 包
    /// 一动，tccutil 就找不到这个 bundle 了。
    func uninstall() {
        cancelGuidedSetup()
        hotkey.stop()
        daemonProcess.stop()
        launchAtLogin.setEnabled(false)

        PermissionCenter.resetAuthorizations()

        UserDefaults.standard.removePersistentDomain(forName: PermissionCenter.bundleIdentifier)
        UserDefaults.standard.synchronize()

        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Voice Doggo")
        if let support {
            try? FileManager.default.removeItem(at: support)
        }

        // 用 recycle 而不是 removeItem：删自己这种事该留一步反悔的余地，
        // 而且丢废纸篓不需要额外权限。
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
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
                    width: SettingsLayout.width,
                    height: SettingsLayout.height
                ),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "语音狗子设置"
            if BuildConfiguration.isLocalDistribution {
                // 设计稿顶部只有交通灯，没有标题栏文字：内容自己铺到最上面，
                // 靠 SettingsLayout.titlebarInset 给交通灯让出高度。
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
            }
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// `--demo-pending-permissions` 假装三项都没授权。
    ///
    /// 授权引导那段界面只在缺权限时出现，而开发机上三项早就开好了，正常路径下
    /// 根本渲染不出来——要么去系统设置里真把权限关掉（还得再开回来），要么就是
    /// 改完看不见。留这个开关配合 --render-settings 用。
    private static var pretendPermissionsMissing: Bool {
        ProcessInfo.processInfo.arguments.contains("--demo-pending-permissions")
    }

    private func refreshPermissionState() {
        if Self.pretendPermissionsMissing {
            microphoneGranted = false
            accessibilityGranted = false
            inputMonitoringGranted = false
            return
        }
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

    /// 权限没配齐就把设置窗口摆到用户面前。
    ///
    /// 以前的判据是「有没有弹过」，记在 UserDefaults 里。这有两个毛病：覆盖
    /// 安装时那个标记还在，于是不弹；而真正该弹的条件跟弹过几次没关系——权限
    /// 没配齐，App 就是个按了没反应的菜单栏图标，用户根本不知道该干嘛。
    ///
    /// 改成按状态判断：缺权限就弹，齐了就安静待着。
    private func presentInitialSetupIfNeeded() {
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            presentSettings()
            return
        }
        guard preferences.startupHint, !PermissionCenter.allGranted else { return }
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
