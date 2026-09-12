import CoreGraphics
import XCTest
@testable import LighttyCore

final class PaneLayoutTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    private func weights(_ layout: PaneLayout?) -> [Double] {
        guard case .split(_, let branches)? = layout else { return [] }
        return branches.map(\.weight)
    }

    // MARK: - 插入

    func testInsertingWrapsTheTargetIntoAnEvenBinarySplit() {
        let right = PaneLayout.pane(a).inserting(b, beside: a, edge: .right)
        XCTAssertEqual(right, .split(.horizontal, [.init(weight: 0.5, node: .pane(a)), .init(weight: 0.5, node: .pane(b))]))
        let top = PaneLayout.pane(a).inserting(b, beside: a, edge: .top)
        XCTAssertEqual(top?.panes, [b, a], "上侧插入排在目标之前")
        guard case .split(.vertical, _)? = top else { return XCTFail("上下插入要是纵向分屏") }
    }

    func testInsertingNestsWithoutTouchingOuterProportions() throws {
        // [a 0.7 | b 0.3]，在 b 下方插 c：外层比例不动，b 原位包成纵向二叉。
        let outer = try XCTUnwrap(PaneLayout.split(.horizontal, weights: [0.7, 0.3], children: [.pane(a), .pane(b)]))
        let nested = try XCTUnwrap(outer.inserting(c, beside: b, edge: .bottom))
        XCTAssertEqual(weights(nested), [0.7, 0.3])
        XCTAssertEqual(nested.node(at: [1]), .split(.vertical, [.init(weight: 0.5, node: .pane(b)), .init(weight: 0.5, node: .pane(c))]))
        XCTAssertEqual(nested.panes, [a, b, c])
    }

    func testInsertingRejectsMissingTargetsAndDuplicates() {
        XCTAssertNil(PaneLayout.pane(a).inserting(b, beside: c, edge: .right))
        XCTAssertNil(PaneLayout.pane(a).inserting(a, beside: a, edge: .right))
    }

    // MARK: - 移除

    func testRemovingUnwrapsTheSiblingIntoTheVacatedSlot() throws {
        let layout = try XCTUnwrap(PaneLayout.split(.horizontal, weights: [0.7, 0.3],
            children: [.pane(a), try XCTUnwrap(PaneLayout.pane(b).inserting(c, beside: b, edge: .bottom))]))
        let removed = layout.removing(c)
        XCTAssertEqual(removed, .split(.horizontal, [.init(weight: 0.7, node: .pane(a)), .init(weight: 0.3, node: .pane(b))]),
                       "兄弟接管空位，外层比例不变")
        XCTAssertEqual(removed?.removing(a), .pane(b))
        XCTAssertNil(PaneLayout.pane(a).removing(a))
        XCTAssertEqual(PaneLayout.pane(a).removing(b), .pane(a), "不在树里原样返回")
    }

    func testRemovingFromAWideSplitGivesTheShareToTheNeighbour() throws {
        let layout = try XCTUnwrap(PaneLayout.split(.horizontal, weights: [0.2, 0.3, 0.5],
            children: [.pane(a), .pane(b), .pane(c)]))
        XCTAssertEqual(weights(layout.removing(b)), [0.5, 0.5], "中间的交给前一个")
        XCTAssertEqual(weights(layout.removing(a)), [0.5, 0.5], "第一个没有前一个，交给后一个")
    }

    func testSplitFromSnapshotNormalisesOrFallsBackToEven() {
        XCTAssertEqual(weights(PaneLayout.split(.horizontal, weights: [2, 6], children: [.pane(a), .pane(b)])), [0.25, 0.75])
        XCTAssertEqual(weights(PaneLayout.split(.horizontal, weights: [1], children: [.pane(a), .pane(b)])), [0.5, 0.5])
        XCTAssertEqual(weights(PaneLayout.split(.horizontal, weights: [.nan, 1], children: [.pane(a), .pane(b)])), [0.5, 0.5])
        XCTAssertEqual(PaneLayout.split(.horizontal, weights: [1], children: [.pane(a)]), .pane(a))
        XCTAssertNil(PaneLayout.split(.horizontal, weights: [], children: []))
    }

    func testEqualizedResetsEverySplit() throws {
        let layout = try XCTUnwrap(PaneLayout.split(.horizontal, weights: [0.9, 0.1],
            children: [.pane(a), try XCTUnwrap(PaneLayout.split(.vertical, weights: [0.2, 0.8], children: [.pane(b), .pane(c)]))]))
        let equal = layout.equalized()
        XCTAssertEqual(weights(equal), [0.5, 0.5])
        XCTAssertEqual(weights(equal.node(at: [1])), [0.5, 0.5])
    }

    // MARK: - 几何

    func testGeometryTilesTheRectWithoutGapsOrOverlap() throws {
        let layout = try XCTUnwrap(PaneLayout.split(.horizontal, weights: [1, 1, 1],
            children: [.pane(a), .pane(b), .pane(c)]))
        let g = layout.geometry(in: CGRect(x: 0, y: 0, width: 101, height: 50), dividerThickness: 1, scale: 2)
        let frames = [a, b, c].compactMap { g.panes[$0] }
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(g.dividers.count, 2)
        // 相邻 pane 之间正好夹一条分隔线
        for (lead, (divider, trail)) in zip(frames, zip(g.dividers, frames.dropFirst())) {
            XCTAssertEqual(lead.maxX, divider.rect.minX, accuracy: 0.0001)
            XCTAssertEqual(divider.rect.maxX, trail.minX, accuracy: 0.0001)
        }
        XCTAssertEqual(frames.last?.maxX, 101, "最后一个钉在边上，不漂移")
        for frame in frames {
            XCTAssertEqual((frame.minX * 2).rounded(), frame.minX * 2, "边界对齐到物理像素")
        }
    }

    func testGeometryNestsSplitsInsideTheirSlot() throws {
        let layout = try XCTUnwrap(PaneLayout.pane(a).inserting(b, beside: a, edge: .right)?
            .inserting(c, beside: b, edge: .bottom))
        let g = layout.geometry(in: CGRect(x: 0, y: 0, width: 201, height: 101), dividerThickness: 1, scale: 1)
        let fb = try XCTUnwrap(g.panes[b]), fc = try XCTUnwrap(g.panes[c])
        XCTAssertEqual(fb.minX, fc.minX)
        XCTAssertEqual(fb.width, fc.width)
        XCTAssertLessThan(fb.maxY, fc.minY, "b 在上 c 在下")
        XCTAssertEqual(g.splits[[1]], CGRect(x: fb.minX, y: 0, width: fb.width, height: 101))
    }

    // MARK: - 调尺寸

    func testMovingADividerOnlyRedistributesItsTwoNeighbours() throws {
        let layout = try XCTUnwrap(PaneLayout.split(.horizontal, weights: [1, 1, 1],
            children: [.pane(a), .pane(b), .pane(c)]))
        let rect = CGRect(x: 0, y: 0, width: 302, height: 100)
        let moved = layout.movingDivider(at: [], index: 0, to: 50, in: rect, dividerThickness: 1, scale: 1, minimumSize: 20)
        let g = moved.geometry(in: rect, dividerThickness: 1, scale: 1)
        XCTAssertEqual(g.panes[a]?.width, 50)
        XCTAssertEqual(g.panes[c]?.width, layout.geometry(in: rect, dividerThickness: 1, scale: 1).panes[c]?.width,
                       "不相邻的分支不动")
        let clamped = layout.movingDivider(at: [], index: 0, to: -500, in: rect, dividerThickness: 1, scale: 1, minimumSize: 20)
        XCTAssertEqual(clamped.geometry(in: rect, dividerThickness: 1, scale: 1).panes[a]?.width, 20, "不小于最小尺寸")
    }

    func testResizingPushesTheNearestSameAxisBoundary() throws {
        // [a | [b / c]]：c 向左推 → 动的是外层竖线；c 向右 → 已贴边，不动。
        let layout = try XCTUnwrap(PaneLayout.pane(a).inserting(b, beside: a, edge: .right)?
            .inserting(c, beside: b, edge: .bottom))
        let rect = CGRect(x: 0, y: 0, width: 201, height: 101)
        let before = layout.geometry(in: rect, dividerThickness: 1, scale: 1)
        let pushed = layout.resizing(c, toward: .left, by: 30, in: rect, dividerThickness: 1, scale: 1, minimumSize: 10)
        XCTAssertEqual(pushed.geometry(in: rect, dividerThickness: 1, scale: 1).panes[a]?.width,
                       (before.panes[a]?.width ?? 0) - 30)
        XCTAssertEqual(layout.resizing(c, toward: .right, by: 30, in: rect, dividerThickness: 1, scale: 1, minimumSize: 10),
                       layout, "那一侧没有兄弟：与 Ghostty 一致不动，也不往上找")
        let grown = layout.resizing(b, toward: .bottom, by: 10, in: rect, dividerThickness: 1, scale: 1, minimumSize: 10)
        XCTAssertEqual(grown.geometry(in: rect, dividerThickness: 1, scale: 1).panes[b]?.height,
                       (before.panes[b]?.height ?? 0) + 10)
    }

    // MARK: - 窗口级编排

    private func tab(_ layout: PaneLayout, id: UUID = UUID()) -> TabLayout { TabLayout(id: id, layout: layout) }

    func testMergingThenDetachingRoundTripsWithoutLosingAPane() throws {
        // 用户实际的操作：终端43（a）并进 TestFlight（b）所在标签页，再拆出来放回第 0 位。
        let t0 = UUID(), t1 = UUID(), fresh = UUID()
        let start = [tab(.pane(a), id: t0), tab(.pane(b), id: t1)]
        let merged = try XCTUnwrap(TabArrangement.movingPane(a, beside: b, edge: .right, in: start))
        XCTAssertEqual(merged.map(\.id), [t1], "a 原来的标签页移空后消失")
        XCTAssertEqual(merged[0].layout.panes, [b, a])

        let detached = try XCTUnwrap(TabArrangement.detachingPane(a, toNewTab: fresh, at: 0, in: merged))
        XCTAssertEqual(detached.map(\.id), [fresh, t1])
        XCTAssertEqual(detached[0].layout, .pane(a))
        XCTAssertEqual(detached[1].layout, .pane(b))
        XCTAssertEqual(Set(detached.flatMap(\.layout.panes)), [a, b], "一个 pane 都不会丢")
    }

    func testMovingIntoATabAppendsAfterItsLastPane() throws {
        let t0 = UUID(), t1 = UUID()
        let tabs = [tab(.pane(a), id: t0), tab(try XCTUnwrap(PaneLayout.pane(b).inserting(c, beside: b, edge: .bottom)), id: t1)]
        let moved = try XCTUnwrap(TabArrangement.movingPane(a, intoTab: t1, in: tabs))
        XCTAssertEqual(moved.map(\.id), [t1])
        XCTAssertEqual(moved[0].layout.panes, [b, c, a])
        XCTAssertNil(TabArrangement.movingPane(a, intoTab: t0, in: tabs), "本来就独占这个标签页")
        XCTAssertNil(TabArrangement.movingPane(a, intoTab: UUID(), in: tabs))
    }

    func testInvalidCommandsProduceNothing() throws {
        let t0 = UUID()
        let tabs = [tab(.pane(a), id: t0), tab(.pane(b))]
        XCTAssertNil(TabArrangement.movingPane(a, beside: a, edge: .right, in: tabs))
        XCTAssertNil(TabArrangement.movingPane(c, beside: a, edge: .right, in: tabs), "源 pane 不存在")
        XCTAssertNil(TabArrangement.movingPane(a, beside: c, edge: .right, in: tabs), "目标 pane 不存在")
        XCTAssertNil(TabArrangement.detachingPane(a, toNewTab: UUID(), at: 0, in: tabs), "独占标签页拆不出东西")
        XCTAssertNil(TabArrangement.detachingPane(a, toNewTab: t0, at: 0, in: [tab(try XCTUnwrap(PaneLayout.pane(a).inserting(d, beside: a, edge: .right)), id: t0)]),
                     "新标签页的身份不能与现有标签页撞")
        XCTAssertNil(TabArrangement.movingTab(from: 1, to: 1, in: tabs))
        XCTAssertNil(TabArrangement.movingTab(from: 5, to: 0, in: tabs))
    }

    func testMovingTabsAndClampingInsertionPoints() throws {
        let ids = [UUID(), UUID(), UUID()]
        let tabs = ids.map { tab(.pane(UUID()), id: $0) }
        XCTAssertEqual(TabArrangement.movingTab(from: 0, to: 9, in: tabs)?.map(\.id), [ids[1], ids[2], ids[0]])
        let split = [tab(try XCTUnwrap(PaneLayout.pane(a).inserting(b, beside: a, edge: .right)))] + tabs
        let fresh = UUID()
        XCTAssertEqual(TabArrangement.detachingPane(b, toNewTab: fresh, at: 99, in: split)?.last?.id, fresh)
    }
}
