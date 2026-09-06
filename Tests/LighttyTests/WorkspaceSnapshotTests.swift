import AppKit
import XCTest
import LighttyCore
@testable import lightty

@MainActor
final class WorkspaceSnapshotTests: XCTestCase {
    func testCatalogConfigurationProvenanceSurvivesSnapshot() throws {
        for location: SessionConfigurationLocation in [.standard, .custom("/fixture/.claude")] {
            let snapshot = PaneSnapshot(name: "fixture", agentAlive: true,
                catalogSession: .init(agent: .claude, sourceRoot: "/fixture/.claude", nativeID: "abc-123"),
                catalogConfiguration: location)
            let restored = try JSONDecoder().decode(PaneSnapshot.self, from: JSONEncoder().encode(snapshot))
            XCTAssertEqual(restored, snapshot)
        }
    }

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
        let snapshot = WorkspaceSnapshot(windows: [
            WindowSnapshot(
                frame: CGRect(x: 10, y: 20, width: 800, height: 600),
                activeTabIndex: 1,
                tabs: [TabSnapshot(title: "A", root: .pane(pane)), TabSnapshot(title: "B", root: tree)],
                taskPanelOpen: false, tabSidebarOpen: true),
        ])
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(tree.leaves.count, 3)
        XCTAssertEqual(tree.firstLeaf.name, "api")
    }

    func testStoreRejectsUnknownVersionAndPersistsFreeze() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WorkspaceStore(fileURL: dir.appendingPathComponent("workspace.json"))
        XCTAssertNil(store.load())

        var snapshot = WorkspaceSnapshot(windows: [])
        store.write(snapshot)
        XCTAssertEqual(store.load(), snapshot)

        snapshot.version = 99
        try JSONEncoder().encode(snapshot).write(to: store.fileURL)
        XCTAssertNil(store.load(), "未知版本整体丢弃")

        store.freeze(with: WorkspaceSnapshot(windows: []))
        XCTAssertTrue(store.frozen)
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
        first.rename(to: "编译")
        controller.split(first, direction: .right)
        let second = try XCTUnwrap(controller.panes().last)
        second.rename(to: "日志")
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

    /// 最复杂场景：两个窗口、各两个标签页、**非活跃**标签页里有嵌套分屏（左右套上下），
    /// 整体快照 → 整体恢复 → 再快照，结构、命名、活跃标签页逐窗一致；恢复后新建 pane
    /// 的默认名不与恢复出的重名。
    func testMultiWindowNestedSplitsRoundTrip() throws {
        let taskDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("session-multi-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: taskDirectory) }
        _ = NSApplication.shared
        AppState.shared = AppState(taskDirectory: taskDirectory, sweepStalePanes: false)
        if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }

        let a = TerminalWindowController()
        let b = TerminalWindowController()
        AppState.shared.windowControllers = [a, b]
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        // 窗口 A：标签页 0 = [A1 | A2]，标签页 1 = [A3]（活跃）
        let a1 = try XCTUnwrap(a.panes().first)
        a1.rename(to: "A1")
        a.split(a1, direction: .right)
        try XCTUnwrap(a.panes().last).rename(to: "A2")
        a.renameTab(at: 0, to: "A-first")
        let a3 = PaneView()
        a3.rename(to: L("Terminal %d", 40))  // 默认名形态，用来验证计数器接续
        a.addTab(initialPane: a3)
        a.renameTab(at: 1, to: "A-second")

        // 窗口 B：标签页 0 = [B1]（活跃），标签页 1 = [Q1 | (Q2 / Q3)] 收在后台
        try XCTUnwrap(b.panes().first).rename(to: "B1")
        b.renameTab(at: 0, to: "B-first")
        let q1 = PaneView()
        q1.rename(to: "Q1")
        b.addTab(initialPane: q1)
        b.renameTab(at: 1, to: "B-nested")
        b.split(q1, direction: .right)
        let q2 = try XCTUnwrap(b.panes().last)
        q2.rename(to: "Q2")
        b.split(q2, direction: .down)
        try XCTUnwrap(b.panes().last).rename(to: "Q3")
        b.selectTab(at: 0)
        for c in [a, b] { c.window?.contentView?.superview?.layoutSubtreeIfNeeded() }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let snapshot = WorkspaceStore.capture()
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows.map(\.activeTabIndex), [1, 0])
        guard case .split(true, _, let kids) = snapshot.windows[1].tabs[1].root,
              case .split(false, _, let inner) = kids[1] else {
            return XCTFail("后台标签页应是 左右分屏 套 上下分屏")
        }
        XCTAssertEqual(kids[0].firstLeaf.name, "Q1")
        XCTAssertEqual(inner.map(\.firstLeaf.name), ["Q2", "Q3"])

        // 整体恢复到一组新窗口
        let originals = AppState.shared.windowControllers
        AppState.shared.windowControllers.removeAll()
        let restored = WorkspaceRestorer.restore(snapshot)
        XCTAssertEqual(restored.count, 2)
        for c in restored { c.window?.contentView?.superview?.layoutSubtreeIfNeeded() }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        let again = WorkspaceStore.capture()
        XCTAssertEqual(
            again.windows.map { $0.tabs.map(\.title) },
            snapshot.windows.map { $0.tabs.map(\.title) })
        XCTAssertEqual(
            again.windows.map { $0.tabs.map { $0.root.leaves.map(\.name) } },
            snapshot.windows.map { $0.tabs.map { $0.root.leaves.map(\.name) } })
        XCTAssertEqual(again.windows.map(\.activeTabIndex), snapshot.windows.map(\.activeTabIndex))
        guard case .split(true, _, let kids2) = again.windows[1].tabs[1].root,
              case .split(false, _, _) = kids2[1] else {
            return XCTFail("恢复后后台标签页的嵌套分屏应保持")
        }

        // 计数器接续：新 pane 的默认名不撞恢复出的「Terminal 40」
        let fresh = PaneView()
        let existing = Set(snapshot.windows.flatMap { $0.tabs.flatMap { $0.root.leaves.map(\.name) } })
        XCTAssertFalse(existing.contains(fresh.header.title))

        _ = originals
        AppState.shared.windowControllers.removeAll()
    }
}
