import Foundation
import LighttyCore
import Darwin


/// codex 的会话操作都走它自己的 CLI：列表与改名用 `codex app-server`（stdio JSON-RPC），
/// 删除用 `codex delete --force`。占用与存活进程没有官方接口，于是一律不报。
struct CodexSessionProvider: AgentSessionProvider {
    let source: SessionCatalogSource

    // MARK: - 列表

    func page(archived: Bool, cursor: String?, cancelled: () -> Bool) throws -> SessionCatalogPage {
        if cancelled() { throw CancellationError() }
        let rpc = try CatalogJSONRPC.connected(to: source, cancelled: cancelled)
        defer { rpc.close() }
        var params: [String: Any] = ["limit": 100, "sourceKinds": ["cli"],
            "modelProviders": [], "archived": archived, "sortKey": "updated_at"]
        if let cursor { params["cursor"] = cursor }
        let response = try rpc.request("thread/list", params: params, cancelled: cancelled)
        let sessions = try Self.decode(response, source: source, archived: archived)
        return annotatingLiveSessions(SessionCatalogPage(sessions: sessions,
                                                         nextCursor: response["nextCursor"] as? String))
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

    // MARK: - 改名、删除

    /// app-server 的 `thread/name/set`。
    func rename(_ key: AgentSessionKey, to title: String) throws {
        let rpc = try CatalogJSONRPC.connected(to: source, cancelled: { false })
        defer { rpc.close() }
        _ = try rpc.request("thread/name/set", params: ["threadId": key.nativeID, "name": title],
                            cancelled: { false })
    }

    /// 连同派生的子会话一起永久删除；写锁冲突由 CLI 自己拒绝。
    func delete(_ key: AgentSessionKey) throws {
        _ = try AgentHelperProcess.agentCLI(source, arguments: ["delete", "--force", key.nativeID],
                                            directory: source.root).output(timeout: 45)
    }

    // MARK: - 占用与存活进程

    /// codex 没有可问的活会话表：`codex agents` 要先连上一个共用的后台服务，而 lightty
    /// 是直接在终端里跑 codex，不连那个服务。所以占用一律「问不出来」——别处开着的会话
    /// 不再标「在其他终端中打开」，删除时由 codex 自己的写锁拒绝。
    func occupancy(of key: AgentSessionKey) -> SessionOccupancy.Result { .unknown }

    /// 没有 Claude 那样的额外核查：codex 自己的写锁拒绝（含被占用的子会话）是权威。
    func checkDeletable(_ key: AgentSessionKey, known: [AgentProcessIdentity: AgentSessionKey]) throws {}

    /// 同上：没有官方接口能说出此刻哪些会话开着，也就不补工作目录。
    func observeLiveSessions() -> LiveSessionObservation? { nil }
}

/// Bounded stdio client for one `codex app-server` conversation; not an app-wide RPC
/// framework. Only the provider's list and rename use it, and both open a child, ask
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

    init(_ spec: AgentHelperProcess) throws {
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        process.environment = spec.environment
        process.currentDirectoryURL = spec.directory
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
        let rpc = try CatalogJSONRPC(.agentCLI(source, arguments: ["app-server", "--listen", "stdio://"],
                                               directory: source.root))
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
        if process.isRunning { ProcessTree.kill(process.processIdentifier) }
        try? output.fileHandleForReading.close()
    }
    deinit { close() }
}
