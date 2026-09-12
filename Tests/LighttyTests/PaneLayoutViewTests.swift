import AppKit
import LighttyCore
import XCTest
@testable import lightty

/// 标签页布局视图的渲染契约。
@MainActor
final class PaneLayoutViewTests: XCTestCase {
    private var directory: URL!
    private var window: NSWindow!

    override func setUp() {
        _ = NSApplication.shared
        if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        AppState.shared = AppState(taskDirectory: directory, sweepStalePanes: false)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    }

    override func tearDown() {
        window.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func container() -> PaneLayoutView {
        let view = PaneLayoutView()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        window.contentView?.addSubview(view)
        return view
    }

    func testAPaneMovingToAnotherContainerIsNeverDroppedFromTheWindow() {
        let source = container(), destination = container()
        let pane = PaneView(), stay = PaneView()
        let registry = [pane.dragIdentifier: pane, stay.dragIdentifier: stay]
        source.render(.pane(pane.dragIdentifier).inserting(stay.dragIdentifier, beside: pane.dragIdentifier, edge: .right),
                      zoomed: nil, panes: registry)
        XCTAssertTrue(pane.superview === source)

        // 源容器先渲染不含它的新树：它还在注册表里，要留给新容器来接，不能先摘下。
        source.render(.pane(stay.dragIdentifier), zoomed: nil, panes: registry)
        XCTAssertNotNil(pane.window, "搬家途中的 pane 不能离开窗口")
        destination.render(.pane(pane.dragIdentifier), zoomed: nil, panes: registry)
        XCTAssertTrue(pane.superview === destination)
        XCTAssertTrue(stay.superview === source)
        XCTAssertEqual(pane.frame, destination.bounds)
    }

    func testAPaneLeavingTheWindowIsDetached() {
        let view = container()
        let pane = PaneView(), other = PaneView()
        view.render(.pane(pane.dragIdentifier).inserting(other.dragIdentifier, beside: pane.dragIdentifier, edge: .bottom),
                    zoomed: nil, panes: [pane.dragIdentifier: pane, other.dragIdentifier: other])
        view.render(.pane(other.dragIdentifier), zoomed: nil, panes: [other.dragIdentifier: other])
        XCTAssertNil(pane.superview, "不在注册表里 = 被关掉或搬去别的窗口，摘掉")
        XCTAssertEqual(other.frame, view.bounds)
    }

    func testDividersSitAbovePanesAndHonourTheMinimumSize() throws {
        let view = container()
        let a = PaneView(), b = PaneView()
        let layout = try XCTUnwrap(PaneLayout.pane(a.dragIdentifier).inserting(b.dragIdentifier, beside: a.dragIdentifier, edge: .right))
        var latest = layout
        view.onLayoutChange = { next in
            latest = next
            view.render(next, zoomed: nil, panes: [a.dragIdentifier: a, b.dragIdentifier: b])
        }
        view.render(layout, zoomed: nil, panes: [a.dragIdentifier: a, b.dragIdentifier: b])
        let divider = try XCTUnwrap(view.subviews.compactMap { $0 as? PaneDividerView }.first { !$0.isHidden })
        XCTAssertGreaterThan(view.subviews.firstIndex(of: divider) ?? -1, view.subviews.firstIndex(of: a) ?? .max,
                             "分隔线的命中区压在 pane 边缘上，必须在 pane 之上")
        let onLine = NSPoint(x: divider.frame.midX, y: divider.frame.midY)
        XCTAssertTrue(view.hitTest(view.convert(onLine, to: view.superview)) === divider,
                      "线条附近的点击归分隔线，不归 pane")

        divider.onDrag?(-100)
        XCTAssertEqual(a.frame.width, PaneLayoutView.minimumPaneSize, "拖到头也不小于最小尺寸")
        XCTAssertNotEqual(latest, layout)
    }
}
