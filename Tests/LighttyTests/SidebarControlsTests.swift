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
        let library = SessionLibrary(fileURL: taskDirectory.appendingPathComponent("sessions.json"),
            providers: [SidebarSnapshotCatalog(source: .init(agent: .codex, root: taskDirectory, executable: "/bin/false", configuration: .custom(taskDirectory.path))),
                        SidebarSnapshotCatalog(source: .init(agent: .claude, root: taskDirectory, executable: "/bin/false", configuration: .custom(taskDirectory.path)))])
        AppState.shared = AppState(taskDirectory: taskDirectory, sweepStalePanes: false, sessionLibrary: library)
        ensureTerminalRuntime()
        let controller = TerminalWindowController()
        let window = try XCTUnwrap(controller.window)
        let host = try XCTUnwrap(window.contentView?.superview)
        // 仅任务侧栏打开、且已滑到位，是实际复现的前置状态。
        try controller.waitForInitialLayout()
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
        let library = SessionLibrary(fileURL: taskDirectory.appendingPathComponent("sessions.json"),
            providers: [SidebarSnapshotCatalog(source: .init(agent: .codex, root: taskDirectory, executable: "/bin/false", configuration: .custom(taskDirectory.path))),
                        SidebarSnapshotCatalog(source: .init(agent: .claude, root: taskDirectory, executable: "/bin/false", configuration: .custom(taskDirectory.path)))])
        AppState.shared = AppState(taskDirectory: taskDirectory, sweepStalePanes: false, sessionLibrary: library)
        ensureTerminalRuntime()

        let controller = TerminalWindowController()
        let window = try XCTUnwrap(controller.window)
        let themeFrame = try XCTUnwrap(window.contentView?.superview)

        XCTAssertTrue(
            window.styleMask.contains(.fullSizeContentView),
            "terminal content 应铺到窗口四边")

        // TerminalWindowController finishes installing its initial chrome on the
        // next main-run-loop turn, after AppKit has settled the private titlebar tree.
        // 轮询而不是固定睡 50ms：整套测试跑起来主队列可能排着别的事，固定时长会偶发。
        try waitUntil("primary sidebar installed") { themeFrame.subviews.contains(where: { $0 is PrimarySidebar }) }
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

        controller.showSettings()
        XCTAssertFalse(expand.isHidden)
        let settings = try XCTUnwrap(themeFrame.subviews.first { $0 is SettingsView })
        let settingsIndex = try XCTUnwrap(themeFrame.subviews.firstIndex(of: settings))
        for control in themeFrame.subviews where control is EdgeToggleControl || control is EdgeRevealStrip {
            XCTAssertLessThan(try XCTUnwrap(themeFrame.subviews.firstIndex(of: control)), settingsIndex)
        }
        controller.hideSettings()
        XCTAssertFalse(expand.isHidden)

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
        controller.showSettings()
        let openSettings = try XCTUnwrap(themeFrame.subviews.first { $0 is SettingsView })
        for control in closeControls {
            XCTAssertFalse(control.isHidden)
            XCTAssertLessThan(try XCTUnwrap(themeFrame.subviews.firstIndex(of: control)),
                              try XCTUnwrap(themeFrame.subviews.firstIndex(of: openSettings)))
        }
        controller.hideSettings()
        XCTAssertTrue(closeControls.allSatisfy { !$0.isHidden })
        XCTAssertEqual(
            try XCTUnwrap(closeControls.first).frame.maxX, sidebar.frame.maxX, accuracy: 0.5)
        let tabIDs = controller.tabOverview().map(\.id)
        let paneIDs = controller.panes().map(\.dragIdentifier)
        let activePane = controller.activePane
        taskPanel.selectMode(.sessions, animated: false)
        taskPanel.selectMode(.handoff, animated: false)
        XCTAssertEqual(controller.tabOverview().map(\.id), tabIDs)
        XCTAssertEqual(controller.panes().map(\.dragIdentifier), paneIDs)
        XCTAssertTrue(controller.activePane === activePane, "切换资料模式不改变终端现场")
        if let directory = ProcessInfo.processInfo.environment["LIGHTTY_UI_SNAPSHOT_DIR"] {
            try captureSidebarVariants(controller, panel: taskPanel, directory: URL(fileURLWithPath: directory))
        }
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
