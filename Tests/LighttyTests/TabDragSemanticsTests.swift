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
        ensureTerminalRuntime()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        AppState.shared = AppState(taskDirectory: directory, sweepStalePanes: false)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    // MARK: - 落点判定

    private let a = UUID(), b = UUID(), c = UUID()
    private let t0 = UUID(), t1 = UUID(), t2 = UUID()

    /// `dropSlot` 是纯函数：显示行 + 源行下标 → 落点，逐行查表。
    func testDropSlotTable() {
        let cases: [(name: String, rows: [TabRowKind], sourceIndex: Int, expected: TabColumnView.DropSlot)] = [
            // [叶子A] [叶子B] [叶子C]，A 拖到最后：叶子落在标签页之间 = 顶层换位
            ("a leaf landing between tabs is a top-level reorder",
             [.leaf(tab: t1, pane: b), .leaf(tab: t2, pane: c), .leaf(tab: t0, pane: a)], 2,
             .betweenTabs(after: t2)),
            // 拖回原位也要算得出原位置，才判得了空动
            ("dropping back where it started still resolves",
             [.leaf(tab: t0, pane: a), .leaf(tab: t1, pane: b)], 0,
             .betweenTabs(after: nil)),
            // [容器] [pane b] [叶子A] [pane c]：A 落在 b 与 c 之间，也就是容器标签页块内 = 并进那棵分屏树
            ("a leaf landing inside an expanded tab joins that split tree",
             [.tab(t0), .pane(tab: t0, pane: b), .leaf(tab: t1, pane: a), .pane(tab: t0, pane: c)], 2,
             .insideTab(next: c, previous: nil)),
            // [叶子B] [pane a] [叶子C]：a 落在两条叶子之间 = 顶层位，不该再并进谁
            ("a pane landing at a top-level slot becomes its own tab",
             [.leaf(tab: t0, pane: b), .pane(tab: t1, pane: a), .leaf(tab: t2, pane: c)], 1,
             .betweenTabs(after: t0)),
            // [容器] [pane b] [pane a] [叶子C]：a 在块尾，上方紧邻仍是同块的 pane = 留在原标签页
            ("a pane stays in its tab when it lands at the end of that tab's block",
             [.tab(t0), .pane(tab: t0, pane: b), .pane(tab: t0, pane: a), .leaf(tab: t1, pane: c)], 2,
             .insideTab(next: nil, previous: b)),
            // 折叠的标签页在列表里只有一行，它下面那一格属于标签页之间
            ("a collapsed tab is opaque so the slot under it is a top-level slot",
             [.tab(t0), .leaf(tab: t1, pane: a)], 1,
             .betweenTabs(after: t0)),
        ]
        for c in cases {
            XCTAssertEqual(TabColumnView.dropSlot(in: c.rows, sourceIndex: c.sourceIndex), c.expected, c.name)
        }
    }

    func testPrecedingTabSkipsPaneRowsInsideBlocks() {
        // [容器0] [pane] [pane] [叶子1] [容器2]
        let rows: [TabRowKind] = [
            .tab(t0), .pane(tab: t0, pane: a), .pane(tab: t0, pane: b), .leaf(tab: t1, pane: c), .tab(t2),
        ]
        XCTAssertNil(TabColumnView.precedingTab(in: rows, before: 0))
        XCTAssertEqual(TabColumnView.precedingTab(in: rows, before: 2), t0, "块内的 pane 行不算标签页")
        XCTAssertEqual(TabColumnView.precedingTab(in: rows, before: 3), t0)
        XCTAssertEqual(TabColumnView.precedingTab(in: rows, before: 4), t1)
        XCTAssertEqual(TabColumnView.precedingTab(in: rows, before: rows.count), t2)
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

        let ids = controller.tabOverview().map(\.id)
        XCTAssertTrue(controller.moveTab(withID: ids[0], after: ids[2]))
        XCTAssertEqual(controller.tabOverview().map(\.title), [titles[1], titles[2], titles[0]])
        XCTAssertEqual(controller.tabOverview().first(where: \.isActive)?.title, titles[0],
                       "重排不该顺手换走当前上下文")
        XCTAssertTrue(controller.panes().contains { $0 === first })
        XCTAssertFalse(controller.moveTab(withID: ids[0], after: ids[2]), "原地不动不算一次移动")
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

        XCTAssertTrue(controller.detachPane(withID: extra.dragIdentifier, toNewTabAfter: nil))
        let overview = controller.tabOverview()
        XCTAssertEqual(overview.count, 3)
        XCTAssertEqual(overview[0].panes.map(\.dragIdentifier), [extra.dragIdentifier],
                       "拆出来的 pane 要独占插入位上的新标签页")
        XCTAssertEqual(overview[1].panes.map(\.dragIdentifier), [first.dragIdentifier])
    }

    // MARK: - 显示行推导与命令映射

    func testTheSessionOnlyReordersTheDisplayNeverTheModel() {
        let rows: [TabRowKind] = [.leaf(tab: t0, pane: a), .leaf(tab: t1, pane: b), .leaf(tab: t2, pane: c)]
        XCTAssertEqual(TabColumnView.arrangement(of: rows, source: .pane(a), insertion: nil), [0, 1, 2],
                       "还没离开原位")
        XCTAssertEqual(TabColumnView.arrangement(of: rows, source: .pane(a), insertion: 2), [1, 2, 0])
        XCTAssertEqual(TabColumnView.arrangement(of: rows, source: .pane(UUID()), insertion: 0), [0, 1, 2],
                       "源行已经不在模型里（被关掉）：显示回到模型原样")
        let tabs: [TabRowKind] = [.tab(t0), .leaf(tab: t1, pane: a)]
        XCTAssertEqual(TabColumnView.arrangement(of: tabs, source: .tab(t0), insertion: 1), [1, 0])
    }

    func testDropsTranslateIntoControllerCommands() {
        // 叶子行落在标签页之间 = 换位次；分屏 pane 落在标签页之间 = 拆成新标签页
        XCTAssertEqual(TabColumnView.dropCommand(
            rows: [.leaf(tab: t1, pane: b), .leaf(tab: t0, pane: a)], sourceIndex: 1, merge: nil),
            .moveTab(t0, after: t1))
        XCTAssertEqual(TabColumnView.dropCommand(
            rows: [.pane(tab: t1, pane: a), .leaf(tab: t0, pane: b)], sourceIndex: 0, merge: nil),
            .detachPane(a, after: nil))
        // 落在块内：插到下一个 pane 左侧，没有下一个就插到上一个右侧
        XCTAssertEqual(TabColumnView.dropCommand(
            rows: [.tab(t0), .leaf(tab: t1, pane: a), .pane(tab: t0, pane: c)], sourceIndex: 1, merge: nil),
            .movePaneBeside(a, target: c, zone: .left))
        XCTAssertEqual(TabColumnView.dropCommand(
            rows: [.tab(t0), .pane(tab: t0, pane: c), .leaf(tab: t1, pane: a)], sourceIndex: 2, merge: nil),
            .movePaneBeside(a, target: c, zone: .right))
        // 合并优先
        XCTAssertEqual(TabColumnView.dropCommand(
            rows: [.leaf(tab: t0, pane: a), .tab(t1)], sourceIndex: 0, merge: .tab(t1)),
            .movePaneIntoTab(a, tab: t1))
        XCTAssertEqual(TabColumnView.dropCommand(
            rows: [.leaf(tab: t0, pane: a), .leaf(tab: t1, pane: b)], sourceIndex: 0, merge: .leaf(tab: t1, pane: b)),
            .movePaneBeside(a, target: b, zone: .right))
        // 容器行只排序，合并目标对它无效
        XCTAssertEqual(TabColumnView.dropCommand(
            rows: [.leaf(tab: t1, pane: a), .tab(t0)], sourceIndex: 1, merge: .leaf(tab: t1, pane: a)),
            .moveTab(t0, after: t1))
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

    /// 等松手后投递到下一拍的命令执行完（`completeDrag`），再等它引起的列表刷新合流的那一拍：
    /// 两跳。用挂起而不是转事件循环：async 测试体本身就是主队列上的块，嵌套转事件循环
    /// 不会执行主队列里排着的块。
    private func settle() async { await awaitMainQueue(hops: 2) }

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

    /// 松手只定下命令，执行在下一拍。这一拍之间关掉一个标签页（快捷键、shell 退出都可能），
    /// 命令必须仍然落在用户松手时指的那个位置上，不能因为序号整体前移而落错。
    /// 两种命令：排在某标签页之后（换位/拆出）、并进某容器标签页。
    func testDeferredDropCommandsResolveByIdentityWhenATabClosesFirst() async throws {
        // 换位：把 a 拖到 c 下面，意图是「排在 c 所在标签页之后」；执行前 b 的标签页被关掉
        do {
            let controller = TerminalWindowController()
            AppState.shared.windowControllers = [controller]
            defer { controller.window?.close(); AppState.shared.windowControllers = [] }
            let a = try XCTUnwrap(controller.activePane)
            let b = PaneView(), c = PaneView(), d = PaneView()
            for pane in [b, c, d] { controller.addTab(initialPane: pane) }
            let (column, table) = try mountedColumn(controller)
            XCTAssertEqual(column.displayedRows.count, 4)

            XCTAssertTrue(column.startDrag(source: .pane(a.dragIdentifier), card: NSView()))
            column.moveDrag(to: gap(below: 2, in: column, table: table))
            column.finishDrag()
            let doomed = try XCTUnwrap(controller.tabOverview().first { $0.panes.first === b }?.id)
            controller.closeTab(withID: doomed)
            await settle()
            XCTAssertEqual(controller.tabOverview().map { $0.panes.map(\.dragIdentifier) },
                           [[c.dragIdentifier], [a.dragIdentifier], [d.dragIdentifier]],
                           "落在用户松手时指的位置，不因序号前移而落错")
        }

        // 合并：把 loose 压在容器标签页上；执行前它前面的标签页被关掉
        do {
            let controller = TerminalWindowController()
            AppState.shared.windowControllers = [controller]
            defer { controller.window?.close(); AppState.shared.windowControllers = [] }
            let first = try XCTUnwrap(controller.activePane)
            let target = PaneView(), loose = PaneView()
            controller.addTab(initialPane: target)
            controller.split(target, direction: .right)   // 标签页 1：容器 + 两条 pane 行
            controller.addTab(initialPane: loose)           // 标签页 2：叶子行
            let (column, table) = try mountedColumn(controller)
            let containerIndex = try XCTUnwrap(column.displayedRows.firstIndex {
                if case .tab = $0 { return true } else { return false }
            })

            XCTAssertTrue(column.startDrag(source: .pane(loose.dragIdentifier), card: NSView()))
            let containerRow = column.convert(table.rect(ofRow: containerIndex), from: table)
            column.moveDrag(to: NSPoint(x: containerRow.midX, y: containerRow.midY))
            column.finishDrag()
            let doomed = try XCTUnwrap(controller.tabOverview().first { $0.panes.first === first }?.id)
            controller.closeTab(withID: doomed)
            await settle()
            let overview = controller.tabOverview()
            XCTAssertEqual(overview.count, 1, "并进了容器标签页，而不是序号前移后的别人")
            XCTAssertEqual(overview.first?.panes.last, loose)
        }
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

    /// 拖动一条多 pane 标签页时它收成一行（途中刷新也保持），松手后恢复用户原来的选择：
    /// 原本展开的恢复展开——折叠只是拖动期间的取景；用户自己折叠的松手后仍折叠。
    func testDragCollapsesTabsOnlyForTheDragAndRestoresTheUsersChoice() async throws {
        let controller = TerminalWindowController()
        AppState.shared.windowControllers = [controller]
        defer { controller.window?.close(); AppState.shared.windowControllers = [] }
        let first = try XCTUnwrap(controller.activePane)
        controller.split(first, direction: .right)   // 标签页 0：两个 pane，展开着
        controller.addTab(initialPane: PaneView())   // 标签页 1：叶子行
        let (column, table) = try mountedColumn(controller)
        XCTAssertEqual(column.displayedRows.count, 4, "容器行 + 两条 pane 行 + 一条叶子行")
        let tabID = try XCTUnwrap(controller.tabOverview().first?.id)

        // 展开着的标签页：拖动期间收起，松手后恢复展开
        XCTAssertTrue(column.startDrag(source: .tab(tabID), card: NSView()))
        XCTAssertEqual(column.displayedRows.count, 2, "拖动期间多 pane 标签页收成一行")
        column.reload()
        XCTAssertEqual(column.displayedRows.count, 2, "途中刷新也保持收着")

        column.moveDrag(to: gap(below: 1, in: column, table: table))
        column.finishDrag()
        await settle()
        XCTAssertEqual(controller.tabOverview().map(\.id).last, tabID, "换到了最后")
        XCTAssertEqual(column.displayedRows.count, 4, "松手后恢复展开：折叠只是拖动期间的取景")

        // 用户自己折叠的标签页：松手后仍折叠
        let collapse = try XCTUnwrap(descendants(table).compactMap { $0 as? NSButton }.first { $0.toolTip == L("Collapse tab") })
        collapse.performClick(nil)
        XCTAssertEqual(column.displayedRows.count, 2, "叶子行 + 折叠成一行的标签页")

        XCTAssertTrue(column.startDrag(source: .tab(tabID), card: NSView()))
        column.finishDrag()
        await settle()
        XCTAssertEqual(column.displayedRows.count, 2, "用户自己折叠的标签页不该被拖拽顺手展开")
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

    // MARK: - 拖到终端区域

    /// 窗口放大、列表贴左边，右侧就有一块不和列表重叠的终端区域可以当落点。
    private func mountedColumnBesideTerminals(_ controller: TerminalWindowController) throws -> (TabColumnView, NSTableView) {
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1400, height: 800))
        window.contentView?.layoutSubtreeIfNeeded()
        let mounted = try mountedColumn(controller)
        mounted.0.frame = NSRect(x: 0, y: 0, width: 200, height: 600)
        mounted.0.layoutSubtreeIfNeeded()
        return mounted
    }

    /// 目标 pane 里靠某条边的一点（列表坐标），保证在列表外。
    private func point(in pane: PaneView, near zone: PaneDropZone, column: TabColumnView) throws -> NSPoint {
        let b = pane.bounds
        let local: NSPoint
        switch zone {
        case .left: local = NSPoint(x: b.minX + b.width * 0.1, y: b.midY)
        case .right: local = NSPoint(x: b.maxX - b.width * 0.1, y: b.midY)
        case .top: local = NSPoint(x: b.midX, y: b.maxY - b.height * 0.1)
        case .bottom: local = NSPoint(x: b.midX, y: b.minY + b.height * 0.1)
        }
        let point = column.convert(pane.convert(local, to: nil), from: nil)
        XCTAssertFalse(column.bounds.contains(point), "落点必须在列表外")
        XCTAssertEqual(PaneDropZone.calculate(at: local, in: b), zone)
        return point
    }

    private func dropPreviewShown(on pane: PaneView) -> Bool {
        pane.subviews.contains { $0 is PaneDropOverlayView }
    }

    func testDraggingAPaneRowOntoATerminalSplitsBesideIt() throws {
        let controller = TerminalWindowController()
        AppState.shared.windowControllers = [controller]
        defer { controller.window?.close(); AppState.shared.windowControllers = [] }
        let target = try XCTUnwrap(controller.activePane)
        let loose = PaneView()
        controller.addTab(initialPane: loose)
        controller.selectTab(withID: try XCTUnwrap(controller.tabOverview().first { $0.panes.contains(target) }?.id))
        let (column, _) = try mountedColumnBesideTerminals(controller)
        let original = column.displayedRows

        XCTAssertTrue(column.startDrag(source: .pane(loose.dragIdentifier), card: NSView()))
        column.moveDrag(to: try point(in: target, near: .right, column: column))
        XCTAssertTrue(dropPreviewShown(on: target), "压在终端上显示和 pane 头部拖动一样的落点高亮")
        column.moveDrag(to: try point(in: target, near: .bottom, column: column))
        XCTAssertEqual(column.displayedRows, original, "光标在列表外，列表保持原样")
        XCTAssertNil(column.finishDrag(), "落在列表外，卡片不飞回列表")
        XCTAssertFalse(dropPreviewShown(on: target))

        try waitUntil("pane moves below the target") { controller.tabOverview().count == 1 }
        XCTAssertEqual(controller.tabOverview().first?.panes, [target, loose])
    }

    func testCursorLeavingTheListUndoesTheProposedReorder() throws {
        let controller = TerminalWindowController()
        AppState.shared.windowControllers = [controller]
        defer { controller.window?.close(); AppState.shared.windowControllers = [] }
        let first = try XCTUnwrap(controller.activePane)
        let second = PaneView(), third = PaneView()
        for pane in [second, third] { controller.addTab(initialPane: pane) }
        controller.selectTab(withID: try XCTUnwrap(controller.tabOverview().first { $0.panes.contains(first) }?.id))
        let (column, table) = try mountedColumnBesideTerminals(controller)
        let original = column.displayedRows

        XCTAssertTrue(column.startDrag(source: .pane(second.dragIdentifier), card: NSView()))
        column.moveDrag(to: gap(below: 2, in: column, table: table))
        XCTAssertNotEqual(column.displayedRows, original)
        // 拖出列表但不压在任何 pane 上（压在源 pane 自己身上也一样）再松手：什么都不发生
        column.moveDrag(to: NSPoint(x: column.bounds.maxX + 1, y: -500))
        XCTAssertEqual(column.displayedRows, original)
        column.finishDrag()
        try waitUntil("drag session ends") { column.startDrag(source: .pane(second.dragIdentifier), card: NSView()) }
        column.finishDrag()
        XCTAssertEqual(controller.tabOverview().map(\.panes), [[first], [second], [third]])
    }

    func testATabRowDraggedOntoATerminalDoesNothing() throws {
        let controller = TerminalWindowController()
        AppState.shared.windowControllers = [controller]
        defer { controller.window?.close(); AppState.shared.windowControllers = [] }
        let first = try XCTUnwrap(controller.activePane)
        controller.split(first, direction: .right)
        let other = PaneView()
        controller.addTab(initialPane: other)
        controller.selectTab(withID: try XCTUnwrap(controller.tabOverview().first { $0.panes.contains(other) }?.id))
        let (column, _) = try mountedColumnBesideTerminals(controller)
        let tabID = try XCTUnwrap(controller.tabOverview().first?.id)

        XCTAssertTrue(column.startDrag(source: .tab(tabID), card: NSView()))
        column.moveDrag(to: try point(in: other, near: .right, column: column))
        XCTAssertFalse(dropPreviewShown(on: other), "标签页行只在列表里排序")
        column.finishDrag()
        try waitUntil("drag session ends") { column.startDrag(source: .tab(tabID), card: NSView()) }
        column.finishDrag()
        XCTAssertEqual(controller.tabOverview().map(\.panes.count), [2, 1])
    }

    /// 拖出列表的卡片放在哪一层：必须是真实窗口里标签页侧栏的祖先，卡片排在最上面才不会被侧栏盖住。
    func testAFreelyFollowingCardSitsAboveTheTabSidebar() throws {
        let controller = TerminalWindowController()
        defer { controller.window?.close() }
        controller.openTabSidebar(animated: false)
        let window = try XCTUnwrap(controller.window)
        let themeFrame = try XCTUnwrap(window.contentView?.superview)
        let column = try XCTUnwrap(descendants(themeFrame).compactMap { $0 as? TabColumnView }.first)

        XCTAssertTrue(ReorderDrag.stage(for: column, followsPointerFreely: false) === column)
        let stage = ReorderDrag.stage(for: column, followsPointerFreely: true)
        XCTAssertTrue(column.isDescendant(of: stage), "侧栏不在这一层下面，卡片会被它盖住")
        XCTAssertFalse(column.isDescendant(of: try XCTUnwrap(window.contentView)),
                       "侧栏挂在 contentView 之外，放进 contentView 的卡片会被盖住")
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
