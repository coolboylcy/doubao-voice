import Foundation
import Darwin
import AppKit

final class DaemonProcessController {
    private var process: Process?
    private var processGroup: pid_t?
    private var logHandle: FileHandle?
    private var stopping = false
    var onError: ((String) -> Void)?
    private var terminationObserver: NSObjectProtocol?
    private var restartWorkItem: DispatchWorkItem?
    private var restartAttempt = 0
    private var startedAt: Date?
    /// 连续重启上限。麦克风权限被撤销之类的故障是重启不好的，试几次就该
    /// 停下来报错，而不是无限拉起进程。
    private static let maximumRestartAttempts = 5
    /// 跑满这么久还活着，就认为上次崩溃是偶发，重启计数归零。
    private static let healthyRuntime: TimeInterval = 60

    init() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stop()
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        stop()
    }

    var configDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Voice Doggo", isDirectory: true)
    }

    var socketPath: String {
        configDirectory.appendingPathComponent("ctl.sock").path
    }

    var isRunning: Bool { process?.isRunning == true }

    func start() {
        guard process?.isRunning != true else { return }
        guard let executable = executableURL else {
            report("找不到内置语音服务")
            return
        }
        try? FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = executable
        p.arguments = ["daemon"]
        var environment = ProcessInfo.processInfo.environment
        environment["DOGGO_CONFIG_DIR"] = configDirectory.path
        // 让 daemon 能在 App 崩溃时自行收场。不能让它用 getppid()：
        // PyInstaller onefile 的 Python 进程父级是 bootloader 而不是本进程，
        // App 崩了那个值也不会变，孤儿会一直占着麦克风和 socket。
        environment["DOGGO_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        if BuildConfiguration.isLocalDistribution,
           let resources = Bundle.main.resourceURL?.appendingPathComponent("funasr") {
            environment["DOGGO_BACKEND"] = "funasr"
            environment["DOGGO_FUNASR_BIN"] = resources
                .appendingPathComponent("bin/llama-funasr-sensevoice").path
            environment["DOGGO_FUNASR_MODEL"] = resources
                .appendingPathComponent("gguf/sensevoice-small-q8.gguf").path
            environment["DOGGO_FUNASR_VAD"] = resources
                .appendingPathComponent("gguf/fsmn-vad.gguf").path
        } else {
            environment["DOGGO_BACKEND"] = "doubao"
        }
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        let credentials = ASRCredentialStore.shared.load()
        environment["DOUBAO_API_KEY"] = credentials.apiKey
        environment["DOUBAO_APP_ID"] = credentials.appID
        environment["DOUBAO_ACCESS_KEY"] = credentials.accessKey
        p.environment = environment
        let logURL = configDirectory.appendingPathComponent("helper.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            _ = try? handle.seekToEnd()
            logHandle = handle
            p.standardOutput = handle
            p.standardError = handle
        } else {
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
        }
        p.terminationHandler = { [weak self, weak p] terminated in
            Task { @MainActor in
                guard let self, self.process === p else { return }
                let wasStopping = self.stopping
                self.process = nil
                self.processGroup = nil
                try? self.logHandle?.close()
                self.logHandle = nil
                self.stopping = false
                if !wasStopping {
                    self.scheduleRestart(exitCode: terminated.terminationStatus)
                }
            }
        }
        do {
            try p.run()
        } catch {
            report("无法启动内置语音服务：\(error.localizedDescription)")
            return
        }
        process = p
        stopping = false
        startedAt = Date()
        Diagnostics.daemon("helper 已启动 pid=\(p.processIdentifier)")
        let pid = p.processIdentifier
        // 让 PyInstaller bootloader 与其 Python 子进程进入独立进程组，退出
        // App 时才能一次回收干净，不留下占用麦克风的孤儿进程。
        if pid > 0, setpgid(pid, pid) == 0 {
            processGroup = pid
        } else {
            processGroup = nil
        }
    }

    func restart() {
        stop()
        start()
    }

    func restartIfRunning() {
        guard isRunning else { return }
        restart()
    }

    /// daemon 意外退出后带退避地拉起来。
    ///
    /// 不这么做的话，helper 一崩就再也没人管：此后每次按右 Option 都发不出
    /// 命令，只能重启 App 才能恢复，而用户根本不知道发生了什么。
    @MainActor
    private func scheduleRestart(exitCode: Int32) {
        if let startedAt, Date().timeIntervalSince(startedAt) > Self.healthyRuntime {
            restartAttempt = 0
        }
        restartAttempt += 1
        guard restartAttempt <= Self.maximumRestartAttempts else {
            Diagnostics.daemon("helper 连续 \(restartAttempt - 1) 次异常退出，放弃重启")
            report("后台语音服务反复退出（状态码 \(exitCode)），请重启 App 或查看 helper.log")
            return
        }
        let delay = min(pow(2, Double(restartAttempt - 1)), 30)
        Diagnostics.daemon(
            "helper 异常退出（状态码 \(exitCode)），\(Int(delay))s 后进行第 \(restartAttempt) 次重启"
        )
        restartWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.start() }
        restartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func stop() {
        restartWorkItem?.cancel()
        restartWorkItem = nil
        restartAttempt = 0
        guard let runningProcess = process else { return }
        stopping = true
        runningProcess.terminate()
        // PyInstaller one-file 会先启动 bootloader，再派生真正的 Python
        // 运行时。两者处于同一个独立进程组；只 terminate 父进程会留下子进程。
        if let processGroup, processGroup > 0 {
            _ = killpg(processGroup, SIGTERM)
        }
        process = nil
        self.processGroup = nil
        try? logHandle?.close()
        logHandle = nil
    }

    private var executableURL: URL? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/doggo")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        // 开发期可以用 DOUBAO_VOICE_REPO 指向仓库，复用其虚拟环境。
        // 这里不设硬编码的默认仓库路径：那只在原作者本机成立，换台机器就
        // 指向一个不存在的文件，报错还会变成含义不明的「找不到内置语音服务」。
        guard let repo = ProcessInfo.processInfo.environment["DOUBAO_VOICE_REPO"] else {
            return nil
        }
        return URL(fileURLWithPath: repo).appendingPathComponent(".venv/bin/doggo")
    }

    private func report(_ message: String) {
        NSLog("Voice Doggo helper: %@", message)
        onError?(message)
    }
}
