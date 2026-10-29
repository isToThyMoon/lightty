import Foundation
import LighttyCore
import Testing
@testable import lightty

private final class MemoryPointers: TaskPointerStore {
    func write(taskFile: URL, for pane: UUID) {}
    func clear(for pane: UUID) {}
}

/// `claude agents --json` 的替身：后台会话的名字可以改、可以晚一步出现，某个名字的查询可以被扣住；
/// 前台会话单独记。查询跑在 `ClaudeAgentView` 自己的队列上，所以状态都加锁。
private final class BackgroundSessions: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String: String] = [:]
    private var interactive: [String: String] = [:]
    private var answered = 0
    private var asked = 0
    private var held: String?
    private let release = DispatchSemaphore(value: 0)

    func name(_ session: String, _ name: String) { lock.withLock { names[session] = name } }
    func foreground(_ session: String, _ name: String?) { lock.withLock { interactive[session] = name } }
    func hold(_ name: String) { lock.withLock { held = name } }
    func releaseHeld() { release.signal() }
    var queries: Int { lock.withLock { asked } }
    var completed: Int { lock.withLock { answered } }

    func rows(cwd: String) -> [ClaudeSessionProvider.LiveSession] {
        let (snapshot, front, hold) = lock.withLock { () -> ([String: String], [String: String], String?) in
            asked += 1
            return (names, interactive, held)
        }
        if let hold, snapshot.values.contains(hold) { release.wait() }
        defer { lock.withLock { answered += 1; held = nil } }
        return front.map { .init(pid: 30, sessionID: $0.key, cwd: cwd, name: $0.value) }
            + snapshot.map { .init(pid: 40, sessionID: $0.key, cwd: cwd, isBackground: true, name: $0.value) }
    }
}

