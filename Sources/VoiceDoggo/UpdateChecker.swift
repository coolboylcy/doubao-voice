import AppKit
import Foundation

/// 检查、下载并安装新版本。
///
/// 没有用 Sparkle：那套要维护 EdDSA 密钥对、每次发版生成并签名 appcast.xml，
/// 而这个 App 的分发本来就只有一条路——GitHub Releases 上一个经过 Apple 公证的
/// DMG。直接读 Releases API、装公证过的包，链路更短，也少一套要守的密钥。
///
/// 安全性不靠自己校验哈希，靠 Apple 的公证：下载完先用 `spctl` 按安装规则评估
/// 一遍，不通过就不装。这跟用户手动双击 DMG 时 Gatekeeper 做的是同一件事，
/// 中间人换包会当场被拦下。
@MainActor
final class UpdateChecker: ObservableObject {
    nonisolated struct Release: Equatable {
        let version: String
        let notes: String
        let downloadURL: URL
        let pageURL: URL
    }

    enum Phase: Equatable {
        case idle
        case checking
        case available(Release)
        case downloading(Double)
        case verifying
        case readyToRestart
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    /// 用户跳过的版本。跳过的是具体某一版，不是「以后都别烦我」——
    /// 下一版出来照样提醒。
    private static let skippedKey = "VoiceDoggo.skippedUpdateVersion"
    private static let lastCheckKey = "VoiceDoggo.lastUpdateCheck"
    /// 启动后隔一会儿再查。开机那阵子网络常常还没就绪，而且这时候弹更新框
    /// 最惹人烦。
    private static let startupDelay: TimeInterval = 90
    private static let checkInterval: TimeInterval = 6 * 3600

    private let defaults: UserDefaults
    private let session: URLSession
    private var timer: Timer?

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
    }

    deinit { timer?.invalidate() }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    func start() {
        guard !ProcessInfo.processInfo.arguments.contains("--no-update-check") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startupDelay) { [weak self] in
            Task { await self?.checkIfDue() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkIfDue() }
        }
    }

    private func checkIfDue() async {
        let last = defaults.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last > Self.checkInterval else { return }
        await check(userInitiated: false)
    }

    /// 查一次。`userInitiated` 为 true 时忽略「跳过此版本」，也会把「已是最新」
    /// 这种结果反馈出来——用户自己点的按钮，不能毫无反应。
    func check(userInitiated: Bool) async {
        if case .downloading = phase { return }
        if case .verifying = phase { return }

        phase = .checking
        defaults.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)

        do {
            let release = try await fetchLatest()
            guard Self.isNewer(release.version, than: currentVersion) else {
                phase = .idle
                return
            }
            if !userInitiated, defaults.string(forKey: Self.skippedKey) == release.version {
                phase = .idle
                return
            }
            phase = .available(release)
        } catch {
            Diagnostics.session("检查更新失败：\(error.localizedDescription)")
            phase = userInitiated ? .failed("没能连上更新服务器，稍后再试") : .idle
        }
    }

    /// 仅供 --render-update 预览用：把状态摆成「发现了新版本」，不联网。
    func presentForPreview(_ release: Release) {
        phase = .available(release)
    }

    func skip(_ release: Release) {
        defaults.set(release.version, forKey: Self.skippedKey)
        phase = .idle
    }

    func dismiss() {
        phase = .idle
    }

    // MARK: - 拉取版本信息

    private func fetchLatest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/coolboylcy/voice-doggo/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.badResponse
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpdateError.badResponse
        }
        return try Self.parse(json)
    }

    // 纯函数，不碰任何状态——标 nonisolated 既是事实陈述，也让它能直接被测试调用
    nonisolated static func parse(_ json: [String: Any]) throws -> Release {
        guard let tag = json["tag_name"] as? String else { throw UpdateError.badResponse }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag

        // 认固定文件名那个资产。带版本号的文件名每次都变，靠它拼地址迟早拼错；
        // 发布脚本保证每次都会传一份 VoiceDoggo.dmg。
        let assets = json["assets"] as? [[String: Any]] ?? []
        let asset = assets.first { ($0["name"] as? String) == "VoiceDoggo.dmg" }
            ?? assets.first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
        guard
            let urlString = asset?["browser_download_url"] as? String,
            let url = URL(string: urlString)
        else { throw UpdateError.noAsset }

        let page = (json["html_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/coolboylcy/voice-doggo/releases/latest")!

        return Release(
            version: version,
            notes: (json["body"] as? String) ?? "",
            downloadURL: url,
            pageURL: page
        )
    }

    /// 语义化版本比较。
    ///
    /// 不能用字符串比大小：那样 "1.10.0" < "1.9.0"，用户会在 1.10 上被反复
    /// 提示「更新到 1.9」。也不能只比前两段。
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ value: String) -> [Int] {
            value.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = parts(candidate)
        let b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    nonisolated enum UpdateError: LocalizedError {
        case badResponse
        case noAsset
        case notNotarized
        case mountFailed
        case appNotFound
        case installFailed(String)

        var errorDescription: String? {
            switch self {
            case .badResponse: return "更新服务器没有正常回应"
            case .noAsset: return "这个版本没有可下载的安装包"
            case .notNotarized: return "下载到的安装包没有通过 Apple 公证校验，已经丢弃"
            case .mountFailed: return "安装包打不开"
            case .appNotFound: return "安装包里找不到语音狗子"
            case .installFailed(let detail): return detail
            }
        }
    }
}

