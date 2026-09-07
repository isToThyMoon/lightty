import AppKit
import XCTest
@testable import lightty

@MainActor
final class SessionSnapshotTests: XCTestCase {
    func testSnapshotCodableRoundTrip() throws {
        let pane = PaneSnapshot(
            name: "api", workingDirectory: "/tmp", taskFile: "/tmp/t.md",
            agent: "claude", sessionID: "abc-123", agentCWD: "/tmp/proj", agentAlive: true)
        let tree = SplitNodeSnapshot.split(
            vertical: true, fractions: [0.3, 0.7],
            children: [
                .pane(pane),
                .split(vertical: false, fractions: [0.5, 0.5],
                       children: [.pane(pane), .pane(pane)]),
            ])
        let snapshot = SessionSnapshot(windows: [
            WindowSnapshot(
                frame: CGRect(x: 10, y: 20, width: 800, height: 600),
                activeTabIndex: 1,
                tabs: [TabSnapshot(title: "A", root: .pane(pane)), TabSnapshot(title: "B", root: tree)],
                taskPanelOpen: false, tabSidebarOpen: true),
        ])
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(tree.leaves.count, 3)
        XCTAssertEqual(tree.firstLeaf.name, "api")
    }

    func testStoreRejectsUnknownVersionAndPersistsFreeze() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(fileURL: dir.appendingPathComponent("session.json"))
        XCTAssertNil(store.load())

        var snapshot = SessionSnapshot(windows: [])
        store.write(snapshot)
        XCTAssertEqual(store.load(), snapshot)

        snapshot.version = 99
        store.write(snapshot)
        XCTAssertNil(store.load(), "未知版本整体丢弃")

        store.freeze(with: SessionSnapshot(windows: []))
        XCTAssertTrue(store.frozen)
    }

    func testAgentResumeCommands() {
        XCTAssertEqual(
            AgentResume.command(agent: "claude", sessionID: "0f1e-2d3c", alive: true),
            "claude --resume 0f1e-2d3c\n")
        XCTAssertEqual(
            AgentResume.command(agent: "codex", sessionID: "thread_1", alive: true),
            "codex resume thread_1\n")
        XCTAssertNil(AgentResume.command(agent: "claude", sessionID: "x", alive: false), "SessionEnd 后不恢复")
        XCTAssertNil(AgentResume.command(agent: "gemini", sessionID: "x", alive: true), "不认识的 agent")
        XCTAssertNil(AgentResume.command(agent: "claude", sessionID: nil, alive: true))
        XCTAssertNil(
            AgentResume.command(agent: "claude", sessionID: "x; rm -rf ~", alive: true),
            "会话 id 进 shell 前必须白名单")
    }

    /// 真窗口：建两个标签页、一处分屏、改名 → 快照 → 按快照重建 → 再快照，结构与命名一致。
    func testControllerSnapshotRestoreRoundTrip() throws {
        let taskDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("session-controller-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: taskDirectory) }
        _ = NSApplication.shared
        AppState.shared = AppState(taskDirectory: taskDirectory, sweepStalePanes: false)
        if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }

        let controller = TerminalWindowController()
        AppState.shared.windowControllers.append(controller)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let first = try XCTUnwrap(controller.panes().first)
        first.header.title = "编译"
        controller.split(first, direction: .right)
        let second = try XCTUnwrap(controller.panes().last)
        second.header.title = "日志"
        controller.renameTab(at: 0, to: "后端")
        controller.addTab(initialPane: PaneView())
        controller.renameTab(at: 1, to: "前端")
        controller.selectTab(at: 0)
        controller.window?.contentView?.superview?.layoutSubtreeIfNeeded()

        let snapshot = try XCTUnwrap(controller.snapshot())
        XCTAssertEqual(snapshot.tabs.map(\.title), ["后端", "前端"])
        XCTAssertEqual(snapshot.activeTabIndex, 0)
        guard case .split(let vertical, let fractions, let children) = snapshot.tabs[0].root else {
            return XCTFail("标签页 0 应是左右分屏")
        }
        XCTAssertTrue(vertical)
        XCTAssertEqual(fractions.count, 2)
        XCTAssertEqual(children.map(\.firstLeaf.name), ["编译", "日志"])

        let restored = TerminalWindowController(restoring: snapshot)
        AppState.shared.windowControllers.append(restored)
        restored.window?.contentView?.superview?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let again = try XCTUnwrap(restored.snapshot())
        XCTAssertEqual(again.tabs.map(\.title), snapshot.tabs.map(\.title))
        XCTAssertEqual(again.activeTabIndex, 0)
        XCTAssertEqual(
            again.tabs.map { $0.root.leaves.map(\.name) },
            snapshot.tabs.map { $0.root.leaves.map(\.name) })
        guard case .split(let v2, _, _) = again.tabs[0].root else {
            return XCTFail("恢复后标签页 0 应仍是分屏")
        }
        XCTAssertTrue(v2)
        XCTAssertTrue(restored.suppressesInitialSize)

        AppState.shared.windowControllers.removeAll()
    }
}
