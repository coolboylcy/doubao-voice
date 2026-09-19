import Foundation

/// 落盘诊断日志。
///
/// 为什么不用 NSLog/os_log：Release + hardened runtime 下 NSLog 不进 unified
/// log，`log show` / `log stream` 都抓不到。热键和 daemon 通信这两条链路一旦
/// 出问题就是「全程静默」——没有落盘记录，只能靠反复重建二分，代价极高。
enum Diagnostics {
    private static let queue = DispatchQueue(label: "com.voicedoggo.diagnostics", qos: .utility)
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        return f
    }()

    static var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Voice Doggo", isDirectory: true)
    }

    /// IO 甩到后台队列：event tap 回调里阻塞会被系统判超时并直接禁用 tap。
    static func log(_ channel: String, _ message: String) {
        let stamp = formatter.string(from: Date())
        queue.async {
            guard let dir = directory else { return }
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(channel).log")
            let line = "\(stamp) \(message)\n"
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    static func hotkey(_ message: String) { log("hotkey", message) }
    static func daemon(_ message: String) { log("daemon-client", message) }
    static func session(_ message: String) { log("session", message) }
}