@MainActor
struct ClaudeAgentViewTests {
    /// pane 跟着 agent view 里显示的会话走，只凭终端标题和 `claude agents --json`（官方文档：
    /// 列表的标题是 `claude agents` 或 `2 awaiting input · claude agents`，连上一段后台会话后是
    /// `<前缀> <会话名>`）。
    /// 回归：以前后台会话的 hook 带着第一个拉起 supervisor 的 pane 身份，备用会话的 SessionStart
    /// 把那个 pane 顶成一段空会话，标题和状态一起没了；别的 pane 转出来的会话也报到它上面。
    @Test func aPaneFollowsTheBackgroundSessionItShows() async throws {
        let f = try SessionModelFixture(agent: .claude)
        defer { f.close() }
        let foreground = f.record("foreground", title: "Emby player")
        let continued = f.record(UUID().uuidString, title: "Emby player")
        let other = f.record(UUID().uuidString, title: "Loading states")
        let late = f.record(UUID().uuidString, title: "Fresh")
        try await f.load([foreground, continued, other, late])
        let runDirectory = f.root.appendingPathComponent("run")
        let tasks = TaskBindings(store: TaskStore(directory: f.root.appendingPathComponent("tasks"), trash: { _ in }),
                                 pointers: MemoryPointers(), notificationCenter: NotificationCenter(),
                                 folderChanges: { _, _ in NSObject() })
        let sessions = BackgroundSessions()
        sessions.foreground(foreground.key.nativeID, "mobile-3f")
        sessions.name(other.key.nativeID, "Loading states")
        let root = f.root.path
        var diagnostics: [AgentDiagnostic] = []
        let view = ClaudeAgentView(library: f.library, taskBindings: tasks, socketPath: "/tmp/lightty-test.sock",
                                   runDirectory: runDirectory,
                                   diagnostic: { diagnostics.append($0) }, liveSessions: { _ in sessions.rows(cwd: root) })
        view.start()
        defer { view.stop() }
        let pane = f.pane()
        f.library.associate(.attached(f.association(foreground)), with: pane)
        tasks.bind(pane, to: f.root.appendingPathComponent("tasks/emby.md"), name: "emby")
        func shown(_ pane: UUID) -> String? { f.library.paneState(for: pane)?.sessionKey?.nativeID }
        func route(_ record: AgentSession) -> AgentSessionRoute? {
            AgentSessionRoute.read(sessionID: record.key.nativeID, in: runDirectory)
        }
        func title(_ text: String, _ target: UUID? = nil) { f.library.noteTerminalTitle(text, in: target ?? pane) }

        // 前台会话自己的标题：核对一次，关联的会话还在前台，什么都不改；转圈不再问。
        title("\u{2733} Emby player")
        try await f.wait { sessions.completed == 1 }
        title("\u{25D0} Emby player")
        await awaitMainQueue(hops: 2)
        #expect(sessions.queries == 1)
        #expect(shown(pane) == foreground.key.nativeID)

        // ← 转到后台（Claude 换了个会话 ID 接着跑），停在列表上，列表标题带着等输入的个数：
        // pane 不再显示哪段会话，任务还在。
        sessions.foreground(foreground.key.nativeID, nil)
        sessions.name(continued.key.nativeID, "Emby player")
        title("1 awaiting input \u{00B7} claude agents")
        try await f.wait { shown(pane) == nil }
        #expect(tasks.task(for: pane) != nil)

        // 连回被转到后台的同一段对话（新会话 ID、同名）：路由送进这个 pane，任务留着。
        title("\u{25D0} Emby player")
        try await f.wait { shown(pane) == continued.key.nativeID }
        #expect(route(continued)?.pane == pane)
        #expect(diagnostics.contains {
            $0.reason == .titleMatched && $0.pane == pane && $0.session == continued.key.nativeID
        })
        #expect(tasks.task(for: pane) != nil, "同一段对话换了个后台会话 ID，任务不该丢")
        title("\u{25D1} Emby player")
        await awaitMainQueue(hops: 2)
        #expect(sessions.queries == 2, "转圈时同一个名字只查一次")

        // 连着的时候改了名：再回列表、再连回来，还是同一段对话。
        sessions.name(continued.key.nativeID, "Emby player v2")
        title("\u{2733} Emby player v2")
        try await f.wait { sessions.completed == 3 }
        await awaitMainQueue(hops: 2)
        title("claude agents")
        try await f.wait { route(continued) == nil }
        title("\u{2733} Emby player v2")
        try await f.wait { shown(pane) == continued.key.nativeID }
        #expect(tasks.task(for: pane) != nil, "改名不是换对话")

        // 查询还没回来就回到了列表：回来的结果作废，pane 停在列表上。
        title("claude agents")
        sessions.hold("Loading states")
        title("\u{2733} Loading states")
        title("claude agents")
        sessions.releaseHeld()
        try await f.wait { sessions.completed == 5 }
        await awaitMainQueue(hops: 2)
        #expect(shown(pane) == nil)
        #expect(route(other) == nil)

        // 刚派出的会话还没进 `claude agents --json`：没查到；回列表再连时重新查。
        title("\u{2733} Fresh")
        try await f.wait { sessions.completed == 6 }
        await awaitMainQueue(hops: 2)
        #expect(shown(pane) == nil)
        sessions.name(late.key.nativeID, "Fresh")
        title("claude agents")
        title("\u{2733} Fresh")
        try await f.wait { shown(pane) == late.key.nativeID }

        // 回列表再连上另一段对话：旧路由撤掉，新的写上，任务解绑。
        title("claude agents")
        try await f.wait { route(late) == nil }
        title("\u{2733} Loading states")
        try await f.wait { shown(pane) == other.key.nativeID }
        #expect(route(other)?.pane == pane)
        #expect(tasks.task(for: pane) == nil)

        // 另一个 pane 也连上这一段：状态只送进后连上的那个，前一个不再关联它。
        let second = f.pane()
        title("claude agents", second)
        title("\u{2733} Loading states", second)
        try await f.wait { shown(second) == other.key.nativeID }
        #expect(route(other)?.pane == second)
        #expect(shown(pane) == nil)
    }
    /// 跟不跟上不靠「先看到列表」：每次核对都从头问，关联的会话不在前台了、有一段同名的后台会话，
    /// 就是连着它。回归：Claude 2.1.295 起列表标题带上了等输入的个数，旧代码一次没认出列表，
    /// pane 就一直关联着被转走的旧会话（官方目录把它藏起来了），标题掉回 pane 名、状态也收不到，
    /// 重启 lightty 也不会好。
    @Test func aPaneCatchesUpWithoutRecognizingTheListTitle() async throws {
        let f = try SessionModelFixture(agent: .claude)
        defer { f.close() }
        let moved = f.record("moved", title: "Photo order")
        let continued = f.record(UUID().uuidString, title: "Photo order")
        let stranger = f.record(UUID().uuidString, title: "Loading states")
        try await f.load([moved, continued, stranger])
        let runDirectory = f.root.appendingPathComponent("run")
        let tasks = TaskBindings(store: TaskStore(directory: f.root.appendingPathComponent("tasks"), trash: { _ in }),
                                 pointers: MemoryPointers(), notificationCenter: NotificationCenter(),
                                 folderChanges: { _, _ in NSObject() })
        let sessions = BackgroundSessions()
        sessions.name(continued.key.nativeID, "Photo order")
        sessions.name(stranger.key.nativeID, "Loading states")
        let root = f.root.path
        let view = ClaudeAgentView(library: f.library, taskBindings: tasks, socketPath: "/tmp/lightty-test.sock",
                                   runDirectory: runDirectory, liveSessions: { _ in sessions.rows(cwd: root) })
        view.start()
        defer { view.stop() }
        func shown(_ pane: UUID) -> String? { f.library.paneState(for: pane)?.sessionKey?.nativeID }

        // 重启后恢复出来的 pane 还关联着已被转到后台的旧会话：第一条标题就跟上新会话，任务留着。
        let restored = f.pane()
        f.library.associate(.attached(f.association(moved)), with: restored)
        tasks.bind(restored, to: f.root.appendingPathComponent("tasks/photo.md"), name: "photo")
        f.library.noteTerminalTitle("\u{2733} Photo order", in: restored)
        try await f.wait { shown(restored) == continued.key.nativeID }
        #expect(AgentSessionRoute.read(sessionID: continued.key.nativeID, in: runDirectory)?.pane == restored)
        #expect(tasks.task(for: restored) != nil)

        // 列表标题换成了认不出来的写法：不当列表，但下一条会话标题照样重新核对。
        f.library.noteTerminalTitle("Agents \u{2014} 2 waiting", in: restored)
        f.library.noteTerminalTitle("\u{2733} Loading states", in: restored)
        try await f.wait { shown(restored) == stranger.key.nativeID }

        // 没关联任何会话、也没见过列表的 pane：一段同名的后台会话不足以说明它连着那段。
        let unbound = f.pane()
        f.library.noteTerminalTitle("\u{2733} Photo order", in: unbound)
        try await f.wait { sessions.completed == 3 }
        await awaitMainQueue(hops: 2)
        #expect(shown(unbound) == nil)
    }
}
