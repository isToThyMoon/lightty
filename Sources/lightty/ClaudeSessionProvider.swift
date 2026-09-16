import Foundation
import LighttyCore
import Darwin

/// Adapter to the pinned official SDK. File-format knowledge stays in the SDK.
///
/// 列表、改名、删除走打包的 SDK helper（`list-sessions.mjs` / `rename-session.mjs` /
/// `delete-session.mjs`）；占用与存活进程先问 Claude 自己的活会话表
/// （`claude agents --json`），删除前再扫一遍进程表，因为 Claude 不一定一直开着转录文件。
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

    /// `/rename` 往会话记录 `projects/<项目>/<id>.jsonl` 里追加一条 `custom-title`。
    /// 项目目录名是工作目录编码出来的、不可逆，所以按 ID 在各项目目录里找，不从目录反推。
    var titleSignalRequiresIdleSession: Bool { true }

    func titleSignalFiles(for key: AgentSessionKey) -> [URL] {
        guard UUID(uuidString: key.nativeID) != nil else { return [] }
        let projects = URL(fileURLWithPath: key.sourceRoot).appendingPathComponent("projects")
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: nil)) ?? []
        return directories.lazy.map { $0.appendingPathComponent(key.nativeID + ".jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }.map { [$0] } ?? []
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

    /// 先问活会话表，问不出或表里没有再读文件表。
    func occupancy(of key: AgentSessionKey) -> SessionOccupancy.Result {
        if let live = Self.liveSessions(executable: source.executable, root: key.sourceRoot),
           let row = live.first(where: { $0.sessionID == key.nativeID }) {
            return .inUse(pid: row.pid)
        }
        guard let data = SessionOccupancy.openFiles(command: SessionAgent.claude.executableName, timeout: 2)
        else { return .unknown }
        return Self.inspect(data, for: key)
    }

    static func inspect(_ data: Data, for key: AgentSessionKey) -> SessionOccupancy.Result {
        guard UUID(uuidString: key.nativeID) != nil else { return .unknown }
        return SessionOccupancy.firstWriter(data, command: SessionAgent.claude.executableName,
                                            root: key.sourceRoot, directories: ["projects"]) {
            $0 == key.nativeID + ".jsonl"
        }
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

    // MARK: - 删除前的进程核查

    /// 启动不到这么久、又不在活会话表里的 claude，可能只是还没来得及登记。
    /// 实测（claude 2.1.270，本机）从内核记下的启动时间到登记进表约 2.2 秒；取 5 秒，
    /// 给负载高、冷启动慢的时候留出一倍多的余量。再长就会把早已稳定却确实查不出身份的进程
    /// 也拖进等待，白白让删除变慢。
    static let registrationWindow: TimeInterval = 5
    /// 给年轻进程的那一次等待，之后只重读一次活会话表。取 2 秒：用户通常是确认删除框
    /// 一两秒前才起的 claude，这时它离登记只差不到 2 秒；更长的等待会让删除明显卡顿，
    /// 而没等到的代价只是多问一次「仍然删除」，不涉及数据安全。
    static let registrationWait: TimeInterval = 2

    /// 删除核查要读的外部状态。拆成可替换的几项，测试不起进程、不真的等。
    struct DeletionProbe {
        /// `ps -axo pid=,comm=` 的输出；读不出返回 nil。
        var processTable: () -> Data?
        /// Claude 的活会话表；问不出来返回 nil。
        var liveSessions: () -> [LiveSession]?
        /// 进程的内核身份（含启动时间）；进程不在或读不出返回 nil。
        var identity: (Int32) -> AgentProcessIdentity?
        var now: () -> Date
        /// 阻塞当前线程指定秒数。
        var wait: (TimeInterval) -> Void

        static func system(executable: String, root: String) -> Self {
            Self(
                // lsof alone misses Claude, which need not keep its transcript descriptor open.
                processTable: {
                    try? SessionHelperProcess.readPage(executable: URL(fileURLWithPath: "/bin/ps"),
                        arguments: ["-axo", "pid=,comm="], directory: URL(fileURLWithPath: "/"),
                        environment: ["PATH": "/usr/bin:/bin"], cancelled: { false }, timeout: 3)
                },
                liveSessions: { ClaudeSessionProvider.liveSessions(executable: executable, root: root) },
                identity: { AgentProcessIdentity.read($0) },
                now: { Date() },
                wait: { seconds in
                    // 删除核查只在 SessionDeletion.perform 派出的后台队列上跑；主线程上等会卡住界面。
                    assert(!Thread.isMainThread, "Claude deletion check must not wait on the main thread")
                    Thread.sleep(forTimeInterval: seconds)
                })
        }
    }

    func checkDeletable(_ target: AgentSessionKey, known: [AgentProcessIdentity: AgentSessionKey]) throws {
        try Self.checkDeletable(target, known: known,
            probe: .system(executable: source.executable, root: target.sourceRoot))
    }

    /// 进程表里每个 claude 进程都要有身份：来自活会话表，或本应用 pane 核对过的关联。
    /// 有一个在跑目标会话就拒绝；有身份不明的就说不清。
    ///
    /// 刚启动的 claude 还没登记进活会话表（见 `registrationWindow`），会被误判成身份不明。
    /// 所以身份不明的进程里有启动不久的，就等 `registrationWait` 后重读一次表再判。
    /// 同时有老的也照样等：结论虽然注定是说不清，但用户随后可以点「仍然删除」压掉它，
    /// 若年轻的那个跑的正是目标，必须先以确认占用拒绝，不能被那次同意一并压过去。
    /// 只有身份不明的全是老的才立即返回，不等。
    /// 第一次读表就失败时同样不等：「问不出来」不能靠多等一会儿变成「没人用」。
    static func checkDeletable(_ target: AgentSessionKey, known: [AgentProcessIdentity: AgentSessionKey],
                               probe: DeletionProbe) throws {
        guard let data = probe.processTable() else {
            throw SessionDeletion.Failure.unknownOccupancy(nil)
        }
        func key(_ row: LiveSession) -> AgentSessionKey {
            AgentSessionKey(agent: .claude, sourceRoot: target.sourceRoot, nativeID: row.sessionID)
        }
        var live: [Int32: AgentSessionKey] = [:]
        // Claude 自己就知道每个活着的进程在跑哪段会话。以前只认 lightty 自己开的 pane，
        // 用户在别处开着的 claude 一律算「说不清」，于是删除几乎每次都要弹一次警告。
        let registry = probe.liveSessions()
        for row in registry ?? [] { live[row.pid] = key(row) }
        // PID reuse must never inherit the previous process's session identity.
        // 自己的 pane 后合并：这份身份是核对过进程标识的，比问来的更可信。
        for (identity, key) in known where probe.identity(identity.pid) == identity {
            live[identity.pid] = key
        }
        let unknown = try unidentifiedProcesses(data, target: target, known: live)
        guard let last = unknown.last else { return }
        guard registry != nil else { throw SessionDeletion.Failure.unknownOccupancy(last) }

        // 登记窗口：先记下每个身份不明进程的内核身份，等完核对没换人，才认它后来的登记。
        let now = probe.now()
        var young: [(pid: Int32, identity: AgentProcessIdentity)] = []
        var old: Int32?
        for pid in unknown {
            guard let identity = probe.identity(pid),
                  now.timeIntervalSince(identity.startDate) < registrationWindow else { old = pid; continue }
            young.append((pid, identity))
        }
        guard !young.isEmpty else { throw SessionDeletion.Failure.unknownOccupancy(old ?? last) }
        probe.wait(registrationWait)
        guard let second = probe.liveSessions() else { throw SessionDeletion.Failure.unknownOccupancy(last) }
        let registered = Dictionary(second.map { ($0.pid, key($0)) }, uniquingKeysWith: { first, _ in first })
        var stillUnknown = old
        for (pid, identity) in young {
            guard let key = registered[pid] else { stillUnknown = stillUnknown ?? pid; continue }
            // 登记的正是目标就是正面证据，哪怕 PID 刚被复用也有 claude 在跑它，先于换人判断。
            if key == target { throw SessionDeletion.Failure.occupiedProcess(pid) }
            if probe.identity(pid) != identity { stillUnknown = stillUnknown ?? pid }
        }
        if let stillUnknown { throw SessionDeletion.Failure.unknownOccupancy(stillUnknown) }
    }

    static func inspectProcesses(_ data: Data, target: AgentSessionKey,
                                 known: [Int32: AgentSessionKey]) throws {
        if let unknown = try unidentifiedProcesses(data, target: target, known: known).last {
            throw SessionDeletion.Failure.unknownOccupancy(unknown)
        }
    }

    /// 按进程表顺序返回身份不明的 claude 进程；已知在跑目标会话、或进程表认不出时直接抛。
    private static func unidentifiedProcesses(_ data: Data, target: AgentSessionKey,
                                              known: [Int32: AgentSessionKey]) throws -> [Int32] {
        guard !data.isEmpty else { throw SessionDeletion.Failure.unknownOccupancy(nil) }
        var unknown: [Int32] = []
        let command = SessionAgent.claude.executableName
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, let pid = Int32(fields[0]) else {
                throw SessionDeletion.Failure.unknownOccupancy(nil)
            }
            let name = fields[1].trimmingCharacters(in: .whitespaces)
            guard name == command || name.hasSuffix("/" + command) else { continue }
            guard let key = known[pid] else { unknown.append(pid); continue }
            // Native IDs alone are not enough: custom configuration roots are independent.
            if key == target { throw SessionDeletion.Failure.occupiedProcess(pid) }
        }
        return unknown
    }
}

private extension AgentProcessIdentity {
    /// 内核记下的进程启动时刻。
    var startDate: Date {
        Date(timeIntervalSince1970: TimeInterval(startedSeconds) + TimeInterval(startedMicroseconds) / 1_000_000)
    }
}
