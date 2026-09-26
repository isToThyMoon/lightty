import Foundation
import LighttyCore

/// codex 的会话操作都走它自己的 CLI：列表与改名问常驻的 `codex app-server`（见 `CodexAppServer`），
/// 删除用 `codex delete --force`。占用与存活进程没有官方接口，于是一律不报。
struct CodexSessionProvider: AgentSessionProvider {
    let source: SessionCatalogSource

    private var server: CodexAppServer {
        CodexAppServer.shared(.agentCLI(source, arguments: ["app-server", "--listen", "stdio://"],
                                        directory: source.root), root: source.root)
    }

    // MARK: - 列表

    func page(archived: Bool, cursor: String?, cancelled: () -> Bool) throws -> SessionCatalogPage {
        if cancelled() { throw CancellationError() }
        // `vscode` 也要：0.157 起终端会话记在这个来源下，逐条再按 originator 筛（见 `decode`）。
        // 本地 app-server 拒绝非空的 `originators` 参数，只能拿回来自己筛。
        var params: [String: Any] = ["limit": 100, "sourceKinds": ["cli", "vscode"],
            "modelProviders": [], "archived": archived, "sortKey": "updated_at"]
        if let cursor { params["cursor"] = cursor }
        let response = try server.request("thread/list", params: params, cancelled: cancelled)
        let sessions = try Self.decode(response, source: source, archived: archived)
        return annotatingLiveSessions(SessionCatalogPage(sessions: sessions,
                                                         nextCursor: response["nextCursor"] as? String))
    }

    static func decode(_ page: [String: Any], source: SessionCatalogSource,
                       archived: Bool) throws -> [AgentSession] {
        guard let records = page["data"] as? [[String: Any]] else { throw SessionCatalogError.protocolFailure }
        return try records.compactMap { record in
            // Fail closed: source filtering must not silently import desktop/IDE threads.
            guard Self.isTerminalThread(record) else { return nil }
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

    /// 终端里建的会话：0.156 及以前记成 `source: cli`；0.157 起经共享后台进程建，记成
    /// `source: vscode`，只有 `originator` 还说明是终端界面（见 `CodexAgent.terminalOriginator`）。
    static func isTerminalThread(_ record: [String: Any]) -> Bool {
        switch record["source"] as? String {
        case "cli": return true
        case "vscode": return record["originator"] as? String == CodexAgent.terminalOriginator
        default: return false
        }
    }

    // MARK: - 改名、删除

    /// app-server 的 `thread/name/set`。
    func rename(_ key: AgentSessionKey, to title: String) throws {
        _ = try server.request("thread/name/set", params: ["threadId": key.nativeID, "name": title])
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
