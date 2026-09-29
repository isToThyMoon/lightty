import Foundation
import LighttyCore
import Testing
@testable import lightty

private final class MemoryPointers: TaskPointerStore {
    func write(taskFile: URL, for pane: UUID) {}
    func clear(for pane: UUID) {}
}

/// `claude agents --json` 的替身：后台会话的名字可以改、可以晚一步出现，某个名字的查询可以被扣住。
/// 查询跑在 `ClaudeAgentView` 自己的队列上，所以状态都加锁。
private final class BackgroundSessions: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String: String] = [:]
    private var answered = 0
    private var asked = 0
    private var held: String?
    private let release = DispatchSemaphore(value: 0)

    func name(_ session: String, _ name: String) { lock.withLock { names[session] = name } }
    func hold(_ name: String) { lock.withLock { held = name } }
    func releaseHeld() { release.signal() }
    var queries: Int { lock.withLock { asked } }
    var completed: Int { lock.withLock { answered } }

    func rows(cwd: String) -> [ClaudeSessionProvider.LiveSession] {
        let (snapshot, hold) = lock.withLock { () -> ([String: String], String?) in
            asked += 1
            return (names, held)
        }
        if let hold, snapshot.values.contains(hold) { release.wait() }
        defer { lock.withLock { answered += 1; held = nil } }
        return snapshot.map { .init(pid: 40, sessionID: $0.key, cwd: cwd, isBackground: true, name: $0.value) }
    }
}

@MainActor
struct ClaudeAgentViewTests {
    /// pane 跟着 agent view 里显示的会话走，只凭终端标题和 `claude agents --json`（2026-09-29 实测：
    /// 列表的标题是 `claude agents`，连上一段后台会话后是 `<前缀> <会话名>`）。
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
        sessions.name(continued.key.nativeID, "Emby player")
        sessions.name(other.key.nativeID, "Loading states")
        let root = f.root.path
        let view = ClaudeAgentView(library: f.library, taskBindings: tasks, socketPath: "/tmp/lightty-test.sock",
                                   runDirectory: runDirectory) { _ in sessions.rows(cwd: root) }
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

        // 前台会话自己的标题：不查任何东西（没装 hook、还没关联上时也一样）。
        title("\u{2733} Emby player")
        await awaitMainQueue(hops: 2)
        #expect(sessions.queries == 0)

        // ← 转到后台、停在列表：pane 不再显示哪段会话，任务还在。
        title("claude agents")
        try await f.wait { shown(pane) == nil }
        #expect(tasks.task(for: pane) != nil)

        // 连回被转到后台的同一段对话（新会话 ID、同名）：路由送进这个 pane，任务留着。
        title("\u{25D0} Emby player")
        try await f.wait { shown(pane) == continued.key.nativeID }
        #expect(route(continued)?.pane == pane)
        #expect(tasks.task(for: pane) != nil, "同一段对话换了个后台会话 ID，任务不该丢")
        title("\u{25D1} Emby player")
        await awaitMainQueue(hops: 2)
        #expect(sessions.queries == 1, "转圈时同一个名字只查一次")

        // 连着的时候改了名：再回列表、再连回来，还是同一段对话。
        sessions.name(continued.key.nativeID, "Emby player v2")
        title("\u{2733} Emby player v2")
        try await f.wait { sessions.completed == 2 }
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
        try await f.wait { sessions.completed == 4 }
        await awaitMainQueue(hops: 2)
        #expect(shown(pane) == nil)
        #expect(route(other) == nil)

        // 刚派出的会话还没进 `claude agents --json`：没查到；回列表再连时重新查。
        title("\u{2733} Fresh")
        try await f.wait { sessions.completed == 5 }
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
}
