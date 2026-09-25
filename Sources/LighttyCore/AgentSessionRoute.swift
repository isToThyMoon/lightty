import Foundation
import Darwin

/// 一段会话此刻显示在哪个 pane：hook 在 Agent 的共享后台进程里跑时，靠它找回自己的 pane。
///
/// 平时 hook 从继承来的 `LIGHTTY_PANE_ID` 就知道 pane。Codex 0.157 起，交互会话默认跑在一个
/// 多终端共用的 app-server 后台进程里，hook 由后台进程启动，继承的是后台进程自己的环境——
/// 那是第一个拉起它的终端的 pane，和当前会话无关（上游 `codex-rs/hooks/src/registry.rs`
/// 的 `Hooks::new` 用 `std::env::vars_os()` 取环境快照）。载荷里唯一可靠的身份是 `session_id`。
///
/// 所以由 lightty 在知道「会话 X 显示在 pane B、由界面进程 P 承载」的那一刻写下这条记录，
/// hook 按 `session_id` 读回来，之后发状态、找任务、写注入标记全走原来那条按 pane 的路。
/// 谁写、何时写见 `CodexSessionRouter`。
public struct AgentSessionRoute: Codable, Equatable, Sendable {
    public let pane: UUID
    /// 写这条记录的 lightty 实例的状态 socket。后台进程的环境里那一份可能属于别的实例或旧实例。
    public let socket: String
    /// 写记录的 lightty 进程；它死了记录就作废（清理与 hook 两边都据此判断）。
    public let owner: Int32
    /// 承载这段会话的界面进程（pane 里的前台作业）。hook 把它当作 agent 进程上报，
    /// lightty 据此判断会话何时结束；不知道时为 nil。
    public let client: AgentProcessIdentity?

    public init(pane: UUID, socket: String, owner: Int32 = getpid(), client: AgentProcessIdentity?) {
        self.pane = pane
        self.socket = socket
        self.owner = owner
        self.client = client
    }

    /// 还能不能用：写它的 lightty 还活着，界面进程（知道的话）也还在。
    public var isLive: Bool {
        guard Darwin.kill(owner, 0) == 0 || errno != ESRCH else { return false }
        return client.map { $0.liveness != .exited } ?? true
    }

    // MARK: - 存取

    /// `~/.lightty/run/sessions/`
    public static func directory(in runDirectory: URL = PaneRuntimeDirectory.runDirectory) -> URL {
        runDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    /// 会话 ID 来自 agent 载荷，拼进路径前只放行字母、数字、`-`、`_`：挡住路径穿越，
    /// 也挡住不像会话 ID 的脏值。两家的会话 ID 都是 UUID。
    public static func file(for sessionID: String,
                            in runDirectory: URL = PaneRuntimeDirectory.runDirectory) -> URL? {
        guard (1...128).contains(sessionID.count),
              sessionID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII
                  || $0 == "-" || $0 == "_" }) else { return nil }
        return directory(in: runDirectory).appendingPathComponent(sessionID)
    }

    /// 读回一条记录。没有、读不了、或已经作废都返回 nil——hook 这时退回原来的判断。
    public static func read(sessionID: String,
                            in runDirectory: URL = PaneRuntimeDirectory.runDirectory) -> Self? {
        guard let url = file(for: sessionID, in: runDirectory),
              let data = try? Data(contentsOf: url),
              let route = try? JSONDecoder().decode(Self.self, from: data),
              route.isLive else { return nil }
        return route
    }

    public func write(sessionID: String,
                      in runDirectory: URL = PaneRuntimeDirectory.runDirectory) throws {
        guard let url = Self.file(for: sessionID, in: runDirectory) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try PaneRuntimeDirectory.atomicWrite(try JSONEncoder().encode(self), to: url)
    }

    public static func remove(sessionID: String,
                              in runDirectory: URL = PaneRuntimeDirectory.runDirectory) {
        guard let url = file(for: sessionID, in: runDirectory) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 清掉作废的记录（写它的实例已退出、或界面进程已结束）。
    /// 只按记录自己的事实判断，所以不会误删另一个仍在运行的 lightty 实例写的记录。
    public static func sweepStale(in runDirectory: URL = PaneRuntimeDirectory.runDirectory) {
        let folder = directory(in: runDirectory)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil) else { return }
        for url in entries {
            let route = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
            if route?.isLive != true { try? FileManager.default.removeItem(at: url) }
        }
    }
}
