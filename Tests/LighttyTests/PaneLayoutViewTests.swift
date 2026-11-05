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
        ensureTerminalRuntime()
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
}
