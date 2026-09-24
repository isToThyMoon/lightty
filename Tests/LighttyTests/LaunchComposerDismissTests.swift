import AppKit
import XCTest
@testable import lightty

/// 启动浮层开着时点它外面的控件：浮层要关，那一下点击也要落到控件上。
/// 用户碰到的形状是：浮层开着，点任务行的「⋯」，第一下只关浮层，第二下才出菜单。
@MainActor
final class LaunchComposerDismissTests: XCTestCase {
    private final class MenuTarget: NSObject {
        var fired = 0
        @objc func showMenu(_ sender: NSButton) {
            fired += 1
            ShellMenuPopover.present(from: sender, items: [.action("One") {}])
        }
    }

    private var directory: URL!
    private var window: NSWindow!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-dismiss-\(UUID().uuidString)")
        AppState.shared = AppState(taskDirectory: directory, sweepStalePanes: false)
        ensureTerminalRuntime()
        let controller = TerminalWindowController()
        window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFrontInvisibly()
        let anchor = NSView(frame: NSRect(x: 20, y: 400, width: 100, height: 30))
        window.contentView?.addSubview(anchor)
        LaunchComposer.begin(.session, from: anchor, in: controller)
        try waitUntil("composer shown") { LaunchComposer.isPresented }
    }

    override func tearDown() {
        ShellMenuPopover.dismiss()
        LaunchComposer.dismiss()
        window.orderOut(nil)
        try? FileManager.default.removeItem(at: directory)
    }

    func testClickOnAnotherControlClosesComposerAndStillOpensItsMenu() throws {
        let target = MenuTarget()
        let button = ShellIconButton(symbol: "ellipsis", accessibilityLabel: "More actions",
                                     target: target, action: #selector(MenuTarget.showMenu(_:)))
        button.frame = NSRect(x: 20, y: 100, width: 26, height: 26)
        window.contentView?.addSubview(button)

        try click(at: button.convert(NSPoint(x: 13, y: 13), to: nil), in: window)

        try waitUntil("composer closed") { !LaunchComposer.isPresented }
        XCTAssertEqual(target.fired, 1, "the click that closes the composer must still reach the button")
        // 浮层关闭有淡出动画，窗口在动画结束后才真正走掉；菜单得撑过那一刻。
        try waitUntil("popover window gone") { Self.popoverWindow() == nil }
        XCTAssertTrue(ShellMenuPopover.isPresented, "the menu opened by that click must stay open")
    }

    func testClickInsideTheComposerKeepsItOpen() throws {
        let composer = try XCTUnwrap(Self.popoverWindow())
        let content = try XCTUnwrap(composer.contentView)
        try click(at: content.convert(NSPoint(x: content.bounds.midX, y: content.bounds.midY), to: nil),
                  in: composer)
        // 关闭是在事件监视器里同步做的；排空一拍只是不让「延后关闭」这种回归溜过去。
        try drainMainQueue()
        XCTAssertTrue(LaunchComposer.isPresented, "a click inside the composer is not a dismissal")
    }

    /// 锚在列表行上的浮层，列表一滚就收：行视图滚出去会被表格复用给别的行，
    /// 箭头就指错了条目。
    func testScrollingTheAnchorsListClosesComposer() throws {
        LaunchComposer.dismiss()
        let controller = try XCTUnwrap(window.windowController as? TerminalWindowController)
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 100, width: 200, height: 300))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 1200))
        scroll.documentView = document
        window.contentView?.addSubview(scroll)
        let row = NSView(frame: NSRect(x: 0, y: 1000, width: 200, height: 40))
        document.addSubview(row)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 900))
        LaunchComposer.begin(.session, from: row, in: controller)
        try waitUntil("composer shown") { LaunchComposer.isPresented }

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 700))
        try waitUntil("composer closed") { !LaunchComposer.isPresented }
    }

    /// 按下走 `NSApp.sendEvent`，让本地事件监视器看到它；抬起先排进队列，
    /// 供按钮的跟踪循环取走。
    private func click(at point: NSPoint, in window: NSWindow) throws {
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: up.timestamp,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        NSApp.postEvent(up, atStart: true)
        NSApp.sendEvent(down)
    }

    /// NSPopover 的窗口是私有类，只能认类名（与 ShellMenuPopover 同一做法）。
    private static func popoverWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && NSStringFromClass(type(of: $0)).contains("Popover") }
    }
}
