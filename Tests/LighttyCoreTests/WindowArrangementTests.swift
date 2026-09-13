import XCTest
@testable import LighttyCore

final class WindowArrangementTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    private let t0 = UUID(), t1 = UUID(), t2 = UUID(), t3 = UUID()

    /// 四个单 pane 标签页 [t0:a] [t1:b] [t2:c] [t3:d]，当前是 active。
    private func four(active: UUID? = nil) -> WindowArrangement {
        WindowArrangement(tabs: zip([t0, t1, t2, t3], [a, b, c, d]).enumerated().map { index, pair in
            ArrangedTab(id: pair.0, layout: .pane(pair.1), title: .numbered(index + 1))
        }, activeTabID: active)
    }

    private func order(_ arrangement: WindowArrangement?) -> [UUID] { arrangement?.tabs.map(\.id) ?? [] }

    /// 关掉一组标签页 = 一次移除它们的全部 pane（控制器的 `close(panes:)` 就是这样关的）。
    private func closing(_ ids: Set<UUID>, in arrangement: WindowArrangement) -> WindowArrangement? {
        arrangement.removingPanes(Set(ids.compactMap(arrangement.tab).flatMap(\.layout.panes)))
    }

    private func closing(_ scope: WindowArrangement.CloseScope, in arrangement: WindowArrangement) -> WindowArrangement? {
        closing(arrangement.tabIDs(in: scope), in: arrangement)
    }

    // MARK: - 构造与查询

    func testInitFallsBackToTheFirstTabAndStaysWellFormed() {
        XCTAssertEqual(four().activeTabID, t0)
        XCTAssertEqual(four(active: UUID()).activeTabID, t0, "不在列表里的当前标签页不算数")
        XCTAssertNil(WindowArrangement().activeTabID)
        XCTAssertTrue(four().isWellFormed)
        XCTAssertTrue(WindowArrangement().isWellFormed)
        let duplicated = WindowArrangement(tabs: [
            ArrangedTab(id: t0, layout: .pane(a), title: .numbered(1)),
            ArrangedTab(id: t1, layout: .pane(a), title: .numbered(2)),
        ])
        XCTAssertFalse(duplicated.isWellFormed, "同一个 pane 不能出现在两个标签页里")
        XCTAssertEqual(four().tabID(hosting: c), t2)
        XCTAssertEqual(four().highestTitleNumber, 4)
    }

    func testRestoringClampsTheActiveIndex() {
        let tabs = four().tabs
        XCTAssertEqual(WindowArrangement(restoring: tabs, activeIndex: 2).activeTabID, t2)
        XCTAssertEqual(WindowArrangement(restoring: tabs, activeIndex: 99).activeTabID, t3)
        XCTAssertEqual(WindowArrangement(restoring: tabs, activeIndex: -1).activeTabID, t0)
        XCTAssertNil(WindowArrangement(restoring: [], activeIndex: 0).activeTabID)
    }

    // MARK: - 选中

    func testGotoWrapsAndClampsAndNeedsMoreThanOneTab() {
        let start = four(active: t0)
        XCTAssertEqual(start.selecting(.previous)?.activeTabID, t3, "从第一个往前环绕到最后")
        XCTAssertEqual(four(active: t3).selecting(.next)?.activeTabID, t0)
        XCTAssertEqual(start.selecting(.last)?.activeTabID, t3)
        XCTAssertEqual(start.selecting(.index(2))?.activeTabID, t1, "序号是 1-based")
        XCTAssertEqual(start.selecting(.index(40))?.activeTabID, t3, "超界落到最后一个")
        let single = WindowArrangement(tabs: [ArrangedTab(id: t0, layout: .pane(a), title: .numbered(1))])
        XCTAssertNil(single.selecting(.next))
        XCTAssertNil(start.selecting(UUID()))
        XCTAssertEqual(start.selecting(t0)?.activeTabID, t0, "选中当前标签页也是有效命令")
    }

    // MARK: - 关闭

    func testClosingTheActiveTabLandsOnTheNeighbourAtTheSamePosition() {
        XCTAssertEqual(closing([t1], in: four(active: t1))?.activeTabID, t2, "原位次上的邻居")
        XCTAssertEqual(closing([t3], in: four(active: t3))?.activeTabID, t2, "最后一个没了取新的最后一个")
        XCTAssertEqual(closing([t0], in: four(active: t2))?.activeTabID, t2, "关别人不换当前")
        XCTAssertNil(closing([UUID()], in: four()))
        let empty = closing([t0, t1, t2, t3], in: four())
        XCTAssertEqual(empty?.tabs.count, 0)
        XCTAssertNil(empty?.activeTabID)
        XCTAssertEqual(empty?.isWellFormed, true)
    }

    func testCloseScopesAreRelativeToTheActiveTab() {
        let start = four(active: t1)
        XCTAssertEqual(order(closing(.this, in: start)), [t0, t2, t3])
        XCTAssertEqual(order(closing(.other, in: start)), [t1])
        XCTAssertEqual(order(closing(.right, in: start)), [t0, t1])
        XCTAssertEqual(closing(.right, in: start)?.activeTabID, t1)
        XCTAssertNil(closing(.right, in: four(active: t3)), "右边没有标签页")
    }

    func testRemovingPanesInOneStepLandsByThePositionBeforeRemoval() throws {
        let start = four(active: t1)
        // 关当前标签页和它前面的一个：落点按移除前的位次算。
        XCTAssertEqual(order(start.removingPanes([a, b])), [t2, t3])
        XCTAssertEqual(start.removingPanes([a, b])?.activeTabID, t3)
        XCTAssertEqual(start.tabIDs(in: .other), [t0, t2, t3])
        XCTAssertEqual(start.tabIDs(in: .right), [t2, t3])
        XCTAssertEqual(WindowArrangement().tabIDs(in: .this), [])

        let split = try XCTUnwrap(start.movingPane(c, intoTab: t1))
        let shrunk = try XCTUnwrap(split.removingPanes([c, UUID()]))
        XCTAssertEqual(shrunk.tab(t1)?.layout.panes, [b], "标签页还有别的 pane 就留着；不认识的身份忽略")
        XCTAssertEqual(shrunk.activeTabID, t1)
        XCTAssertNil(start.removingPanes([UUID()]))
        XCTAssertNil(start.removingPanes([]))
    }

    // MARK: - 标签页换位

    func testMovingATabAfterAnAnchorFollowsIdentityNotPosition() {
        let start = four(active: t0)
        XCTAssertEqual(order(start.movingTab(t0, after: t2)), [t1, t2, t0, t3])
        XCTAssertEqual(start.movingTab(t0, after: t2)?.activeTabID, t0, "选中跟着标签页本体走")
        XCTAssertEqual(order(start.movingTab(t3, after: nil)), [t3, t0, t1, t2])
        // 命令定下之后、执行之前 t1 被关掉：仍然落在 t2 后面。
        let closed = try? XCTUnwrap(closing([t1], in: start))
        XCTAssertEqual(order(closed?.movingTab(t0, after: t2)), [t2, t0, t3])
        XCTAssertNil(closed?.movingTab(t0, after: t1), "anchor 没了，命令作废而不是落到别处")
        XCTAssertNil(start.movingTab(t1, after: t0), "原地不动")
        XCTAssertNil(start.movingTab(t0, after: nil), "原地不动")
        XCTAssertNil(start.movingTab(t0, after: t0))
    }

    func testMovingTheActiveTabWraps() {
        XCTAssertEqual(order(four(active: t0).movingActiveTab(by: -1)), [t1, t2, t3, t0])
        XCTAssertEqual(order(four(active: t3).movingActiveTab(by: 1)), [t3, t0, t1, t2])
        XCTAssertEqual(order(four(active: t1).movingActiveTab(by: 1)), [t0, t2, t1, t3])
        XCTAssertNil(four().movingActiveTab(by: 0))
        XCTAssertNil(four().movingActiveTab(by: 4), "转一整圈回到原位")
    }

    // MARK: - 标题

    func testRenamingMakesTheTitleCustomAndAppendingUsesTheGivenTitle() throws {
        let renamed = try XCTUnwrap(four().renamingTab(t1, to: "后端"))
        XCTAssertEqual(renamed.tab(t1)?.title, .custom("后端"))
        XCTAssertEqual(renamed.highestTitleNumber, 4)
        XCTAssertNil(four().renamingTab(UUID(), to: "x"))

        let fresh = UUID(), pane = UUID()
        let appended = try XCTUnwrap(four(active: t1).appendingTab(fresh, layout: .pane(pane), title: .numbered(9), select: false))
        XCTAssertEqual(appended.activeTabID, t1)
        XCTAssertEqual(appended.highestTitleNumber, 9)
        XCTAssertEqual(four().appendingTab(UUID(), layout: .pane(pane), title: .numbered(5), select: true)?.tabs.last?.title, .numbered(5))
        XCTAssertNil(four().appendingTab(UUID(), layout: .pane(a), title: .numbered(5), select: true), "pane 已经在窗口里")
        XCTAssertNil(four().appendingTab(t0, layout: .pane(pane), title: .numbered(5), select: true), "身份撞了")
        XCTAssertEqual(WindowArrangement().appendingTab(fresh, layout: .pane(pane), title: .numbered(1), select: false)?.activeTabID,
                       fresh, "空窗口追加的第一个标签页总会被选中")
    }

    func testTitleParsingAndSnapshotMigration() {
        XCTAssertEqual(TabTitle.parsing("Tab 7", defaultFormat: "Tab %d"), .numbered(7))
        XCTAssertEqual(TabTitle.parsing("标签页 3", defaultFormat: "Tab %d"), .custom("标签页 3"),
                       "别的语言的默认名只能当成自定义——这正是要显式存下来的原因")
        XCTAssertEqual(TabTitle.parsing("", defaultFormat: "Tab %d"), .custom(""))
        XCTAssertEqual(TabTitle.restored(title: "标签页 3", customTitle: false, number: 3, defaultFormat: "Tab %d"),
                       .numbered(3), "新快照显式存了序号，与当前语言无关")
        XCTAssertEqual(TabTitle.restored(title: "Tab 3", customTitle: true, number: nil, defaultFormat: "Tab %d"),
                       .custom("Tab 3"), "用户就是想叫这个名字")
        XCTAssertEqual(TabTitle.restored(title: "Tab 3", customTitle: nil, number: nil, defaultFormat: "Tab %d"),
                       .numbered(3), "旧快照按旧规则迁移一次")
        XCTAssertEqual(TabTitle.restored(title: "后端", customTitle: nil, number: nil, defaultFormat: "Tab %d"),
                       .custom("后端"))
    }

    // MARK: - pane

    func testPaneCommandsCarryTitlesAndClearZoomOnlyWhereTheTreeChanged() throws {
        let split = try XCTUnwrap(four(active: t0).insertingPane(UUID(), beside: a, edge: .right))
        let zoomed = try XCTUnwrap(split.togglingZoom(a))
        XCTAssertEqual(zoomed.activeTab?.zoomedPane, a)
        XCTAssertNil(four().togglingZoom(a), "单 pane 标签页没什么可放大")
        XCTAssertNil(zoomed.togglingZoom(c), "不在当前标签页里")

        let merged = try XCTUnwrap(zoomed.movingPane(c, intoTab: t1))
        XCTAssertEqual(order(merged), [t0, t1, t3], "c 的标签页移空后消失")
        XCTAssertEqual(merged.tab(t0)?.zoomedPane, a, "t0 的树没变，放大态保留")
        XCTAssertEqual(merged.tab(t1)?.layout.panes, [b, c])
        XCTAssertEqual(merged.tab(t1)?.title, .numbered(2), "标题跟着身份走")

        let changed = try XCTUnwrap(zoomed.movingPane(b, beside: a, edge: .bottom))
        XCTAssertNil(changed.tab(t0)?.zoomedPane, "t0 的树变了，放大态作废")
        XCTAssertNil(zoomed.movingPane(b, intoTab: t1), "本来就独占这个标签页")
        XCTAssertNil(zoomed.movingPane(a, beside: a, edge: .left))
    }

    func testDetachingPlacesTheNewTabAfterTheAnchor() throws {
        let fresh = UUID()
        let split = try XCTUnwrap(four(active: t1).movingPane(a, intoTab: t2))
        XCTAssertEqual(order(split), [t1, t2, t3])
        XCTAssertEqual(split.activeTabID, t1)
        let detached = try XCTUnwrap(split.detachingPane(a, toNewTab: fresh, title: .numbered(5), after: t2))
        XCTAssertEqual(order(detached), [t1, t2, fresh, t3])
        XCTAssertEqual(detached.tab(fresh)?.title, .numbered(5))
        XCTAssertEqual(detached.activeTabID, t1, "拆出不跟随切换")
        XCTAssertEqual(order(split.detachingPane(a, toNewTab: fresh, title: .numbered(5), after: nil)), [fresh, t1, t2, t3])
        XCTAssertNil(split.detachingPane(a, toNewTab: fresh, title: .numbered(5), after: t0), "anchor 已经不在")
        XCTAssertNil(split.detachingPane(b, toNewTab: fresh, title: .numbered(5), after: nil), "独占标签页拆不出东西")
    }

    func testCrossWindowStepsRemoveAndInsert() throws {
        let removed = try XCTUnwrap(four(active: t0).removingPane(a))
        XCTAssertEqual(removed.activeTabID, t1, "当前标签页移空后落到邻居")
        let target = WindowArrangement(tabs: [ArrangedTab(id: UUID(), layout: .pane(UUID()), title: .numbered(9))])
        let anchor = try XCTUnwrap(target.tabs.first)
        XCTAssertEqual(target.insertingPane(a, intoTab: anchor.id)?.tabs.first?.layout.panes.last, a)
        XCTAssertNil(target.insertingPane(a, intoTab: UUID()))
        XCTAssertNil(four().removingPane(UUID()))
    }

    func testResizingOnlyAcceptsRatioChanges() throws {
        let split = try XCTUnwrap(four(active: t0).insertingPane(UUID(), beside: a, edge: .right))
        let zoomed = try XCTUnwrap(split.togglingZoom(a))
        let layout = try XCTUnwrap(zoomed.tab(t0)?.layout)
        let resized = try XCTUnwrap(zoomed.resizingLayout(ofTab: t0, to: layout.equalized().movingDivider(
            at: [], index: 0, to: 30, in: CGRect(x: 0, y: 0, width: 101, height: 10),
            dividerThickness: 1, scale: 1, minimumSize: 5)))
        XCTAssertEqual(resized.tab(t0)?.zoomedPane, a, "只改比例不动放大态")
        XCTAssertNil(zoomed.resizingLayout(ofTab: t0, to: layout), "没有变化")
        XCTAssertNil(zoomed.resizingLayout(ofTab: t0, to: .pane(a)), "结构变化不走这条路")
    }

    func testRestoringARecordKeepsZoomOnlyWhereTheTreeIsTheSame() throws {
        let fresh = UUID()
        let split = try XCTUnwrap(four(active: t0).insertingPane(UUID(), beside: a, edge: .right))
        let record = split
        let now = try XCTUnwrap(split.togglingZoom(a)?.detachingPane(a, toNewTab: fresh, title: .numbered(5), after: t0)?
            .selecting(t1)?.renamingTab(t1, to: "改过"))
        let back = now.restoring(record)
        XCTAssertEqual(order(back), order(record))
        XCTAssertEqual(back.activeTabID, t0)
        XCTAssertEqual(back.tab(t1)?.title, .numbered(2), "标题回到记录时的样子")
        XCTAssertNil(back.tab(t0)?.zoomedPane)
    }

    // MARK: - 焦点

    func testFocusIsRecordedPerTabAndFallsBackToTheFirstPane() throws {
        let fresh = UUID()
        let split = try XCTUnwrap(four(active: t0).insertingPane(fresh, beside: a, edge: .right))
        XCTAssertNil(split.tab(t0)?.focusedPane)
        XCTAssertEqual(split.focusTarget, a, "没记过焦点取第一个 pane")
        let focused = try XCTUnwrap(split.focusing(fresh))
        XCTAssertEqual(focused.tab(t0)?.focusedPane, fresh)
        XCTAssertEqual(focused.focusTarget, fresh)
        XCTAssertEqual(focused.activeTabID, t0)
        let elsewhere = try XCTUnwrap(focused.focusing(c))
        XCTAssertEqual(elsewhere.tab(t2)?.focusedPane, c, "焦点按标签页各记各的，不换当前标签页")
        XCTAssertEqual(elsewhere.tab(t0)?.focusedPane, fresh)
        XCTAssertEqual(elsewhere.activeTabID, t0)
        XCTAssertNil(split.focusing(UUID()), "不在本窗口的 pane")
    }

    func testRemovingOrMovingTheFocusedPaneClearsItsTabsFocus() throws {
        let fresh = UUID()
        let focused = try XCTUnwrap(four(active: t0).insertingPane(fresh, beside: a, edge: .right)?
            .focusing(fresh)?.focusing(b))

        let closed = try XCTUnwrap(focused.removingPane(fresh))
        XCTAssertNil(closed.tab(t0)?.focusedPane, "关掉的 pane 不再是焦点")
        XCTAssertEqual(closed.focusTarget, a)
        XCTAssertEqual(try XCTUnwrap(focused.removingPane(a)).tab(t0)?.focusedPane, fresh, "关的不是焦点就不动")

        let moved = try XCTUnwrap(focused.movingPane(fresh, beside: c, edge: .left))
        XCTAssertNil(moved.tab(t0)?.focusedPane, "移走的 pane 不再是源标签页的焦点")
        XCTAssertNil(moved.tab(t2)?.focusedPane, "移进来不抢目标标签页的焦点")

        let merged = try XCTUnwrap(focused.movingPane(b, intoTab: t0))
        XCTAssertNil(merged.tab(t1), "b 的标签页移空消失")
        XCTAssertEqual(merged.tab(t0)?.focusedPane, fresh, "并进来不抢焦点")

        let detached = try XCTUnwrap(focused.detachingPane(fresh, toNewTab: UUID(), title: .numbered(5), after: t0))
        XCTAssertNil(detached.tab(t0)?.focusedPane, "拆走的 pane 不再是源标签页的焦点")
        XCTAssertNil(detached.tabs[1].focusedPane, "新标签页从第一个 pane 起")

        let removedElsewhere = try XCTUnwrap(focused.removingPane(fresh))
        XCTAssertEqual(removedElsewhere.tab(t1)?.focusedPane, b, "跨窗口移出只影响源标签页")
        XCTAssertNil(try XCTUnwrap(focused.removingPanes([fresh, b])).tab(t1), "一次移除多个同样修正")
        XCTAssertNil(try XCTUnwrap(focused.removingPanes([fresh, c])).tab(t0)?.focusedPane)
    }

    func testRestoringARecordKeepsFocusOnlyWherePanesStayed() throws {
        let fresh = UUID()
        let record = try XCTUnwrap(four(active: t0).insertingPane(fresh, beside: a, edge: .right))
        let now = try XCTUnwrap(record.focusing(fresh)?.focusing(b)?.movingPane(fresh, intoTab: t1)?.focusing(fresh))
        XCTAssertEqual(now.tab(t1)?.focusedPane, fresh)
        let back = now.restoring(record)
        XCTAssertNil(back.tab(t0)?.focusedPane, "记录里没有焦点，眼下的焦点 pane 也不在这个标签页里")
        XCTAssertNil(back.tab(t1)?.focusedPane, "撤销后 fresh 已经不在 t1")
        let stayed = try XCTUnwrap(record.focusing(b)?.focusing(a))
        XCTAssertEqual(stayed.restoring(record).tab(t1)?.focusedPane, b, "pane 还在原标签页，焦点保留")
    }

    // MARK: - 快照

    func testSnapshotSkipsTabsItCannotCaptureAndClampsTheActiveIndex() {
        let start = four(active: t3)
        let captured = start.snapshot { $0.id == t3 ? nil : $0.title.number }
        XCTAssertEqual(captured?.tabs, [1, 2, 3])
        XCTAssertEqual(captured?.activeIndex, 2)
        XCTAssertNil(start.snapshot { _ -> Int? in nil })
    }
}
