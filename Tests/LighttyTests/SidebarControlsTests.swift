import AppKit
import XCTest
@testable import lightty

@MainActor
final class SidebarControlsTests: XCTestCase {
    func testInitialWindowShowsTaskExpandControl() throws {
        let taskDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sidebar-controls-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: taskDirectory) }

        _ = NSApplication.shared
        AppState.shared = AppState(taskDirectory: taskDirectory, sweepStalePanes: false)
        if GhosttyRuntime.shared == nil {
            GhosttyRuntime.shared = GhosttyRuntime()
        }

        let controller = TerminalWindowController()
        let window = try XCTUnwrap(controller.window)
        let themeFrame = try XCTUnwrap(window.contentView?.superview)

        XCTAssertTrue(
            window.styleMask.contains(.fullSizeContentView),
            "terminal content 应铺到窗口四边")

        // TerminalWindowController finishes installing its initial chrome on the
        // next main-run-loop turn, after AppKit has settled the private titlebar tree.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        themeFrame.layoutSubtreeIfNeeded()

        let controls = themeFrame.subviews.compactMap { $0 as? EdgeToggleControl }
        let control = try XCTUnwrap(
            controls.first,
            "task 关闭时，窗口左缘应安装展开钮")

        XCTAssertFalse(control.isHidden)
        XCTAssertGreaterThan(control.alphaValue, 0)
        XCTAssertEqual(control.frame.minX, themeFrame.bounds.minX, accuracy: 0.5)
        XCTAssertEqual(control.frame.width, 12, accuracy: 0.5)
        let expandControlMidY = control.frame.midY

        control.onTap?()
        themeFrame.layoutSubtreeIfNeeded()

        let taskPanel = try XCTUnwrap(
            themeFrame.subviews.compactMap { $0 as? TaskSidebar }.first)
        XCTAssertTrue(taskPanel.closeControl.superview === themeFrame)
        XCTAssertEqual(
            taskPanel.closeControl.frame.midY,
            expandControlMidY,
            accuracy: 0.5,
            "task 开关前后应共用窗口边界中线")
        XCTAssertEqual(
            taskPanel.closeControl.frame.midY,
            themeFrame.bounds.midY,
            accuracy: 0.5)

        let sidebar = try XCTUnwrap(
            themeFrame.subviews.compactMap { $0 as? WorkspaceSidebarView }.first)
        let sidebarToolTips = descendantToolTips(of: sidebar)
        XCTAssertTrue(sidebarToolTips.contains(L("Split right")))
        XCTAssertTrue(sidebarToolTips.contains(L("Split down")))
        XCTAssertTrue(sidebarToolTips.contains(L("New workspace")))

        taskPanel.closeControl.onTap?()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
    }

    private func descendantToolTips(of view: NSView) -> [String] {
        view.subviews.flatMap { child in
            [child.toolTip].compactMap { $0 } + descendantToolTips(of: child)
        }
    }
}
