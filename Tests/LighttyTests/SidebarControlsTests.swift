import AppKit
import XCTest
@testable import lightty

@MainActor
final class SidebarControlsTests: XCTestCase {
    func testOpeningTabSidebarWithDetachedTrafficLightsKeepsContentInsideWindow() throws {
        let taskDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sidebar-detached-titlebar-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: taskDirectory) }
        _ = NSApplication.shared
        AppState.shared = AppState(taskDirectory: taskDirectory, sweepStalePanes: false)
        if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }
        let controller = TerminalWindowController()
        let window = try XCTUnwrap(controller.window)
        let host = try XCTUnwrap(window.contentView?.superview)
        let deadline = Date(timeIntervalSinceNow: 2)
        while !host.subviews.contains(where: { $0 is PrimarySidebar }), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        // 收敛初始任务侧栏动画；仅任务侧栏打开是实际复现的前置状态。
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
        host.layoutSubtreeIfNeeded()
        let pane = try XCTUnwrap(controller.panes().first)
        let terminalBefore = pane.terminal.convert(pane.terminal.bounds, to: host)
        let zoom = try XCTUnwrap(window.standardWindowButton(.zoomButton))
        let originalParent = try XCTUnwrap(zoom.superview)
        let originalFrame = zoom.frame
        let detachedTitlebar = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 32))
        detachedTitlebar.addSubview(zoom)
        zoom.frame = NSRect(x: 55, y: 9, width: 14, height: 14)
        defer {
            originalParent.addSubview(zoom)
            zoom.frame = originalFrame
        }
        XCTAssertNil(zoom.window)
        XCTAssertTrue(window.standardWindowButton(.zoomButton) === zoom)

        controller.openTabSidebar(animated: false)
        host.layoutSubtreeIfNeeded()

        let sidebar = try XCTUnwrap(host.subviews.compactMap { $0 as? TabSidebarView }.first)
        let newTab = try XCTUnwrap(descendantIconButtons(of: sidebar).first {
            $0.toolTip == L("New tab")
        })
        let header = newTab.convert(newTab.bounds, to: host)
        XCTAssertLessThan(host.bounds.maxY - header.maxY, 80,
                          "Detached titlebar coordinates must not move the sidebar header to the bottom")
        let terminalAfter = pane.terminal.convert(pane.terminal.bounds, to: host)
        XCTAssertEqual(terminalAfter.maxY, terminalBefore.maxY, accuracy: 0.5,
                       "Opening a horizontal sidebar must preserve the terminal top")
        XCTAssertTrue(host.bounds.contains(terminalAfter), "Terminal must remain inside the window")
    }

    /// 默认布局：task 侧栏（核心）打开、标签页侧栏收起。
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
        // 轮询而不是固定睡 50ms：整套测试跑起来主队列可能排着别的事，固定时长会偶发。
        let deadline = Date(timeIntervalSinceNow: 2)
        while themeFrame.subviews.first(where: { $0 is PrimarySidebar }) == nil, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        themeFrame.layoutSubtreeIfNeeded()

        // 默认打开 task 侧栏。
        let taskPanel = try XCTUnwrap(
            themeFrame.subviews.compactMap { $0 as? PrimarySidebar }.first,
            "默认应打开 task 侧栏")

        // 卡片从窗口顶边起（只留 panelInset），把红绿灯收进自己的头部行；
        // 头部行右端是收起卡片的 sidebar.left 按钮，标题栏那枚随之隐藏。
        XCTAssertEqual(
            taskPanel.frame.maxY, themeFrame.bounds.maxY - ShellStyle.panelInset, accuracy: 0.5)
        XCTAssertTrue(descendantToolTips(of: taskPanel).contains(L("Primary sidebar")))
        let titlebarToggles = themeFrame.subviews
            .filter { !($0 is PrimarySidebar) }
            .flatMap { descendantIconButtons(of: $0) }
            .filter { $0.toolTip == L("Task Sidebar") }
        XCTAssertFalse(titlebarToggles.isEmpty, "标题栏应仍装有 task 开关（只是隐藏）")
        XCTAssertTrue(titlebarToggles.allSatisfy(\.isHidden), "task 开着时标题栏开关应隐藏")

        // 默认标签页侧栏收起；其展开钮吸在主区左缘（task 卡片让位线）中点。
        XCTAssertNil(
            themeFrame.subviews.compactMap { $0 as? TabSidebarView }.first,
            "默认标签页侧栏应关闭")
        let expandControls = themeFrame.subviews.compactMap { $0 as? EdgeToggleControl }
        XCTAssertEqual(expandControls.count, 1, "应只有一枚标签页展开钮")
        let expand = try XCTUnwrap(expandControls.first)
        XCTAssertEqual(
            expand.frame.minX, ShellStyle.taskPanelWidth + ShellStyle.panelInset * 2,
            accuracy: 0.5)
        XCTAssertEqual(expand.frame.midY, themeFrame.bounds.midY, accuracy: 0.5)

        // 标签页侧栏打开后：分屏 / 新建标签页按钮齐备，关闭钮吸在侧栏右边线。
        controller.openTabSidebar(animated: false)
        themeFrame.layoutSubtreeIfNeeded()
        let sidebar = try XCTUnwrap(
            themeFrame.subviews.compactMap { $0 as? TabSidebarView }.first)
        let sidebarToolTips = descendantToolTips(of: sidebar)
        XCTAssertTrue(sidebarToolTips.contains(L("Split right")))
        XCTAssertTrue(sidebarToolTips.contains(L("Split down")))
        XCTAssertTrue(sidebarToolTips.contains(L("New tab")))
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
