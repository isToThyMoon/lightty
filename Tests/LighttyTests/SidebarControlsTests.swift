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
        let statusStore = PaneStatusStore(socketPath: URL(fileURLWithPath: "/tmp/lightty-t-\(UInt32.random(in: 0...0xFFFF_FFFF)).sock"))
        defer { statusStore.stop() }
        let library = SessionLibrary(fileURL: taskDirectory.appendingPathComponent("sessions.json"),
            providers: [SidebarSnapshotCatalog(source: .init(agent: .codex, root: taskDirectory, executable: "/bin/false", configuration: .custom(taskDirectory.path))),
                        SidebarSnapshotCatalog(source: .init(agent: .claude, root: taskDirectory, executable: "/bin/false", configuration: .custom(taskDirectory.path)))],
            statusStore: statusStore)
        AppState.shared = AppState(taskDirectory: taskDirectory, sweepStalePanes: false, sessionLibrary: library)
        ensureTerminalRuntime()

        let controller = TerminalWindowController()
        let window = try XCTUnwrap(controller.window)
        let themeFrame = try XCTUnwrap(window.contentView?.superview)


        // TerminalWindowController finishes installing its initial chrome on the
        // next main-run-loop turn, after AppKit has settled the private titlebar tree.
        // 轮询而不是固定睡 50ms：整套测试跑起来主队列可能排着别的事，固定时长会偶发。
        try waitUntil("primary sidebar installed") { themeFrame.subviews.contains(where: { $0 is PrimarySidebar }) }
        themeFrame.layoutSubtreeIfNeeded()

        // 默认打开 task 侧栏。
        let taskPanel = try XCTUnwrap(
            themeFrame.subviews.compactMap { $0 as? PrimarySidebar }.first,
            "默认应打开 task 侧栏")


        let expandControls = themeFrame.subviews.compactMap { $0 as? EdgeToggleControl }
        let expand = try XCTUnwrap(expandControls.first)

        // 拖卡片右边线：卡片、展开钮与终端主区一起收窄，头部三钮和模式切换带跟着卡片走；
        // 松手后宽度落入偏好，越过最小宽再拖则关闭。
        let pane = try XCTUnwrap(controller.panes().first)
        taskPanel.onResizeBegan?()
        taskPanel.onWidthChange?(PrimarySidebarSizing.range.minimum - 100)
        themeFrame.layoutSubtreeIfNeeded()
        XCTAssertEqual(taskPanel.frame.width, PrimarySidebarSizing.range.minimum, accuracy: 0.5, "钳到最小宽")
        let terminalAfter = pane.terminal.convert(pane.terminal.bounds, to: themeFrame)
        XCTAssertEqual(terminalAfter.minX, expand.frame.minX, accuracy: 0.5, "终端主区从展开钮所在让位线起")
        taskPanel.onWidthChange?(PrimarySidebarSizing.range.maximum + 100)
        themeFrame.layoutSubtreeIfNeeded()
        XCTAssertEqual(taskPanel.frame.width, PrimarySidebarSizing.range.maximum, accuracy: 0.5, "钳到最大宽")
        XCTAssertEqual(pane.terminal.convert(pane.terminal.bounds, to: themeFrame).minX,
                       PrimarySidebarSizing.range.maximum + ShellStyle.panelInset * 2, accuracy: 0.5)
        taskPanel.onWidthChange?(PrimarySidebarSizing.range.minimum)
        themeFrame.layoutSubtreeIfNeeded()
        taskPanel.onResizeEnded?()
        XCTAssertEqual(PrimarySidebarWidthPreference.width(), PrimarySidebarSizing.range.minimum)
        FilePreferences.shared.removeObject(forKey: PrimarySidebarWidthPreference.defaultsKey)


        controller.openTabSidebar(animated: false)
        themeFrame.layoutSubtreeIfNeeded()
        let tabIDs = controller.tabOverview().map(\.id)
        let paneIDs = controller.panes().map(\.dragIdentifier)
        let activePane = controller.activePane
        taskPanel.selectMode(.sessions, animated: false)
        taskPanel.selectMode(.handoff, animated: false)
        XCTAssertEqual(controller.tabOverview().map(\.id), tabIDs)
        XCTAssertEqual(controller.panes().map(\.dragIdentifier), paneIDs)
        XCTAssertTrue(controller.activePane === activePane, "切换资料模式不改变终端现场")
        if let directory = ProcessInfo.processInfo.environment["LIGHTTY_UI_SNAPSHOT_DIR"] {
            XCTAssertTrue(statusStore.start())
            try captureSidebarVariants(controller, panel: taskPanel, directory: URL(fileURLWithPath: directory))
        }
    }

    private func descendantIconButtons(of view: NSView) -> [ShellIconButton] {
        view.subviews.flatMap { child in
            [child as? ShellIconButton].compactMap { $0 } + descendantIconButtons(of: child)
        }
    }
}
