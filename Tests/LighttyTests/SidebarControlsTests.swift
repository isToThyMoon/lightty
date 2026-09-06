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

        // 默认打开 task 侧栏。
        let taskPanel = try XCTUnwrap(
            themeFrame.subviews.compactMap { $0 as? TaskSidebar }.first,
            "默认应打开 task 侧栏")

        // 卡片从窗口顶边起（只留 panelInset），把红绿灯收进自己的头部行；
        // 头部行右端是收起卡片的 sidebar.left 按钮，标题栏那枚随之隐藏。
        XCTAssertEqual(
            taskPanel.frame.maxY, themeFrame.bounds.maxY - ShellStyle.panelInset, accuracy: 0.5)
        XCTAssertTrue(descendantToolTips(of: taskPanel).contains(L("Task Sidebar")))
        let titlebarToggles = themeFrame.subviews
            .filter { !($0 is TaskSidebar) }
            .flatMap { descendantIconButtons(of: $0) }
            .filter { $0.toolTip == L("Task Sidebar") }
        XCTAssertFalse(titlebarToggles.isEmpty, "标题栏应仍装有 task 开关（只是隐藏）")
        XCTAssertTrue(titlebarToggles.allSatisfy(\.isHidden), "task 开着时标题栏开关应隐藏")

        // 默认工作区侧栏收起；其展开钮吸在主区左缘（task 卡片让位线）中点。
        XCTAssertNil(
            themeFrame.subviews.compactMap { $0 as? WorkspaceSidebarView }.first,
            "默认工作区侧栏应关闭")
        let expandControls = themeFrame.subviews.compactMap { $0 as? EdgeToggleControl }
        XCTAssertEqual(expandControls.count, 1, "应只有一枚工作区展开钮")
        let expand = try XCTUnwrap(expandControls.first)
        XCTAssertEqual(
            expand.frame.minX, ShellStyle.taskPanelWidth + ShellStyle.panelInset * 2,
            accuracy: 0.5)
        XCTAssertEqual(expand.frame.midY, themeFrame.bounds.midY, accuracy: 0.5)

        // 工作区侧栏打开后：分屏 / 新建工作区按钮齐备，关闭钮吸在侧栏右边线。
        controller.openWorkspaceSidebar(animated: false)
        themeFrame.layoutSubtreeIfNeeded()
        let sidebar = try XCTUnwrap(
            themeFrame.subviews.compactMap { $0 as? WorkspaceSidebarView }.first)
        let sidebarToolTips = descendantToolTips(of: sidebar)
        XCTAssertTrue(sidebarToolTips.contains(L("Split right")))
        XCTAssertTrue(sidebarToolTips.contains(L("Split down")))
        XCTAssertTrue(sidebarToolTips.contains(L("New workspace")))
        let closeControls = themeFrame.subviews.compactMap { $0 as? EdgeToggleControl }
        XCTAssertEqual(closeControls.count, 1, "侧栏开着时应只剩一枚关闭钮")
        XCTAssertEqual(
            try XCTUnwrap(closeControls.first).frame.maxX, sidebar.frame.maxX, accuracy: 0.5)
    }

    private func descendantIconButtons(of view: NSView) -> [ShellIconButton] {
        view.subviews.flatMap { child in
            [child as? ShellIconButton].compactMap { $0 } + descendantIconButtons(of: child)
        }
    }

    private func descendantToolTips(of view: NSView) -> [String] {
        view.subviews.flatMap { child in
            [child.toolTip].compactMap { $0 } + descendantToolTips(of: child)
        }
    }
}
