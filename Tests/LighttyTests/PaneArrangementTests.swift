import AppKit
import XCTest
@testable import lightty

/// 控制器改 pane 树的唯一通路（算好新编排 → 校验 → 一次性提交）在真实窗口里的表现。
///
/// 背景：以前 pane 树直接是 NSSplitView 层级，合并再拆出时 AppKit 的约束求解器会抛
/// NSInternalInconsistencyException，树停在改到一半的样子，拖拽卡片也被甩在屏幕上。
/// 下面第一条就是当时稳定复现的现场。
@MainActor
final class PaneArrangementTests: XCTestCase {
    private var directory: URL!
    private var controllers: [TerminalWindowController] = []

    override func setUp() {
        _ = NSApplication.shared
        if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        AppState.shared = AppState(taskDirectory: directory, sweepStalePanes: false)
    }

    override func tearDown() {
        controllers.forEach { $0.window?.close() }
        controllers = []
        AppState.shared.windowControllers = []
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeController(extraTabs: Int = 0) -> TerminalWindowController {
        let controller = TerminalWindowController()
        controllers.append(controller)
        AppState.shared.windowControllers = controllers
        for _ in 0..<extraTabs { controller.addTab(initialPane: PaneView()) }
        return controller
    }

    private func spin(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// 每次操作之后都必须成立的不变量：模型里的每个 pane 恰好出现一次，视图就挂在
    /// 它所属标签页的容器里，没有挂错、挂丢或重复。
    private func assertConsistent(_ controller: TerminalWindowController,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let overview = controller.tabOverview()
        let listed = overview.flatMap(\.panes)
        XCTAssertEqual(Set(listed.map(\.dragIdentifier)).count, listed.count, "pane 重复出现", file: file, line: line)
        XCTAssertEqual(listed.map(\.dragIdentifier), controller.panes().map(\.dragIdentifier), file: file, line: line)
        for entry in overview {
            XCTAssertFalse(entry.panes.isEmpty, "不该留下空标签页", file: file, line: line)
            let containers = Set(entry.panes.map { $0.superview.map(ObjectIdentifier.init) })
            XCTAssertEqual(containers.count, 1, "同一标签页的 pane 要在同一个容器里", file: file, line: line)
            for pane in entry.panes {
                XCTAssertTrue(pane.superview is PaneLayoutView, "pane 必须挂在标签页容器上", file: file, line: line)
                XCTAssertTrue(pane.window === controller.window, "pane 必须在本窗口里", file: file, line: line)
            }
        }
    }

    // MARK: - 当时的现场

    func testMergingThenDetachingWithTheSidebarOpenNoLongerBreaksLayout() throws {
        let controller = makeController(extraTabs: 2)
        let a = PaneView(); controller.addTab(initialPane: a)
        let b = PaneView(); controller.addTab(initialPane: b)
        controller.openTabSidebar(animated: false)
        spin()

        XCTAssertTrue(controller.movePane(withID: a.dragIdentifier, to: b, zone: .right))
        spin(0.4)
        assertConsistent(controller)
        XCTAssertEqual(controller.tabOverview().map(\.panes.count), [1, 1, 1, 2])

        XCTAssertTrue(controller.detachPane(withID: a.dragIdentifier, toNewTabAt: 0))
        assertConsistent(controller)
        XCTAssertEqual(controller.tabOverview().map(\.panes.count), [1, 1, 1, 1, 1])
        XCTAssertEqual(controller.tabOverview().first?.panes.first, a)
    }

    func testRepeatedRestructuringAcrossConfigurationsKeepsTheTreeWhole() throws {
        for extra in [0, 2, 4] {
            for sidebar in [false, true] {
                let controller = makeController(extraTabs: extra)
                if sidebar { controller.openTabSidebar(animated: false) }
                let a = PaneView(); controller.addTab(initialPane: a)
                let b = PaneView(); controller.addTab(initialPane: b)
                spin(0.1)
                for round in 0..<3 {
                    XCTAssertTrue(controller.movePane(withID: a.dragIdentifier, to: b, zone: round % 2 == 0 ? .right : .bottom))
                    spin(0.05)
                    assertConsistent(controller)
                    controller.split(b, direction: .down)
                    assertConsistent(controller)
                    XCTAssertTrue(controller.detachPane(withID: a.dragIdentifier, toNewTabAt: round))
                    assertConsistent(controller)
                    XCTAssertTrue(controller.moveTab(from: 0, to: controller.tabCount - 1))
                    assertConsistent(controller)
                    if let extraPane = controller.panes().first(where: {
                        $0 !== a && $0 !== b && controller.tabName(of: $0) == controller.tabName(of: b)
                    }) {
                        controller.close(pane: extraPane)
                        assertConsistent(controller)
                    }
                }
            }
        }
    }

    // MARK: - 事务性

    func testRejectedCommandsLeaveEverythingUntouched() throws {
        let controller = makeController()
        let only = try XCTUnwrap(controller.activePane)
        let other = PaneView(); controller.addTab(initialPane: other)
        let before = controller.tabOverview().map { ($0.id, $0.panes.map(\.dragIdentifier)) }

        XCTAssertFalse(controller.movePane(withID: only.dragIdentifier, to: only, zone: .right))
        XCTAssertFalse(controller.movePane(withID: UUID(), to: other, zone: .right), "源 pane 不存在")
        XCTAssertFalse(controller.movePane(withID: only.dragIdentifier, toTabAt: 9))
        XCTAssertFalse(controller.movePane(withID: only.dragIdentifier, toTabAt: 0), "本来就独占这个标签页")
        XCTAssertFalse(controller.detachPane(withID: only.dragIdentifier, toNewTabAt: 1), "独占标签页拆不出东西")
        XCTAssertFalse(controller.moveTab(from: 1, to: 1))

        let after = controller.tabOverview().map { ($0.id, $0.panes.map(\.dragIdentifier)) }
        XCTAssertEqual(after.map(\.0), before.map(\.0))
        XCTAssertEqual(after.map(\.1), before.map(\.1))
        assertConsistent(controller)
    }

    func testMovingAcrossWindowsHandsTheViewOverInOneStep() throws {
        let source = makeController()
        let destination = makeController()
        let moved = try XCTUnwrap(source.activePane)
        let anchor = try XCTUnwrap(destination.activePane)

        XCTAssertTrue(destination.movePane(withID: moved.dragIdentifier, to: anchor, zone: .right))
        XCTAssertEqual(source.tabCount, 0, "源窗口移空进空态")
        XCTAssertTrue(source.panes().isEmpty)
        XCTAssertEqual(destination.tabOverview().map { $0.panes.map(\.dragIdentifier) },
                       [[anchor.dragIdentifier, moved.dragIdentifier]])
        XCTAssertTrue(moved.window === destination.window)
        assertConsistent(destination)
    }

    // MARK: - 撤销

    func testUndoRestoresTheArrangementAndRedoReappliesIt() throws {
        let controller = makeController()
        let a = try XCTUnwrap(controller.activePane)
        controller.split(a, direction: .right)
        let b = try XCTUnwrap(controller.panes().first { $0 !== a })
        let undo = try XCTUnwrap(controller.window?.undoManager)
        undo.removeAllActions()
        let split = controller.tabOverview().map { $0.panes.map(\.dragIdentifier) }

        XCTAssertTrue(controller.detachPane(withID: b.dragIdentifier, toNewTabAt: 1))
        let detached = controller.tabOverview().map { $0.panes.map(\.dragIdentifier) }
        XCTAssertEqual(detached, [[a.dragIdentifier], [b.dragIdentifier]])

        undo.undo()
        XCTAssertEqual(controller.tabOverview().map { $0.panes.map(\.dragIdentifier) }, split)
        assertConsistent(controller)
        undo.redo()
        XCTAssertEqual(controller.tabOverview().map { $0.panes.map(\.dragIdentifier) }, detached)
        assertConsistent(controller)
    }

    func testUndoIsVoidOnceThePaneSetChanged() throws {
        let controller = makeController()
        let a = try XCTUnwrap(controller.activePane)
        controller.split(a, direction: .right)
        let b = try XCTUnwrap(controller.panes().first { $0 !== a })
        let undo = try XCTUnwrap(controller.window?.undoManager)
        undo.removeAllActions()

        XCTAssertTrue(controller.detachPane(withID: b.dragIdentifier, toNewTabAt: 1))
        controller.split(a, direction: .down)  // 新建了一个 pane：旧编排里没有它
        let now = controller.tabOverview().map { $0.panes.map(\.dragIdentifier) }
        undo.undo()
        XCTAssertEqual(controller.tabOverview().map { $0.panes.map(\.dragIdentifier) }, now,
                       "按旧编排恢复会把新 pane 挤掉，这种撤销必须作废")
        assertConsistent(controller)
    }

    // MARK: - 放大、尺寸、快照、焦点

    func testZoomHidesSiblingsUntilTheTreeChanges() throws {
        let controller = makeController()
        let a = try XCTUnwrap(controller.activePane)
        controller.split(a, direction: .right)
        let b = try XCTUnwrap(controller.panes().first { $0 !== a })
        controller.window?.contentView?.layoutSubtreeIfNeeded()

        XCTAssertTrue(controller.toggleSplitZoom(a))
        XCTAssertTrue(b.isHidden)
        XCTAssertEqual(a.frame, a.superview?.bounds)

        controller.split(a, direction: .down)  // 树变了：放大态失效
        XCTAssertFalse(b.isHidden)
        assertConsistent(controller)
    }

    func testSnapshotsCarryExactProportionsThroughARestore() throws {
        let controller = makeController()
        let a = try XCTUnwrap(controller.activePane)
        controller.split(a, direction: .right)
        let host = try XCTUnwrap(controller.window?.contentView)
        host.layoutSubtreeIfNeeded()
        let container = try XCTUnwrap(a.superview as? PaneLayoutView)
        let divider = try XCTUnwrap(container.subviews.compactMap { $0 as? PaneDividerView }.first { !$0.isHidden })
        divider.onDrag?(container.bounds.width * 0.3)

        let snapshot = try XCTUnwrap(controller.snapshot())
        guard case .split(true, let fractions, _) = snapshot.tabs[0].root else { return XCTFail("应是左右分屏") }
        let restored = TerminalWindowController(restoring: snapshot)
        controllers.append(restored)
        let again = try XCTUnwrap(restored.snapshot())
        guard case .split(true, let restoredFractions, _) = again.tabs[0].root else { return XCTFail("恢复后应仍是左右分屏") }
        XCTAssertEqual(restoredFractions, fractions, "比例存在模型里，恢复不再从视图尺寸反算")
        XCTAssertEqual(fractions[0], 0.3, accuracy: 0.01)
    }

    func testDirectionalFocusReadsTopAndBottomInWindowCoordinates() throws {
        let controller = makeController()
        let top = try XCTUnwrap(controller.activePane)
        controller.split(top, direction: .down)
        let bottom = try XCTUnwrap(controller.panes().first { $0 !== top })
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertLessThan(top.frame.maxY, bottom.frame.minY, "flipped 容器里上面的 pane y 更小")

        bottom.focusTerminal()
        controller.focusPane(direction: .top)
        XCTAssertTrue(controller.activePane === top, "容器 flipped 之后上下不能反")
    }
}
