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
            .appendingPathComponent("Doubao Voice", isDirectory: true)
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
        environment["DBVOICE_CONFIG_DIR"] = configDirectory.path
        if BuildConfiguration.isLocalDistribution,
           let resources = Bundle.main.resourceURL?.appendingPathComponent("funasr") {
            environment["DBVOICE_BACKEND"] = "funasr"
            environment["DBVOICE_FUNASR_BIN"] = resources
                .appendingPathComponent("bin/llama-funasr-sensevoice").path
            environment["DBVOICE_FUNASR_MODEL"] = resources
                .appendingPathComponent("gguf/sensevoice-small-q8.gguf").path
            environment["DBVOICE_FUNASR_VAD"] = resources
                .appendingPathComponent("gguf/fsmn-vad.gguf").path
        } else {
            environment["DBVOICE_BACKEND"] = "doubao"
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
                if !wasStopping, terminated.terminationStatus != 0 {
                    self.report("后台语音服务意外退出（状态码 \(terminated.terminationStatus)）")
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

    func stop() {
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
            .appendingPathComponent("Contents/Helpers/dbvoice")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        // 开发期可以用 DOUBAO_VOICE_REPO 指向仓库，复用其虚拟环境。
        // 这里不设硬编码的默认仓库路径：那只在原作者本机成立，换台机器就
        // 指向一个不存在的文件，报错还会变成含义不明的「找不到内置语音服务」。
        guard let repo = ProcessInfo.processInfo.environment["DOUBAO_VOICE_REPO"] else {
            return nil
        }
        return URL(fileURLWithPath: repo).appendingPathComponent(".venv/bin/dbvoice")
    }

    private func report(_ message: String) {
        NSLog("Doubao Voice helper: %@", message)
        onError?(message)
    }
}
