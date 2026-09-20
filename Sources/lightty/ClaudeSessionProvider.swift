import Foundation
import LighttyCore

/// Adapter to the pinned official SDK. File-format knowledge stays in the SDK.
///
/// 列表、改名、删除走打包的 SDK helper（`list-sessions.mjs` / `rename-session.mjs` /
/// `delete-session.mjs`）；占用与存活进程只问 Claude 自己的活会话表
/// （`claude agents --json`）。问不出来就是问不出来，不去读进程表或文件表反推。
struct ClaudeSessionProvider: AgentSessionProvider {
    let source: SessionCatalogSource
    var helperDirectory: URL? = nil // Injected fixture/build artifact, never a user shell command.

    static var installedHelper: URL {
        if Bundle.main.bundleURL.pathExtension == "app", let resources = Bundle.main.resourceURL {
            return resources.appendingPathComponent("claude-session-helper")
        }
        // SwiftPM executable is in .build/<triple>/debug (or release).
        let executable = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).standardizedFileURL
        var directory = executable.deletingLastPathComponent()
        while directory.path != "/" {
            if directory.lastPathComponent == ".build" {
                return directory.appendingPathComponent("claude-session-helper")
            }
            directory.deleteLastPathComponent()
        }
        return executable.deletingLastPathComponent().appendingPathComponent("claude-session-helper")
    }

    /// helper 里的一个脚本；运行时或脚本缺了直接说清楚，不去起一个必然失败的进程。
    private func script(_ name: String, arguments: [String]) throws -> AgentHelperProcess {
        let process = AgentHelperProcess.sdkScript(name, arguments: arguments,
                                                   helperDirectory: helperDirectory ?? Self.installedHelper,
                                                   source: source)
        guard FileManager.default.isExecutableFile(atPath: process.executable.path),
              FileManager.default.isReadableFile(atPath: process.arguments[0]) else {
            throw SessionCatalogError.unavailable(L("Claude session helper is missing. Reinstall the app; for debug builds run node scripts/prepare-claude-helper.mjs."))
        }
        return process
    }

    // MARK: - 列表

    func page(archived: Bool, cursor: String?, cancelled: () -> Bool) throws -> SessionCatalogPage {
        if cancelled() { throw CancellationError() }
        // Claude has no equivalent of Codex's archived_sessions catalog.
        if archived { return SessionCatalogPage(sessions: [], nextCursor: nil) }
        let offset = cursor ?? "0"
        let process = try script("list-sessions.mjs", arguments: [offset])
        guard let value = Int(offset), value >= 0, value < 50_000, String(value) == offset else {
            throw SessionCatalogError.tooLarge
        }
        if FileManager.default.fileExists(atPath: source.root.path),
           !FileManager.default.isReadableFile(atPath: source.root.path) {
            throw SessionCatalogError.unavailable(L("The CLI session directory is not readable."))
        }
        let data = try process.output(cancelled: cancelled)
        return annotatingLiveSessions(try Self.decode(data, source: source, offset: value))
    }

    static func decode(_ data: Data, source: SessionCatalogSource, offset: Int) throws -> SessionCatalogPage {
        struct Record: Decodable { let id: String; let title: String; let cwd: String?; let updatedAt: Double }
        struct Response: Decodable { let version: Int; let sessions: [Record]; let nextCursor: String? }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), response.version == 1,
              response.sessions.count <= 100 else { throw SessionCatalogError.protocolFailure }
        if let next = response.nextCursor {
            guard next == String(offset + 100), response.sessions.count == 100 else { throw SessionCatalogError.protocolFailure }
        }
        let rows = try response.sessions.map { row -> AgentSession in
            guard UUID(uuidString: row.id) != nil, row.updatedAt.isFinite else { throw SessionCatalogError.protocolFailure }
            return AgentSession(key: .init(agent: .claude, sourceRoot: source.root.path, nativeID: row.id),
                title: row.title, workingDirectory: row.cwd,
                updatedAt: Date(timeIntervalSince1970: row.updatedAt / 1000))
        }
        guard Set(rows.map(\.key)).count == rows.count else { throw SessionCatalogError.protocolFailure }
        return SessionCatalogPage(sessions: rows, nextCursor: response.nextCursor)
    }

    // MARK: - 改名、删除

    /// 官方开发包的 `renameSession`，跟 `listSessions` / `deleteSession` 同一个包。
    func rename(_ key: AgentSessionKey, to title: String) throws {
        let data = try script("rename-session.mjs", arguments: [key.nativeID, title]).output()
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["renamed"] as? String == key.nativeID else { throw SessionCatalogError.protocolFailure }
    }

    /// SDK helper is a local filesystem operation, not a Claude Agent invocation.
    func delete(_ key: AgentSessionKey) throws {
        let data = try script("delete-session.mjs", arguments: [key.nativeID]).output()
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["deleted"] as? String == key.nativeID else { throw SessionCatalogError.protocolFailure }
    }

    // MARK: - 占用与存活进程

    /// 只问活会话表：表里有这段会话就是正面证据，问不出来或表里没有都只是「说不清」。
    func occupancy(of key: AgentSessionKey) -> SessionOccupancy.Result {
        guard let live = Self.liveSessions(executable: source.executable, root: key.sourceRoot),
              let row = live.first(where: { $0.sessionID == key.nativeID }) else { return .unknown }
        return .inUse(pid: row.pid)
    }

    /// 问一次 Claude 的活会话表（`claude agents --json`），补两件事：
    ///
    /// 1. **缺失的工作目录**。官方开发包偶尔给不出（实测：34 条里有 2 条 `cwd` 是 null，
    ///    都是当时正在跑的会话）。绝不从项目目录名反解——那个编码不可逆
    ///    （路径里本来就有连字符时还原不回去），猜出来的路径比留空更糟。
    /// 2. **进程身份**。保留 PID 与启动时间，由统一模型判断所属和退出，
    ///    不在来源或视图里把“正在跑”直接解释成“在其他终端中打开”。
    ///
    /// 问不出来（命令不在、版本旧、输出改格式）就返回 nil：这两样都是锦上添花。
    func observeLiveSessions() -> LiveSessionObservation? {
        guard let live = Self.liveSessions(executable: source.executable, root: source.root.path) else { return nil }
        return LiveSessionObservation(
            processes: Dictionary(grouping: live, by: \.sessionID).mapValues { rows in
                Set(rows.compactMap { AgentProcessIdentity.read($0.pid) })
            },
            workingDirectories: Dictionary(live.compactMap { row in
                row.cwd.map { (row.sessionID, $0) }
            }, uniquingKeysWith: { first, _ in first }))
    }

    /// `claude agents --json` 的一行。
    struct LiveSession: Equatable {
        let pid: Int32
        let sessionID: String
        let cwd: String?
    }

    /// Claude 当前活着的会话。命令失败或输出不认识时返回 nil（「问不出来」），
    /// 绝不返回空表——空表会被读成「一个都没在跑」。
    static func liveSessions(executable: String, root: String) -> [LiveSession]? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        guard let data = try? AgentHelperProcess.agentCLI(.claude, executable: executable, root: root,
            arguments: ["agents", "--json"], directory: URL(fileURLWithPath: NSHomeDirectory()))
            .output(timeout: 8) else { return nil }
        return decodeLiveSessions(data)
    }

    /// 单独拆出来是为了能用固定样本测：这条命令的输出格式不归 lightty 管，
    /// 认不出来必须退化成「问不出来」，而不是崩或者当成空表。
    static func decodeLiveSessions(_ data: Data) -> [LiveSession]? {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var live: [LiveSession] = []
        for row in rows {
            // 少了 pid 或 sessionId 的一行说明这版输出和我们认识的不是一回事，
            // 这时整张表都不能信——漏掉一条就等于把「有人在用」读成「没人用」。
            guard let pid = row["pid"] as? Int, pid > 0, pid <= Int(Int32.max),
                  let id = row["sessionId"] as? String, UUID(uuidString: id) != nil else { return nil }
            // cwd 缺了不算致命：它只用来补目录，不参与占用判断。
            live.append(LiveSession(pid: Int32(pid), sessionID: id, cwd: row["cwd"] as? String))
        }
        return live
    }

    // MARK: - 删除前的核查

    /// 删除核查要读的外部状态。拆成可替换的一项，测试不起进程。
    struct DeletionProbe {
        /// Claude 的活会话表；问不出来返回 nil。
        var liveSessions: () -> [LiveSession]?

        static func system(executable: String, root: String) -> Self {
            Self(liveSessions: { ClaudeSessionProvider.liveSessions(executable: executable, root: root) })
        }
    }

    func checkDeletable(_ target: AgentSessionKey, known: [AgentProcessIdentity: AgentSessionKey]) throws {
        try Self.checkDeletable(target, known: known,
            probe: .system(executable: source.executable, root: target.sourceRoot))
    }

    /// 只认两处正面证据：Claude 自己的活会话表，和本应用 pane 核对过的进程身份。
    /// 表问不出来（命令不在、版本旧、输出改格式）就是「说不清」——绝不能把问不出来读成没人用。
    ///
    /// 不再扫进程表：那要按可执行文件名认 claude，而进程名随安装方式变，认错一个就把
    /// 「有人在用」读成「没人用」。代价是刚启动、还没登记进活会话表的外部 claude 查不出来，
    /// 这时表里没有它，结论是通过；接受。
    static func checkDeletable(_ target: AgentSessionKey, known: [AgentProcessIdentity: AgentSessionKey],
                               probe: DeletionProbe) throws {
        guard let live = probe.liveSessions() else {
            throw SessionDeletion.Failure.unknownOccupancy(nil)
        }
        if let row = live.first(where: { $0.sessionID == target.nativeID }) {
            throw SessionDeletion.Failure.occupiedProcess(row.pid)
        }
        // PID reuse must never inherit the previous process's session identity.
        // Native IDs alone are not enough: custom configuration roots are independent.
        for (identity, key) in known
        where key == target && AgentProcessIdentity.read(identity.pid) == identity {
            throw SessionDeletion.Failure.occupiedProcess(identity.pid)
        }
    }
}