// MARK: - 下载与安装

extension UpdateChecker {
    func install(_ release: Release) {
        Task { await performInstall(release) }
    }

    private func performInstall(_ release: Release) async {
        do {
            phase = .downloading(0)
            let dmg = try await download(release)

            phase = .verifying
            try verifyNotarized(dmg)
            let newApp = try mountAndLocateApp(dmg)

            phase = .readyToRestart
            try scheduleSwap(from: newApp, dmg: dmg)
        } catch {
            Diagnostics.session("安装更新失败：\(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
    }

    private func download(_ release: Release) async throws -> URL {
        let (temp, response) = try await session.download(from: release.downloadURL) { [weak self] progress in
            Task { @MainActor in
                guard let self, case .downloading = self.phase else { return }
                self.phase = .downloading(progress)
            }
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.badResponse
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceDoggo-\(release.version).dmg")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }

    /// 按 Gatekeeper 的安装规则评估下载到的镜像。
    ///
    /// 这是整条链路上唯一的安全闸门，不能省。走的就是用户手动双击 DMG 时系统
    /// 做的那套检查：签名完整、证书链有效、而且这份镜像确实被 Apple 公证过。
    /// 中间人把包换掉，这里当场拦下。
    private func verifyNotarized(_ dmg: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
        task.arguments = ["-a", "-t", "install", "-vv", dmg.path]
        let pipe = Pipe()
        task.standardError = pipe
        task.standardOutput = FileHandle.nullDevice
        try task.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        task.waitUntilExit()

        guard task.terminationStatus == 0, output.contains("accepted") else {
            try? FileManager.default.removeItem(at: dmg)
            Diagnostics.session("spctl 拒绝了下载的镜像：\(output)")
            throw UpdateError.notNotarized
        }
    }

    private func mountAndLocateApp(_ dmg: URL) throws -> URL {
        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceDoggoUpdate-\(UUID().uuidString)")

        let attach = Process()
        attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attach.arguments = [
            "attach", dmg.path,
            "-mountpoint", mountPoint.path,
            "-nobrowse", "-readonly", "-noverify",
        ]
        attach.standardOutput = FileHandle.nullDevice
        attach.standardError = FileHandle.nullDevice
        try attach.run()
        attach.waitUntilExit()
        guard attach.terminationStatus == 0 else { throw UpdateError.mountFailed }

        let app = mountPoint.appendingPathComponent("Voice Doggo.app")
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw UpdateError.appNotFound
        }
        return app
    }

    /// 交给一个独立脚本去换包，然后退出自己。
    ///
    /// 不能在进程内直接覆盖自己：copy 到一半时 App 的可执行文件、资源、内嵌
    /// helper 处于半新半旧的状态，任何一次访问都可能崩。所以把「等这个进程退出
    /// → 换包 → 重新打开」写成脚本交给 shell，本进程只管退出。
    ///
    /// 脚本先等旧进程真的没了再动手。不等的话 ditto 会跟正在运行的 App 抢文件。
    private func scheduleSwap(from newApp: URL, dmg: URL) throws {
        let target = Bundle.main.bundleURL
        let mountPoint = newApp.deletingLastPathComponent()
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-doggo-update-\(UUID().uuidString).sh")

        let body = """
        #!/bin/bash
        # 语音狗子自动更新。由 App 生成并在退出前启动，App 退出后才真正动手。
        set -o pipefail

        pid=$1
        for _ in $(seq 1 100); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
        done

        # 先复制到同一个卷上的临时位置再原子替换，避免中途失败留下一个残缺的 App
        staging=$(mktemp -d "$(dirname "\(target.path)")/.voice-doggo-update-XXXXXX")
        if /usr/bin/ditto "\(newApp.path)" "$staging/Voice Doggo.app"; then
            /bin/rm -rf "\(target.path)"
            /bin/mv "$staging/Voice Doggo.app" "\(target.path)"
        fi
        /bin/rm -rf "$staging"

        /usr/bin/hdiutil detach "\(mountPoint.path)" -quiet -force
        /bin/rm -f "\(dmg.path)"
        /usr/bin/open "\(target.path)"
        /bin/rm -f "$0"
        """

        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let runner = Process()
        runner.executableURL = URL(fileURLWithPath: "/bin/bash")
        runner.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier)]
        try runner.run()

        // 给脚本一点时间进到等待循环，再退出自己
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
    }
}

private extension URLSession {
    /// 带进度回调的下载。URLSession 自带的 downloadTask 要走 delegate 才拿得到
    /// 进度，这里用 KVO 观察 progress，省得为一个进度条铺一整套 delegate。
    func download(
        from url: URL,
        onProgress: @escaping (Double) -> Void
    ) async throws -> (URL, URLResponse) {
        var observation: NSKeyValueObservation?
        defer { observation?.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            let task = downloadTask(with: url) { location, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let location, let response else {
                    continuation.resume(throwing: UpdateChecker.UpdateError.badResponse)
                    return
                }
                // 回调返回后系统就会删掉这个临时文件，必须当场挪走
                let kept = FileManager.default.temporaryDirectory
                    .appendingPathComponent("voice-doggo-download-\(UUID().uuidString).dmg")
                do {
                    try FileManager.default.moveItem(at: location, to: kept)
                    continuation.resume(returning: (kept, response))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            observation = task.progress.observe(\.fractionCompleted) { progress, _ in
                onProgress(progress.fractionCompleted)
            }
            task.resume()
        }
    }
}
