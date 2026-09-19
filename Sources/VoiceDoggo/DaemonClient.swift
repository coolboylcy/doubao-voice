import Foundation
import Network

final class DaemonClient {
    enum Event {
        case pong
        case started
        case level(Int, Bool)
        case partial(String)
        case final(String)
        case empty
        case cancelled
        case error(String)
    }

    var onEvent: ((Event) -> Void)?
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var ready = false
    private var pendingCommands: [[String: Any]] = []
    private let socketPath: String
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectAttempt = 0
    private let maximumReconnectAttempts = 30

    init(socketPath: String? = nil) {
        self.socketPath = socketPath ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".voice-doggo/ctl.sock").path
    }

    func connectAndStart() {
        connectIfNeeded()
        send(["cmd": "start"])
    }

    /// 反复 ping 直到 daemon 应答。
    ///
    /// PyInstaller 冷启动加载模型要十几秒，这段时间里按热键只会录到空音频
    /// （命令堆在 pendingCommands 里，等就绪后才一起发出）。有了这个探测，
    /// App 才能在界面上明说「还在启动」，而不是让人白录一段。
    func probeUntilReady() {
        guard !isReady else { return }
        send(["cmd": "ping"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.probeUntilReady()
        }
    }

    private(set) var isReady = false

    func stop() { send(["cmd": "stop"]) }
    func cancel() { send(["cmd": "cancel"]) }

    private func connectIfNeeded() {
        guard connection == nil else { return }
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        Diagnostics.daemon("connect → \(socketPath)")
        let c = NWConnection(to: .unix(path: socketPath), using: .tcp)
        connection = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Diagnostics.daemon("state = \(state)")
            if case .ready = state {
                self.ready = true
                self.reconnectAttempt = 0
                self.flushPendingCommands()
            }
            // `.waiting` 必须当失败处理并重连：socket 还没出现时 NWConnection
            // 默认停在 waiting 而不是 failed，既不 ready 也不触发重连，命令会
            // 永远烂在 pendingCommands 里——外部表现是波形闪一下就没了，
            // daemon 端一条命令都收不到。
            if case .waiting(let error) = state {
                self.handleDisconnect(connection: c, lastError: error)
            }
            if case .failed(let error) = state {
                self.handleDisconnect(connection: c, lastError: error)
            }
            if case .cancelled = state, self.connection === c {
                self.ready = false
                self.connection = nil
            }
        }
        c.start(queue: .main)
        receive(over: c)
    }

    private func send(_ object: [String: Any]) {
        Diagnostics.daemon("send \(object["cmd"] ?? "?") (ready=\(ready))")
        connectIfNeeded()
        pendingCommands.append(object)
        flushPendingCommands()
    }

    private func flushPendingCommands() {
        guard ready, let connection else { return }
        guard !pendingCommands.isEmpty else { return }
        let commands = pendingCommands
        pendingCommands.removeAll()
        for object in commands {
            sendReady(object, over: connection)
        }
    }

    private func sendReady(_ object: [String: Any], over connection: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        Diagnostics.daemon("flush \(object["cmd"] ?? "?")")
        connection.send(content: data + Data([0x0A]), completion: .contentProcessed { [weak self] error in
            if let error {
                guard let self else { return }
                Diagnostics.daemon("send 失败：\(error)")
                self.pendingCommands.insert(object, at: 0)
                self.handleDisconnect(connection: connection, lastError: error)
            }
        })
    }

    private func receive(over connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.receiveBuffer.append(data) }
            self.consumeLines()
            if isComplete || error != nil {
                self.handleDisconnect(connection: connection, lastError: error)
                return
            }
            self.receive(over: connection)
        }
    }

    private func handleDisconnect(connection disconnected: NWConnection, lastError: NWError? = nil) {
        guard connection === disconnected else { return }
        ready = false
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll(keepingCapacity: true)
        guard !pendingCommands.isEmpty else { return }

        reconnectAttempt += 1
        guard reconnectAttempt <= maximumReconnectAttempts else {
            pendingCommands.removeAll()
            let suffix = lastError.map { "：\($0.localizedDescription)" } ?? ""
            onEvent?(.error("无法连接后台语音服务\(suffix)"))
            return
        }

        // PyInstaller one-file 首次展开通常需要数秒。短间隔重连让 App 启动
        // helper 后不会因为第一次 socket 尚未出现就永久丢掉 start 命令。
        let delay = min(0.1 * Double(reconnectAttempt), 0.5)
        let work = DispatchWorkItem { [weak self] in self?.connectIfNeeded() }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func consumeLines() {
        while let newline = receiveBuffer.firstIndex(of: 0x0A) {
            let line = receiveBuffer.prefix(upTo: newline)
            receiveBuffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["event"] is String else { continue }
            // level 每 50ms 一条，记下来会把日志刷爆
            if (object["event"] as? String) != "level" {
                Diagnostics.daemon("recv \(object["event"] ?? "?")")
            }
            if let decoded = Self.decodeEvent(object) {
                if case .pong = decoded { isReady = true }
                onEvent?(decoded)
            }
        }
    }

    static func decodeEvent(_ object: [String: Any]) -> Event? {
        guard let event = object["event"] as? String else { return nil }
        switch event {
        case "pong": return .pong
        case "started": return .started
        case "level": return .level(object["peak"] as? Int ?? 0, object["voiced"] as? Bool ?? false)
        case "partial": return .partial(object["text"] as? String ?? "")
        case "final": return .final(object["text"] as? String ?? "")
        case "empty": return .empty
        case "cancelled": return .cancelled
        case "error": return .error(object["message"] as? String ?? "未知错误")
        default: return nil
        }
    }
}
