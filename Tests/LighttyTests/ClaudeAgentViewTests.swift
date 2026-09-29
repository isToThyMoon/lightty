import Foundation
import LighttyCore
import Testing
@testable import lightty

private final class MemoryPointers: TaskPointerStore {
    func write(taskFile: URL, for pane: UUID) {}
    func clear(for pane: UUID) {}
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
        try await f.load([foreground, continued, other])
        let runDirectory = f.root.appendingPathComponent("run")
        let tasks = TaskBindings(store: TaskStore(directory: f.root.appendingPathComponent("tasks"), trash: { _ in }),
                                 pointers: MemoryPointers(), notificationCenter: NotificationCenter(),
                                 folderChanges: { _, _ in NSObject() })
        var queries = 0
        let view = ClaudeAgentView(library: f.library, taskBindings: tasks, socketPath: "/tmp/lightty-test.sock",
                                   runDirectory: runDirectory) { _ in
            queries += 1
            return [
                .init(pid: 41, sessionID: continued.key.nativeID, cwd: f.root.path, isBackground: true, name: "Emby player"),
                .init(pid: 42, sessionID: other.key.nativeID, cwd: f.root.path, isBackground: true, name: "Loading states"),
            ]
        }
        view.start()
        defer { view.stop() }
        let pane = f.pane()
        f.library.associate(.attached(f.association(foreground)), with: pane)
        tasks.bind(pane, to: f.root.appendingPathComponent("tasks/emby.md"), name: "emby")
        func shown() -> String? { f.library.paneState(for: pane)?.sessionKey?.nativeID }
        func route(_ record: AgentSession) -> AgentSessionRoute? {
            AgentSessionRoute.read(sessionID: record.key.nativeID, in: runDirectory)
        }

        // 前台会话自己的标题：不查任何东西。
        f.library.noteTerminalTitle("\u{2733} Emby player", in: pane)
        await awaitMainQueue(hops: 2)
        #expect(queries == 0)

        // ← 转到后台、停在列表：pane 不再显示哪段会话，任务还在。
        f.library.noteTerminalTitle("claude agents", in: pane)
        try await f.wait { shown() == nil }
        #expect(tasks.task(for: pane) != nil)

        // 连回被转到后台的同一段对话（新会话 ID、同名）：路由送进这个 pane，任务留着。
        f.library.noteTerminalTitle("\u{25D0} Emby player", in: pane)
        try await f.wait { shown() == continued.key.nativeID }
        #expect(route(continued)?.pane == pane)
        #expect(tasks.task(for: pane) != nil, "同一段对话换了个后台会话 ID，任务不该丢")
        f.library.noteTerminalTitle("\u{25D1} Emby player", in: pane)
        await awaitMainQueue(hops: 2)
        #expect(queries == 1, "转圈时同一个名字只查一次")

        // 回列表再连上另一段对话：旧路由撤掉，新的写上，任务解绑。
        f.library.noteTerminalTitle("claude agents", in: pane)
        try await f.wait { route(continued) == nil }
        f.library.noteTerminalTitle("\u{2733} Loading states", in: pane)
        try await f.wait { shown() == other.key.nativeID }
        #expect(route(other)?.pane == pane)
        #expect(tasks.task(for: pane) == nil)
    }
}
