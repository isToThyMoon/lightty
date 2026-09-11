import Foundation
import LighttyCore
import Darwin

/// Positive evidence only. No match is unknown, not proof that native resume will succeed.
/// Never opens a transcript, takes a lock, or signals an Agent.
///
/// 两家的证据来源不一样，因为它们提供的东西不一样：
///
/// - **Claude** 自己维护着一张活会话表，`claude agents --json` 就是给脚本读的
///   （帮助里写着 "for scripting; does not require a TTY"）。它直接给出 pid 与
///   sessionId 的对应关系，是这个问题的正面答案。
/// - **Codex** 没有对等的东西：`codex agents` 要先有一个共用的后台服务，而 lightty
///   是直接在终端里跑 codex，不连那个服务；不连的话 `thread/list` 里每一条都是
///   「未加载」。所以 codex 只能退回读操作系统的文件表，靠会话记录文件的文件名反推。
///
/// 读文件表这条路对两家都留着：Claude 那条命令可能因为版本旧、输出改格式而失败，
/// 失败时不该把「问不出来」当成「没人用」。
enum SessionOccupancy {
    enum Result: Equatable { case inUse(pid: Int32), unknown }

    /// `executable` 是这个来源实际配置的 CLI 路径。传 nil 只走文件表——测试和拿不到
    /// 来源的调用方用，不是产品路径。
    static func check(_ key: AgentSessionKey, executable: String? = nil) -> Result {
        if key.agent == .claude, let executable,
           let live = liveClaudeSessions(executable: executable, root: key.sourceRoot),
           let pid = live.first(where: { $0.value == key.nativeID })?.key {
            return .inUse(pid: pid)
        }
        let command = key.agent.rawValue
        guard let data = try? SessionHelperProcess.readPage(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-n", "-P", "-b", "-a", "-u", String(getuid()), "-c", command, "-F0pcfan"],
            directory: URL(fileURLWithPath: "/"), environment: ["PATH": "/usr/bin:/bin"],
            cancelled: { false }, timeout: 2, maximumBytes: 4 * 1024 * 1024) else { return .unknown }
        return inspect(data, for: key)
    }

    /// `claude agents --json` 的一行。
    struct LiveClaudeSession: Equatable {
        let pid: Int32
        let sessionID: String
        let cwd: String?
    }

