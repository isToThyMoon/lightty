import AppKit
import XCTest
@testable import lightty

/// 第二侧栏的拖拽有两种意图：落在行与行之间是排序，压在某一行的中央带上是合并。
/// 列表是两级的，排序的落点也分两级：标签页之间（整条标签页换位，或把分屏 pane
/// 拆成新标签页）和某个标签页的 pane 块内（并进那棵分屏树）。
@MainActor
final class TabDragSemanticsTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        _ = NSApplication.shared
        if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        AppState.shared = AppState(taskDirectory: directory, sweepStalePanes: false)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    // MARK: - 落点判定

    private let a = UUID(), b = UUID(), c = UUID()
    private let t0 = UUID(), t1 = UUID(), t2 = UUID()

    func testALeafLandingBetweenTabsIsATopLevelReorder() {
        // [叶子A] [叶子B] [叶子C]，A 拖到最后。
        let rows: [TabRowKind] = [.leaf(tab: 1, pane: b), .leaf(tab: 2, pane: c), .leaf(tab: 0, pane: a)]
        XCTAssertEqual(TabColumnView.dropSlot(in: rows, sourceIndex: 2), .betweenTabs(2))
        XCTAssertEqual(
            TabColumnView.dropSlot(in: [.leaf(tab: 0, pane: a), .leaf(tab: 1, pane: b)], sourceIndex: 0),
            .betweenTabs(0), "拖回原位也要算得出原位次，才判得了空动")
    }

    func testALeafLandingInsideAnExpandedTabJoinsThatSplitTree() {
        // [容器] [pane b] [叶子A] [pane c]：A 落在 b 与 c 之间，也就是容器标签页块内。
        let rows: [TabRowKind] = [
            .tab(index: 0, id: t0), .pane(tab: 0, pane: b), .leaf(tab: 1, pane: a), .pane(tab: 0, pane: c),
        ]
        XCTAssertEqual(TabColumnView.dropSlot(in: rows, sourceIndex: 2), .insideTab(next: c, previous: nil))
    }

    func testAPaneLandingAtATopLevelSlotBecomesItsOwnTab() {
        // [叶子B] [pane a] [叶子C]：a 落在两条叶子之间 = 顶层位，不该再并进谁。
        let rows: [TabRowKind] = [.leaf(tab: 0, pane: b), .pane(tab: 1, pane: a), .leaf(tab: 2, pane: c)]
        XCTAssertEqual(TabColumnView.dropSlot(in: rows, sourceIndex: 1), .betweenTabs(1))
    }

    func testAPaneStaysInItsTabWhenItLandsAtTheEndOfThatTabsBlock() {
        // [容器] [pane b] [pane a] [叶子C]：a 在块尾，上方紧邻仍是同块的 pane。
        let rows: [TabRowKind] = [
            .tab(index: 0, id: t0), .pane(tab: 0, pane: b), .pane(tab: 0, pane: a), .leaf(tab: 1, pane: c),
        ]
        XCTAssertEqual(TabColumnView.dropSlot(in: rows, sourceIndex: 2), .insideTab(next: nil, previous: b))
    }

    func testACollapsedTabIsOpaqueSoTheSlotUnderItIsATopLevelSlot() {
        // 折叠的标签页在列表里只有一行，它下面那一格属于标签页之间。
        let rows: [TabRowKind] = [.tab(index: 0, id: t0), .leaf(tab: 1, pane: a)]
        XCTAssertEqual(TabColumnView.dropSlot(in: rows, sourceIndex: 1), .betweenTabs(1))
    }

    func testTopLevelIndexCountsTabsNotRows() {
        // [容器0] [pane] [pane] [叶子1] [容器2]
        let rows: [TabRowKind] = [
            .tab(index: 0, id: t0), .pane(tab: 0, pane: a), .pane(tab: 0, pane: b), .leaf(tab: 1, pane: c), .tab(index: 2, id: t2),
        ]
        XCTAssertEqual(TabColumnView.topLevelIndex(in: rows, before: 0), 0)
        XCTAssertEqual(TabColumnView.topLevelIndex(in: rows, before: 2), 1, "块内的 pane 行不计位次")
        XCTAssertEqual(TabColumnView.topLevelIndex(in: rows, before: 3), 1)
        XCTAssertEqual(TabColumnView.topLevelIndex(in: rows, before: 4), 2)
        XCTAssertEqual(TabColumnView.topLevelIndex(in: rows, before: rows.count), 3)
    }

    // MARK: - 落点对应的真实移动

    func testMovingATabKeepsTheSelectionOnTheSameTab() throws {
        let controller = TerminalWindowController()
        defer { controller.window?.close() }
        let first = try XCTUnwrap(controller.activePane)
        controller.addTab(initialPane: PaneView())
        controller.addTab(initialPane: PaneView())
        controller.selectTab(at: 0)
        let titles = controller.tabOverview().map(\.title)
        XCTAssertEqual(controller.tabOverview().first(where: \.isActive)?.title, titles[0])

        XCTAssertTrue(controller.moveTab(from: 0, to: 2))
        XCTAssertEqual(controller.tabOverview().map(\.title), [titles[1], titles[2], titles[0]])
        XCTAssertEqual(controller.tabOverview().first(where: \.isActive)?.title, titles[0],
                       "重排不该顺手换走当前上下文")
        XCTAssertTrue(controller.panes().contains { $0 === first })
        XCTAssertFalse(controller.moveTab(from: 2, to: 2), "原地不动不算一次移动")
    }

    func testDetachingAPaneMakesANewTabAtThatPosition() throws {
        let controller = TerminalWindowController()
        defer { controller.window?.close() }
        let first = try XCTUnwrap(controller.activePane)
        controller.addTab(initialPane: PaneView())
        controller.selectTab(at: 0)
        controller.split(first, direction: .right)
        let extra = try XCTUnwrap(controller.panes().first { $0 !== first })
        XCTAssertEqual(controller.tabOverview().count, 2)

        XCTAssertTrue(controller.detachPane(withID: extra.dragIdentifier, toNewTabAt: 0))
        let overview = controller.tabOverview()
        XCTAssertEqual(overview.count, 3)
        XCTAssertEqual(overview[0].panes.map(\.dragIdentifier), [extra.dragIdentifier],
                       "拆出来的 pane 要独占插入位上的新标签页")
        XCTAssertEqual(overview[1].panes.map(\.dragIdentifier), [first.dragIdentifier])
    }

    func testAPaneThatAlreadyOwnsItsTabHasNothingToDetach() throws {
        let controller = TerminalWindowController()
        defer { controller.window?.close() }
        let only = try XCTUnwrap(controller.activePane)
        XCTAssertFalse(controller.detachPane(withID: only.dragIdentifier, toNewTabAt: 0),
                       "单 pane 标签页拆不出东西，这种落点该走 moveTab")
        XCTAssertEqual(controller.tabOverview().count, 1)
    }

    // MARK: - 显示行推导与命令映射

    func testTheSessionOnlyReordersTheDisplayNeverTheModel() {
        let rows: [TabRowKind] = [.leaf(tab: 0, pane: a), .leaf(tab: 1, pane: b), .leaf(tab: 2, pane: c)]
        XCTAssertEqual(TabColumnView.arrangement(of: rows, source: .pane(a), insertion: nil), [0, 1, 2],
                       "还没离开原位")
        XCTAssertEqual(TabColumnView.arrangement(of: rows, source: .pane(a), insertion: 2), [1, 2, 0])
        XCTAssertEqual(TabColumnView.arrangement(of: rows, source: .pane(UUID()), insertion: 0), [0, 1, 2],
                       "源行已经不在模型里（被关掉）：显示回到模型原样")
        let tabs: [TabRowKind] = [.tab(index: 0, id: t0), .leaf(tab: 1, pane: a)]
        XCTAssertEqual(TabColumnView.arrangement(of: tabs, source: .tab(t0), insertion: 1), [1, 0])
    }

    func testDropsTranslateIntoControllerCommands() {
        // 叶子行落在标签页之间 = 换位次；分屏 pane 落在标签页之间 = 拆成新标签页
        XCTAssertEqual(TabColumnView.dropCommand(
            rows: [.leaf(tab: 1, pane: b), .leaf(tab: 0, pane: a)], sourceIndex: 1, merge: nil),
            .moveTab(from: 0, to: 1))
        XCTAssertEqual(TabColumnView.dropCommand(
            rows: [.pane(tab: 1, pane: a), .leaf(tab: 0, pane: b)], sourceIndex: 0, merge: nil),
            .detachPane(a, toNewTabAt: 0))
        // 落在块内：插到下一个 pane 左侧，没有下一个就插到上一个右侧
        XCTAssertEqual(TabColumnView.dropCommand(
            rows: [.tab(index: 0, id: t0), .leaf(tab: 1, pane: a), .pane(tab: 0, pane: c)], sourceIndex: 1, merge: nil),
            .movePaneBeside(a, target: c, zone: .left))
        XCTAssertEqual(TabColumnView.dropCommand(
            rows: [.tab(index: 0, id: t0), .pane(tab: 0, pane: c), .leaf(tab: 1, pane: a)], sourceIndex: 2, merge: nil),
            .movePaneBeside(a, target: c, zone: .right))
        // 合并优先
        XCTAssertEqual(TabColumnView.dropCommand(
            rows: [.leaf(tab: 0, pane: a), .tab(index: 1, id: t1)], sourceIndex: 0, merge: .tab(index: 1, id: t1)),
            .movePaneIntoTab(a, tabIndex: 1))
        XCTAssertEqual(TabColumnView.dropCommand(
            rows: [.leaf(tab: 0, pane: a), .leaf(tab: 1, pane: b)], sourceIndex: 0, merge: .leaf(tab: 1, pane: b)),
            .movePaneBeside(a, target: b, zone: .right))
        // 容器行只排序，合并目标对它无效
        XCTAssertEqual(TabColumnView.dropCommand(
            rows: [.leaf(tab: 1, pane: a), .tab(index: 0, id: t0)], sourceIndex: 1, merge: .leaf(tab: 1, pane: a)),
            .moveTab(from: 0, to: 1))
    }

    // MARK: - 拖拽会话

    private func mountedColumn(_ controller: TerminalWindowController) throws -> (TabColumnView, NSTableView) {
        let window = try XCTUnwrap(controller.window)
        let column = TabColumnView()
        try XCTUnwrap(window.contentView).addSubview(column)
        column.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        column.reload()
        column.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(descendants(column).compactMap { $0 as? NSTableView }.first)
        table.layoutSubtreeIfNeeded()
        return (column, table)
    }

    /// 行与行之间的缝（self 坐标），避开中央合并带。
    private func gap(below row: Int, in column: TabColumnView, table: NSTableView) -> NSPoint {
        let rect = column.convert(table.rect(ofRow: row), from: table)
        return NSPoint(x: rect.midX, y: rect.minY - 1)
    }

    /// 等松手后投递到下一拍的命令执行完。用挂起而不是转事件循环：同步测试若本身
    /// 跑在主队列的块里，嵌套转事件循环不会执行主队列里排着的块。
    private func settle() async {
        for _ in 0..<5 { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    func testAReloadInTheMiddleOfADragNoLongerCancelsIt() async throws {
        let controller = TerminalWindowController()
        AppState.shared.windowControllers = [controller]
        defer { controller.window?.close(); AppState.shared.windowControllers = [] }
        let first = try XCTUnwrap(controller.activePane)
        controller.addTab(initialPane: PaneView())
        controller.split(first, direction: .right)   // 标签页 0 展开成容器 + 两条 pane 行
        let extra = try XCTUnwrap(controller.panes().first {
            $0 !== first && controller.tabName(of: $0) == controller.tabName(of: first)
        })
        let (column, table) = try mountedColumn(controller)
        XCTAssertEqual(column.displayedRows.count, 4)

        XCTAssertTrue(column.startDrag(source: .pane(extra.dragIdentifier), card: NSView()))
        // 拖到最末那条叶子行下面：标签页之间 = 拆成新标签页
        column.moveDrag(to: gap(below: 3, in: column, table: table))
        let proposed = column.displayedRows
        XCTAssertTrue(TabColumnView.matches(proposed.last!, .pane(extra.dragIdentifier)))

        // 途中来一次整表刷新（agent 状态、任务通知都会触发）：拖拽不能被打断
        column.reload()
        XCTAssertEqual(column.displayedRows, proposed, "刷新只是重新推导，源行留在提议的位置")

        column.finishDrag()
        XCTAssertEqual(controller.tabOverview().map(\.panes.count), [2, 1], "命令在下一拍执行，不在跟踪循环里")
        await settle()
        XCTAssertEqual(controller.tabOverview().map(\.panes.count), [1, 1, 1])
        XCTAssertEqual(controller.tabOverview().last?.panes.first, extra)
    }

    func testDroppingBackWhereItStartedChangesNothing() async throws {
        let controller = TerminalWindowController()
        AppState.shared.windowControllers = [controller]
        defer { controller.window?.close(); AppState.shared.windowControllers = [] }
        controller.addTab(initialPane: PaneView())
        let (column, _) = try mountedColumn(controller)
        let before = controller.tabOverview().map(\.id)
        let source = try XCTUnwrap(controller.tabOverview().first?.panes.first)

        XCTAssertTrue(column.startDrag(source: .pane(source.dragIdentifier), card: NSView()))
        column.finishDrag()
        await settle()
        XCTAssertEqual(controller.tabOverview().map(\.id), before)
        XCTAssertFalse(column.startDrag(source: .pane(UUID()), card: NSView()), "源行不存在不能开始")
    }

    func testDraggingAnExpandedTabCollapsesItOnlyForTheDrag() async throws {
        let controller = TerminalWindowController()
        AppState.shared.windowControllers = [controller]
        defer { controller.window?.close(); AppState.shared.windowControllers = [] }
        let first = try XCTUnwrap(controller.activePane)
        controller.split(first, direction: .right)   // 标签页 0：两个 pane，展开着
        controller.addTab(initialPane: PaneView())   // 标签页 1：叶子行
        let (column, table) = try mountedColumn(controller)
        XCTAssertEqual(column.displayedRows.count, 4, "容器行 + 两条 pane 行 + 一条叶子行")
        let tabID = try XCTUnwrap(controller.tabOverview().first?.id)

        XCTAssertTrue(column.startDrag(source: .tab(tabID), card: NSView()))
        XCTAssertEqual(column.displayedRows.count, 2, "拖动期间多 pane 标签页收成一行")
        column.reload()
        XCTAssertEqual(column.displayedRows.count, 2, "途中刷新也保持收着")

        column.moveDrag(to: gap(below: 1, in: column, table: table))
        column.finishDrag()
        await settle()
        XCTAssertEqual(controller.tabOverview().map(\.id).last, tabID, "换到了最后")
        XCTAssertEqual(column.displayedRows.count, 4, "松手后恢复展开：折叠只是拖动期间的取景")
    }

    func testATabTheUserCollapsedStaysCollapsedAfterTheDrag() async throws {
        let controller = TerminalWindowController()
        AppState.shared.windowControllers = [controller]
        defer { controller.window?.close(); AppState.shared.windowControllers = [] }
        let first = try XCTUnwrap(controller.activePane)
        controller.split(first, direction: .right)
        let (column, table) = try mountedColumn(controller)
        let collapse = try XCTUnwrap(descendants(table).compactMap { $0 as? NSButton }.first { $0.toolTip == L("Collapse tab") })
        collapse.performClick(nil)
        XCTAssertEqual(column.displayedRows.count, 1)
        let tabID = try XCTUnwrap(controller.tabOverview().first?.id)

        XCTAssertTrue(column.startDrag(source: .tab(tabID), card: NSView()))
        column.finishDrag()
        await settle()
        XCTAssertEqual(column.displayedRows.count, 1, "用户自己折叠的标签页不该被拖拽顺手展开")
    }

    func testMergingOntoAContainerRowMovesThePaneIntoThatTab() async throws {
        let controller = TerminalWindowController()
        AppState.shared.windowControllers = [controller]
        defer { controller.window?.close(); AppState.shared.windowControllers = [] }
        let first = try XCTUnwrap(controller.activePane)
        controller.split(first, direction: .right)   // 标签页 0：容器 + 两条 pane 行
        let loose = PaneView()
        controller.addTab(initialPane: loose)          // 标签页 1：叶子行
        let (column, table) = try mountedColumn(controller)

        XCTAssertTrue(column.startDrag(source: .pane(loose.dragIdentifier), card: NSView()))
        let containerRow = column.convert(table.rect(ofRow: 0), from: table)
        column.moveDrag(to: NSPoint(x: containerRow.midX, y: containerRow.midY))
        column.finishDrag()
        await settle()
        XCTAssertEqual(controller.tabOverview().map { $0.panes.count }, [3])
        XCTAssertEqual(controller.tabOverview().first?.panes.last, loose, "并进来接在最后一个 pane 右侧")
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    func testMergingTwoSinglePaneTabsLeavesOneTabWithBothPanes() throws {
        let controller = TerminalWindowController()
        defer { controller.window?.close() }
        // movePane 经 AppState 反查源 pane 所在窗口，控制器要在册。
        AppState.shared.windowControllers = [controller]
        defer { AppState.shared.windowControllers = [] }
        let first = try XCTUnwrap(controller.activePane)
        let second = PaneView()
        controller.addTab(initialPane: second)
        XCTAssertEqual(controller.tabOverview().count, 2)

        // 合并 = 把源 pane 插到目标 pane 旁边；源标签页空掉后自动收走。
        XCTAssertTrue(controller.movePane(withID: second.dragIdentifier, to: first, zone: .right))
        let overview = controller.tabOverview()
        XCTAssertEqual(overview.count, 1)
        XCTAssertEqual(Set(overview[0].panes.map(\.dragIdentifier)),
                       [first.dragIdentifier, second.dragIdentifier])
    }
}
