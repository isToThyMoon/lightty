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
            .tab(0), .pane(tab: 0, pane: b), .leaf(tab: 1, pane: a), .pane(tab: 0, pane: c),
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
            .tab(0), .pane(tab: 0, pane: b), .pane(tab: 0, pane: a), .leaf(tab: 1, pane: c),
        ]
        XCTAssertEqual(TabColumnView.dropSlot(in: rows, sourceIndex: 2), .insideTab(next: nil, previous: b))
    }

    func testACollapsedTabIsOpaqueSoTheSlotUnderItIsATopLevelSlot() {
        // 折叠的标签页在列表里只有一行，它下面那一格属于标签页之间。
        let rows: [TabRowKind] = [.tab(0), .leaf(tab: 1, pane: a)]
        XCTAssertEqual(TabColumnView.dropSlot(in: rows, sourceIndex: 1), .betweenTabs(1))
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
