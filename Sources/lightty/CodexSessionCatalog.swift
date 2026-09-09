import Foundation
import LighttyCore
import Darwin


struct CodexSessionCatalog: SessionCatalogProvider {
    let source: SessionCatalogSource

    func page(archived: Bool, cursor: String?, cancelled: () -> Bool) throws -> SessionCatalogPage {
        if cancelled() { throw CancellationError() }
        let rpc = try CatalogJSONRPC.connected(to: source, cancelled: cancelled)
        defer { rpc.close() }
        var params: [String: Any] = ["limit": 100, "sourceKinds": ["cli"],
            "modelProviders": [], "archived": archived, "sortKey": "updated_at"]
        if let cursor { params["cursor"] = cursor }
        let response = try rpc.request("thread/list", params: params, cancelled: cancelled)
        let sessions = try Self.decode(response, source: source, archived: archived)
        return SessionCatalogPage(sessions: Self.markRunning(sessions, root: source.root.path),
                                  nextCursor: response["nextCursor"] as? String)
    }

    /// 标出哪些会话此刻正开着，让列表在用户点下去之前就能说明白，
    /// 而不是点完撞上「该会话已在其他终端中打开」那个提示框。
    ///
    /// codex 没有 Claude 那样的活会话表（那要先连上共用的后台服务），只能读操作系统
    /// 的文件表。一次 `lsof -c codex` 实测 0.01 秒、4KB 输出，挂在刷新上不算负担。
    ///
    /// 问不出来就原样返回：这是锦上添花，不能因为它失败而让列表读不出来。
    /// 因此「没有标记」只意味着没有证据，不代表一定没开着——那个提示框仍然是最后一道防线。
    static func markRunning(_ sessions: [AgentSession], root: String) -> [AgentSession] {
        guard sessions.contains(where: { !$0.sourceRunning }),
              let open = SessionOccupancy.openSessionIDs(agent: .codex, root: root),
              !open.isEmpty else { return sessions }
        return sessions.map { session in
            guard open.contains(session.key.nativeID) else { return session }
            return AgentSession(key: session.key, title: session.title,
                                workingDirectory: session.workingDirectory,
                                updatedAt: session.updatedAt,
                                sourceArchived: session.sourceArchived, sourceRunning: true)
        }
    }

    static func decode(_ page: [String: Any], source: SessionCatalogSource,
                       archived: Bool) throws -> [AgentSession] {
        guard let records = page["data"] as? [[String: Any]] else { throw SessionCatalogError.protocolFailure }
        return try records.compactMap { record in
            // Fail closed: source filtering must not silently import desktop/IDE threads.
            guard record["source"] as? String == "cli" else { return nil }
            guard let id = record["id"] as? String, !id.isEmpty else { throw SessionCatalogError.protocolFailure }
            let name = record["name"] as? String
            let preview = record["preview"] as? String
            return AgentSession(
                key: .init(agent: .codex, sourceRoot: source.root.path, nativeID: id),
                title: [name, preview].compactMap { $0 }.first { !$0.isEmpty } ?? "",
                workingDirectory: record["cwd"] as? String,
                updatedAt: (record["updatedAt"] as? Double).map(Date.init(timeIntervalSince1970:)),
                sourceArchived: archived)
        }
    }
}

/// Bounded stdio client for one `codex app-server` conversation; not an app-wide RPC
/// framework. Only the catalog and `SessionRename` use it, and both open a child, ask
/// one question, and close it.
/// Reads are nonblocking so cancellation/deadlines also work when a CLI stops responding.
final class CatalogJSONRPC {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var requestID = 0
    private var closed = false
    private let deadline = Date().addingTimeInterval(45)

    init(executable: String, root: URL) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = root.path
        environment["PATH"] = HookInstaller.searchPath().joined(separator: ":")
        // A catalog process is not a pane and must never inherit its hook routing.
        for key in environment.keys where key.hasPrefix("LIGHTTY_") { environment.removeValue(forKey: key) }
        process.environment = environment
        process.currentDirectoryURL = root
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice // Never log private provider diagnostics.
        try process.run()
        let fd = output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    /// 握手：app-server 在 `initialize` 有回应、`initialized` 发出去之前不接别的方法。
    /// 两个调用方（列表、改名）都要走这一步，所以放在这里而不是各写一遍。
    static func connected(to source: SessionCatalogSource, cancelled: () -> Bool) throws -> CatalogJSONRPC {
        let rpc = try CatalogJSONRPC(executable: source.executable, root: source.root)
        do {
            _ = try rpc.request("initialize", params: [
                "clientInfo": ["name": "lightty_session_catalog", "version": "0.1.0"],
                "capabilities": ["experimentalApi": false],
            ], cancelled: cancelled)
            try rpc.notify("initialized")
        } catch {
            rpc.close()
            throw error
        }
        return rpc
    }

    func notify(_ method: String) throws { try send(["method": method]) }

    func request(_ method: String, params: [String: Any], cancelled: () -> Bool) throws -> [String: Any] {
        requestID += 1
        let id = requestID
        try send(["id": id, "method": method, "params": params])
        let requestDeadline = min(deadline, Date().addingTimeInterval(12))
        while Date() < requestDeadline {
            if cancelled() { throw CancellationError() }
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw SessionCatalogError.protocolFailure
                }
                guard message["id"] as? Int == id else { continue }
                guard message["error"] == nil, let value = message["result"] as? [String: Any] else {
                    throw SessionCatalogError.protocolFailure
                }
                return value
            }
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                buffer.append(contentsOf: bytes.prefix(count))
                if buffer.count > 8 * 1024 * 1024 { throw SessionCatalogError.tooLarge }
            } else if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
                throw SessionCatalogError.protocolFailure
            } else {
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        throw SessionCatalogError.timeout
    }

    private func send(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func close() {
        guard !closed else { return }
        closed = true
        try? input.fileHandleForWriting.close()
        let until = Date().addingTimeInterval(0.2)
        while process.isRunning, Date() < until { Thread.sleep(forTimeInterval: 0.005) }
        if process.isRunning { process.terminate() }
        let termination = Date().addingTimeInterval(0.2)
        while process.isRunning, Date() < termination { Thread.sleep(forTimeInterval: 0.005) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? output.fileHandleForReading.close()
    }
    deinit { close() }
}
