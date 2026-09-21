import Foundation
import LighttyCore

/// 一家 Agent 的会话操作：列表分页（`SessionCatalogProvider`）之外，还有改名、删除、
/// 占用检测和存活进程观测。
///
/// Agent 之间的差异——走哪个官方接口、起哪个 helper、从哪里找进程证据——只存在于
/// adapter 里（`ClaudeSessionProvider`、`CodexSessionProvider`）。调用方
/// （`SessionRename`、`SessionDeletion`、`PaneLauncher`、`SessionLibrary`）
/// 只管确认、互斥和刷新，不按 Agent 分支。
///
/// 每个方法只做一次原生操作，可能起子进程、会阻塞，不在主线程调。
/// 官方接口清单与为什么这样用，见 docs/specs/agent-session-apis.md。
protocol AgentSessionProvider: SessionCatalogProvider {
    /// 通过官方接口改一段**没开着**的会话的标题。`title` 由调用方清洗过。
    func rename(_ key: AgentSessionKey, to title: String) throws
    /// 官方的永久删除。不做任何占用检查，那是 `occupancy` / `checkDeletable` 和调用方的事。
    func delete(_ key: AgentSessionKey) throws
    /// 是否有进程正在用这段会话。只报正面证据；`.unknown` 不代表空闲。
    func occupancy(of key: AgentSessionKey) -> SessionOccupancy.Result
    /// 删除前这家 Agent 特有的额外核查。`known` 是本应用 pane 已核对过的进程身份。
    /// 能确认有人在用抛 `SessionDeletion.Failure.occupiedProcess`，说不清抛 `.unknownOccupancy`；
    /// 没有额外核查的 Agent 直接返回（原生接口自己的写锁拒绝仍然是权威）。
    func checkDeletable(_ key: AgentSessionKey, known: [AgentProcessIdentity: AgentSessionKey]) throws
    /// 此刻观察到的活会话进程（以及能顺带补上的工作目录）。问不出来返回 nil——绝不返回
    /// 空观察冒充「一个都没在跑」。
    func observeLiveSessions() -> LiveSessionObservation?
}

/// 占用检测的结论。只报正面证据：`.unknown` 是「问不出来」，不是「没人用」。
///
/// 证据只来自各家的官方接口：Claude 自己维护着一张活会话表（`claude agents --json`
/// 就是给脚本读的），直接给出 pid 与 sessionId 的对应；Codex 没有对等的东西
/// （`codex agents` 要先连上一个共用的后台服务，而 lightty 是直接在终端里跑 codex），
/// 所以它恒为 `.unknown`，由 codex 自己的写锁在删除时拒绝。
enum SessionOccupancy {
    enum Result: Equatable { case inUse(pid: Int32), unknown }
}

/// 一次观察的结果，按原生会话 ID 索引。只是读取时的证据，不是实时布尔值。
struct LiveSessionObservation: Equatable {
    var processes: [String: Set<AgentProcessIdentity>] = [:]
    /// 目录只用来补官方列表缺的那一项，不覆盖已有值。
    var workingDirectories: [String: String] = [:]
}

extension AgentSessionProvider {
    /// 把存活进程观察补进一页。观察是锦上添花：问不出来就原样返回，不能让列表读不出来。
    /// 因此「没有标记」只意味着没有证据，不代表一定没开着。
    func annotatingLiveSessions(_ page: SessionCatalogPage) -> SessionCatalogPage {
        guard !page.sessions.isEmpty, let live = observeLiveSessions() else { return page }
        return SessionCatalogPage(
            sessions: page.sessions.map { session in
                let id = session.key.nativeID
                let directory = session.workingDirectory ?? live.workingDirectories[id]
                let observed = live.processes[id] ?? []
                guard directory != session.workingDirectory || !observed.isEmpty else { return session }
                return AgentSession(key: session.key, title: session.title,
                                    workingDirectory: directory, updatedAt: session.updatedAt,
                                    sourceArchived: session.sourceArchived,
                                    sourceProcesses: observed, titleSettled: session.titleSettled)
            },
            nextCursor: page.nextCursor)
    }
}

extension SessionCatalogSource {
    /// 全 app 唯一按 Agent 选 adapter 的地方。穷举 switch：多一家 Agent 是编译错误。
    func makeProvider() -> AgentSessionProvider {
        switch agent {
        case .claude: return ClaudeSessionProvider(source: self)
        case .codex: return CodexSessionProvider(source: self)
        }
    }

    /// 写操作（改名、删除）之前的身份核对：同一家、同一配置根、UUID 形态的原生 ID。
    /// 对不上就不能动用户的 Agent 目录，也不起任何进程。
    func owns(_ key: AgentSessionKey) -> Bool {
        UUID(uuidString: key.nativeID) != nil && key.agent == agent
            && root.standardizedFileURL.path == key.sourceRoot && root.path != "/"
    }
}
