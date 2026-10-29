import Foundation
import LighttyCore
import Testing
@testable import lightty

/// lightty 依赖的各家官方接口，逐项对着本机装的版本核一遍。升级 Claude Code / Codex 之后跑
/// `swift test --filter AgentContractTests`：哪一项没了，失败信息直接点名，不用等界面上出毛病。
/// 本机没装那一家就跳过。
///
/// 只核公开、机器可读的契约：Codex 的 app-server 协议（官方 `generate-json-schema` 生成）；
/// Claude 的 `claude agents --json`。Claude 的官方开发包版本锁在 helper 的 package-lock.json，
/// 升级它时由 `ClaudeSessionCatalogTests` 用合成转录核对。终端标题的形状没有机器可读的契约，
/// 按官方文档写成 `AgentTerminalTitleTests` 的表。
///
/// **代码里新用到一个方法、字段或枚举值，就加进下面的表。**
struct AgentContractTests {
    /// 专项检查要求两家都实际验证，避免未安装 CLI 却被报成全部通过。
    private static let required = ProcessInfo.processInfo.environment["LIGHTTY_REQUIRE_AGENT_CONTRACTS"] == "1"

    private func recordVersion(_ agent: SessionAgent, executable: String, directory: URL) throws {
        let data = try AgentHelperProcess.agentCLI(agent, executable: executable, root: directory.path,
            arguments: ["--version"], directory: directory).output(timeout: 15)
        let version = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        try #require(!version.isEmpty, "\(agent.rawValue) returned an empty version")
        let record = try JSONSerialization.data(withJSONObject: [
            "agent": agent.rawValue, "executable": executable, "version": version,
        ], options: [.sortedKeys])
        // 专项检查收集这一行；与实际测试共用可执行文件定位，不再用 shell 的 which 猜。
        print("LIGHTTY_AGENT_VERSION " + String(decoding: record, as: UTF8.self))
    }

    // MARK: - Codex app-server

    /// `CodexSessionProvider`、`CodexSessionRouter`、`CodexPluginInventory` 发出的请求。
    static let codexRequests = ["initialize", "thread/list", "thread/read", "thread/loaded/list",
                                "thread/name/set", "plugin/installed"]
    /// `CodexSessionRouter` 订阅的广播。
    static let codexNotifications = CodexSessionEvents.Method.allCases.map(\.rawValue)
    /// 读到的结构字段：定义名 → 字段。
    static let codexFields: [String: [String]] = [
        "ThreadListParams": ["useStateDbOnly"],
        "Thread": ["id", "cwd", "createdAt", "updatedAt", "name", "preview", "source", "originator",
                   "status", "parentThreadId", "ephemeral", "threadSource"],
        "ThreadStatusChangedNotification": ["threadId", "status"],
        "TurnCompletedNotification": ["threadId", "turn"],
        "ThreadStartedNotification": ["thread"],
        "Turn": ["id", "status"],
    ]
    /// 认的枚举值：定义名 → 值。`ThreadStatus` 是 `type` 区分的联合。
    static let codexEnums: [String: [String]] = [
        "ThreadStatus": ["active", "idle"],
        "ThreadActiveFlag": ["waitingOnApproval", "waitingOnUserInput"],
        "TurnStatus": ["completed", "interrupted", "failed"],
    ]

    static let codex = HookInstaller.locateExecutable(SessionAgent.codex.executableName)

