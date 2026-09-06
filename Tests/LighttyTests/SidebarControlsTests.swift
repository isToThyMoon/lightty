import AppKit
import XCTest
@testable import lightty

@MainActor
final class SidebarControlsTests: XCTestCase {
    /// 默认布局：task 侧栏（核心）打开、工作区侧栏收起。
    func testInitialWindowOpensTaskPanel() throws {
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

        // 默认打开 task 侧栏，其关闭钮以窗口边界中线为纵向基准。
        let taskPanel = try XCTUnwrap(
            themeFrame.subviews.compactMap { $0 as? TaskSidebar }.first,
            "默认应打开 task 侧栏")
        XCTAssertTrue(taskPanel.closeControl.superview === themeFrame)
        XCTAssertEqual(
            taskPanel.closeControl.frame.midY, themeFrame.bounds.midY, accuracy: 0.5)
        let closeControlMidY = taskPanel.closeControl.frame.midY

        // 默认工作区侧栏收起。
        XCTAssertNil(
            themeFrame.subviews.compactMap { $0 as? WorkspaceSidebarView }.first,
            "默认工作区侧栏应关闭")

        _ = closeControlMidY
        // task 开着时不应再有左缘展开钮（它只在 task 关闭时出现）。
        let extraEdgeControls = themeFrame.subviews
            .compactMap { $0 as? EdgeToggleControl }
            .filter { $0 !== taskPanel.closeControl }
        XCTAssertTrue(extraEdgeControls.isEmpty, "task 开着时不应有左缘展开钮")

        // 工作区侧栏按需打开后，分屏 / 新建工作区按钮齐备。
        controller.openWorkspaceSidebar(animated: false)
        themeFrame.layoutSubtreeIfNeeded()
        let sidebar = try XCTUnwrap(
            themeFrame.subviews.compactMap { $0 as? WorkspaceSidebarView }.first)
        let sidebarToolTips = descendantToolTips(of: sidebar)
        XCTAssertTrue(sidebarToolTips.contains(L("Split right")))
        XCTAssertTrue(sidebarToolTips.contains(L("Split down")))
        XCTAssertTrue(sidebarToolTips.contains(L("New workspace")))
    }

    private func descendantToolTips(of view: NSView) -> [String] {
        view.subviews.flatMap { child in
            [child.toolTip].compactMap { $0 } + descendantToolTips(of: child)
        }
    }
}
