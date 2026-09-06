import AppKit
import Testing
@testable import lightty

@MainActor
@Test func dockMenuUsesLiveTabIdentity() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let previousState = AppState.shared
    defer {
        AppState.shared = previousState
        try? FileManager.default.removeItem(at: directory)
    }
    AppState.shared = AppState(taskDirectory: directory, sweepStalePanes: false)
    if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }
    let controller = TerminalWindowController()
    AppState.shared.windowControllers = [controller]
    defer { controller.window?.close() }
    controller.renameTab(at: 0, to: "First")
    controller.addTab(initialPane: PaneView(), installPane: false)
    controller.renameTab(at: 1, to: "Second")
    let delegate = AppDelegate()
    let menu = try #require(delegate.applicationDockMenu(NSApp))
    #expect(menu.items.prefix(2).map(\.title) == [L("New Window"), L("New Tab")])
    #expect(menu.items.suffix(2).map(\.title) == ["First", "Second"])
    let item = try #require(menu.items.first { $0.title == "First" })
    controller.moveActiveTab(by: -1)
    #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
    #expect(controller.window?.title == "First")
    controller.renameTab(at: 1, to: "Renamed")
    let updated = try #require(delegate.applicationDockMenu(NSApp))
    #expect(updated.items.suffix(2).map(\.title) == ["Second", "Renamed"])
    controller.closeTab(at: 1)
    // An old menu item must not select a different tab after its target is closed.
    _ = NSApp.sendAction(try #require(item.action), to: item.target, from: item)
    #expect(controller.window?.title == "Second")
}