    @Test(.enabled(if: codex != nil || required, "codex is not installed"))
    func codexAppServerStillSpeaksWhatLighttyUses() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try recordVersion(.codex, executable: try #require(Self.codex, "Codex CLI is required"), directory: directory)
        // 只在本地生成协议描述：不连后台进程、不建会话、不联网。
        _ = try AgentHelperProcess.agentCLI(.codex, executable: try #require(Self.codex), root: directory.path,
            arguments: ["app-server", "generate-json-schema", "--out", directory.path], directory: directory)
            .output(timeout: 60)

        func json(_ name: String) throws -> [String: Any] {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any], "\(name)")
        }
        func methods(_ name: String) throws -> Set<String> {
            let variants = try json(name)["oneOf"] as? [[String: Any]] ?? []
            return Set(variants.flatMap { variant -> [String] in
                let method = (variant["properties"] as? [String: Any])?["method"] as? [String: Any]
                return method?["enum"] as? [String] ?? []
            })
        }
        let requests = try methods("ClientRequest.json")
        for method in Self.codexRequests { #expect(requests.contains(method), "request \(method)") }
        let notifications = try methods("ServerNotification.json")
        for method in Self.codexNotifications { #expect(notifications.contains(method), "notification \(method)") }

        let definitions = try json("codex_app_server_protocol.v2.schemas.json")["definitions"] as? [String: Any] ?? [:]
        for (name, fields) in Self.codexFields {
            let properties = (definitions[name] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
            for field in fields { #expect(properties[field] != nil, "\(name).\(field)") }
        }
        for (name, values) in Self.codexEnums {
            let definition = definitions[name] as? [String: Any] ?? [:]
            // 平铺的枚举，或按 `type` 区分的联合（每个分支的 `type` 是单值枚举）。
            let flat = definition["enum"] as? [String] ?? []
            let tagged = (definition["oneOf"] as? [[String: Any]] ?? []).flatMap { variant -> [String] in
                let type = (variant["properties"] as? [String: Any])?["type"] as? [String: Any]
                return type?["enum"] as? [String] ?? []
            }
            for value in values { #expect((flat + tagged).contains(value), "\(name).\(value)") }
        }
        // 合成配置根发现不了大历史目录的扫描超时：用真实配置做只读目录查询，
        // 沿用生产的超时与参数；不输出会话正文、标题或路径，也不执行元数据写入。
        let configuration = SessionConfigurationLocation.resolve(agent: .codex,
            environment: ProcessInfo.processInfo.environment)
        let root = configuration.root(for: .codex, home: FileManager.default.homeDirectoryForCurrentUser)
        let source = SessionCatalogSource(agent: .codex, root: root,
            executable: try #require(Self.codex), configuration: configuration)
        for archived in [false, true] {
            _ = try CodexSessionProvider(source: source).page(archived: archived, cursor: nil, cancelled: { false })
        }
    }

    // MARK: - Claude Code

    static let claude = HookInstaller.locateExecutable(SessionAgent.claude.executableName)

    /// agent view 的两样官方接口：`claude agents --json` 是官方说的「从 Claude Code 外面读会话状态」的
    /// 正式途径（占用检测、agent view 跟随都靠它），后台会话行带着短 ID；`claude attach <id>` 把后台
    /// 会话连回终端（重启恢复、从侧栏打开后台会话都靠它）。读的是本机真实的活会话表（只读）。
    @Test(.enabled(if: claude != nil || required, "claude is not installed"))
    func claudeAgentViewInterfacesStillWork() throws {
        let executable = try #require(Self.claude)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try recordVersion(.claude, executable: executable, directory: directory)
        let root = SessionConfigurationLocation.resolve(agent: .claude, environment: ProcessInfo.processInfo.environment)
            .root(for: .claude, home: FileManager.default.homeDirectoryForCurrentUser).path
        let rows = ClaudeSessionProvider.liveSessions(executable: executable, root: root)
        #expect(rows != nil, "`claude agents --json` output is no longer recognized")
        for row in rows ?? [] where row.isBackground {
            #expect(row.jobID != nil, "background row \(row.sessionID ?? "?") has no `id` for `claude attach`")
        }
        // 只看帮助。不认识的子命令也退出 0、打印总帮助（`Usage: claude [options]…`），只能看首行。
        let help = try AgentHelperProcess.agentCLI(.claude, executable: executable, root: root,
            arguments: ["attach", "--help"], directory: FileManager.default.homeDirectoryForCurrentUser)
            .output(timeout: 15)
        #expect(String(decoding: help, as: UTF8.self).hasPrefix("Usage: claude attach"), "`claude attach` is gone")
    }
}
