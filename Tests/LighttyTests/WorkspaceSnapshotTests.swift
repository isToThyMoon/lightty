import AppKit
import XCTest
import LighttyCore
@testable import lightty

@MainActor
final class WorkspaceSnapshotTests: XCTestCase {
    /// 整棵 WorkspaceSnapshot 的 Codable 往返，pane 夹具带齐每个字段——
    /// 包括会话关联（catalogSession）与配置来源（standard / custom 两种）。
    func testSnapshotCodableRoundTripCoversEveryField() throws {
        for location: SessionConfigurationLocation in [.standard, .custom("/fixture/.claude")] {
            let pane = PaneSnapshot(
                name: "api", workingDirectory: "/tmp", taskFile: "/tmp/t.md",
                agent: "claude", sessionID: "abc-123", agentCWD: "/tmp/proj", agentAlive: true,
                catalogSession: .init(agent: .claude, sourceRoot: "/fixture/.claude", nativeID: "abc-123"),
                catalogConfiguration: location)
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
            XCTAssertEqual(decoded, snapshot, "\(location)")
            XCTAssertEqual(decoded.windows.first?.tabs.first?.root.firstLeaf.catalogConfiguration, location)
            XCTAssertEqual(tree.leaves.count, 3)
            XCTAssertEqual(tree.firstLeaf.name, "api")
        }
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

    /// 旧快照读入时的默认值：
    /// - 标签页名：新快照显式存「是否改过名」与默认名序号；还没有这两个字段的旧快照
    ///   读入时按旧规则迁移一次。恢复出的默认名序号全局占号，别的窗口新开的标签页不撞名。
    /// - 主侧栏模式：没有这个字段的旧快照解出 nil，恢复时按 Handoff 兼容处理。
    func testLegacyWindowSnapshotsDecodeWithDefaults() throws {
        let taskDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("session-titles-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: taskDirectory) }
        _ = NSApplication.shared
        AppState.shared = AppState(taskDirectory: taskDirectory, sweepStalePanes: false)
        ensureTerminalRuntime()
        defer { AppState.shared.windowControllers.removeAll() }

        // 旧快照：只有 title 字符串，没有 primarySidebarMode。
        let legacy = """
        {"activeTabIndex":0,"taskPanelOpen":false,"tabSidebarOpen":false,"tabs":[
          {"title":"\(L("Tab %d", 5))","root":{"kind":"pane","pane":{"name":"a","agentAlive":false}}},
          {"title":"后端","root":{"kind":"pane","pane":{"name":"b","agentAlive":false}}}]}
        """
        let window = try JSONDecoder().decode(WindowSnapshot.self, from: Data(legacy.utf8))
        XCTAssertNil(window.tabs[0].customTitle)
        XCTAssertNil(window.primarySidebarMode, "旧快照没有主侧栏模式字段，解出 nil 以兼容 Handoff")
        let restored = TerminalWindowController(restoring: window)
        AppState.shared.windowControllers.append(restored)
        XCTAssertEqual(restored.tabOverview().map(\.hasCustomTitle), [false, true])

        let again = try XCTUnwrap(restored.snapshot())
        XCTAssertEqual(again.tabs.map(\.customTitle), [false, true])
        XCTAssertEqual(again.tabs.map(\.titleNumber), [5, nil])
        XCTAssertEqual(again.tabs.map(\.title), [L("Tab %d", 5), "后端"])

        let other = TerminalWindowController()
        AppState.shared.windowControllers.append(other)
        XCTAssertEqual(other.tabOverview().first?.title, L("Tab %d", 6), "恢复出的序号全局占号")
        for controller in [restored, other] { controller.window?.close() }
    }

    /// 最复杂场景：两个窗口、各两个标签页、**非活跃**标签页里有嵌套分屏（左右套上下），
    /// 整体快照 → 整体恢复 → 再快照，结构、命名、活跃标签页逐窗一致；恢复后新建 pane
    /// 的默认名不与恢复出的重名；按快照重建的控制器不再按首帧尺寸重排（`suppressesInitialSize`）。
    func testMultiWindowNestedSplitsRoundTrip() throws {
        let taskDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("session-multi-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: taskDirectory) }
        _ = NSApplication.shared
        AppState.shared = AppState(taskDirectory: taskDirectory, sweepStalePanes: false)
        ensureTerminalRuntime()

        let a = TerminalWindowController()
        let b = TerminalWindowController()
        AppState.shared.windowControllers = [a, b]
        for c in [a, b] { try c.waitForInitialLayout() }

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
        try drainMainQueue()

        let snapshot = WorkspaceStore.capture()
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows.map(\.activeTabIndex), [1, 0])
        XCTAssertEqual(snapshot.windows[0].tabs.map(\.title), ["A-first", "A-second"])
        guard case .split(true, let fractions, let aKids) = snapshot.windows[0].tabs[0].root else {
            return XCTFail("窗口 A 标签页 0 应是左右分屏")
        }
        XCTAssertEqual(fractions.count, 2)
        XCTAssertEqual(aKids.map(\.firstLeaf.name), ["A1", "A2"])
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
        for c in restored { try c.waitForInitialLayout() }
        XCTAssertTrue(restored.allSatisfy(\.suppressesInitialSize), "按快照重建的窗口不按首帧尺寸重排")

        let again = WorkspaceStore.capture()
        XCTAssertEqual(
            again.windows.map { $0.tabs.map(\.title) },
            snapshot.windows.map { $0.tabs.map(\.title) })
        XCTAssertEqual(
            again.windows.map { $0.tabs.map { $0.root.leaves.map(\.name) } },
            snapshot.windows.map { $0.tabs.map { $0.root.leaves.map(\.name) } })
        XCTAssertEqual(again.windows.map(\.activeTabIndex), snapshot.windows.map(\.activeTabIndex))
        guard case .split(true, _, _) = again.windows[0].tabs[0].root else {
            return XCTFail("恢复后窗口 A 标签页 0 应仍是左右分屏")
        }
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