    /// Claude 当前活着的会话。命令失败或输出不认识时返回 nil（「问不出来」），
    /// 绝不返回空表——空表会被读成「一个都没在跑」。
    static func liveClaudeSessionRows(executable: String, root: String) -> [LiveClaudeSession]? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        var environment = ProcessInfo.processInfo.environment
        for name in environment.keys where name.hasPrefix("LIGHTTY_") { environment.removeValue(forKey: name) }
        environment["PATH"] = HookInstaller.searchPath().joined(separator: ":")
        environment["CLAUDE_CONFIG_DIR"] = root
        guard let data = try? SessionHelperProcess.readPage(
            executable: URL(fileURLWithPath: executable), arguments: ["agents", "--json"],
            directory: URL(fileURLWithPath: NSHomeDirectory()), environment: environment,
            cancelled: { false }, timeout: 8) else { return nil }
        return decodeLiveClaudeRows(data)
    }

    /// pid → sessionId。占用检测只关心这一层。
    static func liveClaudeSessions(executable: String, root: String) -> [Int32: String]? {
        liveClaudeSessionRows(executable: executable, root: root)
            .map { Dictionary(uniqueKeysWithValues: $0.map { ($0.pid, $0.sessionID) }) }
    }

    /// 单独拆出来是为了能用固定样本测：这条命令的输出格式不归 lightty 管，
    /// 认不出来必须退化成「问不出来」，而不是崩或者当成空表。
    static func decodeLiveClaudeRows(_ data: Data) -> [LiveClaudeSession]? {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var live: [LiveClaudeSession] = []
        for row in rows {
            // 少了 pid 或 sessionId 的一行说明这版输出和我们认识的不是一回事，
            // 这时整张表都不能信——漏掉一条就等于把「有人在用」读成「没人用」。
            guard let pid = row["pid"] as? Int, pid > 0, pid <= Int(Int32.max),
                  let id = row["sessionId"] as? String, UUID(uuidString: id) != nil else { return nil }
            // cwd 缺了不算致命：它只用来补目录，不参与占用判断。
            live.append(LiveClaudeSession(pid: Int32(pid), sessionID: id, cwd: row["cwd"] as? String))
        }
        return live
    }

    static func decodeLiveClaudeSessions(_ data: Data) -> [Int32: String]? {
        decodeLiveClaudeRows(data).map { Dictionary(uniqueKeysWithValues: $0.map { ($0.pid, $0.sessionID) }) }
    }

    /// lsof field output is NUL-delimited, with a newline separating process/file sets.
    /// Keep parsing separate so paths, access modes and partial output are fixture-testable.
    ///
    /// 只认**可写打开的会话记录文件**：命令名对得上、描述符是数字、访问模式是 u/w。
    /// 只读打开不算证据——别的工具也会读它。
    private static func forEachWritableSessionFile(
        _ data: Data, agent: SessionAgent, root: String,
        body: (_ pid: Int32, _ name: String) -> Void
    ) {
        let root = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        var pid: Int32?
        var command = ""
        var descriptor = ""
        var access = ""
        for field in String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: true) {
            let field = field.drop(while: { $0 == "\n" })
            guard let tag = field.first else { continue }
            let value = String(field.dropFirst())
            switch tag {
            case "p": pid = Int32(value); command = ""; descriptor = ""; access = ""
            case "c": command = value
            case "f": descriptor = value; access = ""
            case "a": access = value
            case "n":
                guard let pid, pid > 0, command == agent.rawValue,
                      Int(descriptor) != nil, access == "u" || access == "w",
                      value.hasPrefix("/") else { continue }
                let path = URL(fileURLWithPath: value).standardizedFileURL.path
                let directory: Bool
                switch agent {
                case .codex:
                    directory = path.hasPrefix(root + "/sessions/") || path.hasPrefix(root + "/archived_sessions/")
                case .claude:
                    directory = path.hasPrefix(root + "/projects/")
                }
                guard directory else { continue }
                body(pid, URL(fileURLWithPath: path).lastPathComponent)
            default: break
            }
        }
    }

    static func inspect(_ data: Data, for key: AgentSessionKey) -> Result {
        guard UUID(uuidString: key.nativeID) != nil else { return .unknown }
        var found: Int32?
        forEachWritableSessionFile(data, agent: key.agent, root: key.sourceRoot) { pid, name in
            guard found == nil else { return }
            let matches: Bool
            switch key.agent {
            case .codex: matches = name.hasPrefix("rollout-") && name.hasSuffix("-" + key.nativeID + ".jsonl")
            case .claude: matches = name == key.nativeID + ".jsonl"
            }
            if matches { found = pid }
        }
        return found.map { Result.inUse(pid: $0) } ?? .unknown
    }

    /// 一次问出**每个会话的具体进程**，保留同一会话多进程的证据，而不是逐条问。
    ///
    /// 列表要在用户点下去之前就标出「在别处开着」，逐条问 N 次不现实；
    /// 一次 `lsof -c <agent>` 实测 0.01 秒、4KB 输出，挂在刷新上不算负担。
    ///
    /// 命令失败返回 nil（「问不出来」），绝不返回空集——空集会被读成「一个都没开」。
    static func openSessionProcesses(agent: SessionAgent, root: String) -> [String: Set<AgentProcessIdentity>]? {
        guard let data = try? SessionHelperProcess.readPage(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-n", "-P", "-b", "-a", "-u", String(getuid()), "-c", agent.rawValue, "-F0pcfan"],
            directory: URL(fileURLWithPath: "/"), environment: ["PATH": "/usr/bin:/bin"],
            cancelled: { false }, timeout: 4, maximumBytes: 4 * 1024 * 1024) else { return nil }
        return decodeOpenSessionPIDs(data, agent: agent, root: root).mapValues { pids in
            Set(pids.compactMap(AgentProcessIdentity.read))
        }
    }

    /// 单独拆出来是为了能用固定样本测。文件名里的会话 id 是最后 36 个字符，
    /// codex 那边前面还带着时间戳（`rollout-<时间>-<id>.jsonl`）。
    static func decodeOpenSessionPIDs(_ data: Data, agent: SessionAgent, root: String) -> [String: Set<Int32>] {
        var processes: [String: Set<Int32>] = [:]
        forEachWritableSessionFile(data, agent: agent, root: root) { pid, name in
            guard name.hasSuffix(".jsonl") else { return }
            if agent == .codex, !name.hasPrefix("rollout-") { return }
            let stem = String(name.dropLast(".jsonl".count))
            guard stem.count >= 36 else { return }
            let id = String(stem.suffix(36))
            guard UUID(uuidString: id) != nil else { return }
            processes[id, default: []].insert(pid)
        }
        return processes
    }

}
