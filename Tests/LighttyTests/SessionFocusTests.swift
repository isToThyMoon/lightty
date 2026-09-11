import AppKit
import LighttyCore
import Testing
@testable import lightty

private struct FocusCatalog: SessionCatalogProvider {
    let source: SessionCatalogSource
    func page(archived: Bool, cursor: String?, cancelled: () -> Bool) throws -> SessionCatalogPage {
        .init(sessions: archived ? [] : [.init(key: .init(agent: .claude, sourceRoot: source.root.path,
            nativeID: "focus-fixture"), title: "Focus fixture", workingDirectory: nil, updatedAt: nil)], nextCursor: nil)
    }
}

extension SessionAssociationTests {
@Test func clearTabsResetsOnlyCurrentWindowNumbering() {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let previous = AppState.shared
    AppState.shared = AppState(taskDirectory: root, sweepStalePanes: false)
    defer {
        AppState.shared = previous ?? AppState.shared
        try? FileManager.default.removeItem(at: root)
    }
    if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }
    let first = TerminalWindowController()
    let other = TerminalWindowController()
    defer { first.window?.close(); other.window?.close() }
    first.addTab(initialPane: PaneView())
    let otherTitles = other.snapshot()?.tabs.map(\.title)
    let otherNames = other.panes().map { $0.snapshot().name }
    first.clearTabs()
    #expect(first.snapshot() == nil)
    #expect(first.panes().isEmpty)
    #expect(other.snapshot()?.tabs.map(\.title) == otherTitles)
    #expect(other.panes().map { $0.snapshot().name } == otherNames)
    first.addTab(initialPane: PaneView())
    #expect(first.snapshot()?.tabs.first?.title == L("Tab %d", 1))
    #expect(first.panes().first?.snapshot().name == L("Terminal %d", 1))
    first.addTab(initialPane: PaneView())
    #expect(first.snapshot()?.tabs.last?.title == L("Tab %d", 2))
    #expect(first.panes().last?.snapshot().name == L("Terminal %d", 2))
}

@MainActor
@Test func sessionSelectionFollowsTabInsteadOfLastClick() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let previous = AppState.shared
    defer { AppState.shared = previous ?? AppState.shared; try? FileManager.default.removeItem(at: root) }
    let library = SessionLibrary(fileURL: root.appendingPathComponent("organization.json"),
        providers: [FocusCatalog(source: .init(agent: .claude, root: root, executable: "/bin/false"))])
    AppState.shared = AppState(taskDirectory: root, sweepStalePanes: false, sessionLibrary: library)
    if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }
    let controller = TerminalWindowController()
    AppState.shared.windowControllers = [controller]
    defer { controller.window?.close() }
    let content = SessionsSidebarContent(library: library)
    controller.window?.contentView?.addSubview(content)
    content.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
    library.start()
    content.activate()
    let deadline = Date().addingTimeInterval(2)
    while (!library.loaded || library.loading) && Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    // 循环在 `loading` 转 false 的那一刻就退出，而那之后才广播通知；会话库的通知
    // 合流到下一拍再重算（见 `Coalescer`），所以这里必须再让出一拍，否则读到的
    // 还是上一轮的行。真实 app 里主 runloop 一直在转，这一拍是几微秒。
    try await Task.sleep(for: .milliseconds(50))
    func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    let table = try #require(descendants(content).compactMap { $0 as? NSTableView }.first)
    func expectSelection(_ row: Int) async throws {
        let deadline = Date().addingTimeInterval(1)
        while table.selectedRow != row, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(table.selectedRow == row)
    }
    let record = try #require(library.records.first)
    let pane = try #require(controller.activePane)
    pane.associateSession(.init(key: record.key, configuration: .custom(root.path), workingDirectory: root.path))
    controller.selectTab(at: 0)
    // Simulate the old click-owned selection, then switch to an unrelated shell.
    table.selectRowIndexes([table.numberOfRows - 1], byExtendingSelection: false)
    controller.addTab(initialPane: PaneView(), installPane: false)
    try await expectSelection(-1)
    controller.selectTab(at: 0)
    try await expectSelection(table.numberOfRows - 1)
    controller.selectTab(at: 1)
    var showedModal = false
    let watchdog = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
        if NSApp.modalWindow != nil { showedModal = true; NSApp.abortModal() }
    }
    SessionResumeFlow.open(record, source: .init(agent: .claude, root: root, executable: "/bin/false"),
        in: controller)
    watchdog.invalidate()
    #expect(!showedModal, "An internal terminal must be focused without a confirmation dialog")
    #expect(controller.activePane === pane)
    #expect(controller.tabCount == 2)
    let openCell = try #require(content.tableView(table, viewFor: table.tableColumns.first, row: table.numberOfRows - 1))
    #expect(descendants(openCell).compactMap { $0 as? NSTextField }
        .contains { $0.stringValue.contains(L("Open in lightty")) })
    pane.terminal.commandFinished(at: Date())
    try await expectSelection(-1)
    #expect(pane.displayedSessionKey == nil)
    #expect(!pane.snapshot().agentAlive)
    pane.associateSession(.init(key: record.key, configuration: .custom(root.path), workingDirectory: root.path))
    try await expectSelection(table.numberOfRows - 1)
    // Same Agent and native ID in a different source must not match.
    pane.associateSession(.init(key: .init(agent: .claude, sourceRoot: root.appendingPathComponent("other").path,
        nativeID: record.key.nativeID), configuration: .custom(root.appendingPathComponent("other").path), workingDirectory: root.path))
    try await expectSelection(-1)
    pane.associateSession(.init(key: record.key, configuration: .custom(root.path), workingDirectory: root.path))
    try await expectSelection(table.numberOfRows - 1)
    // Split focus also clears selection when the focused pane is an ordinary shell.
    let split = PaneView()
    controller.addPaneToActiveTab(split)
    split.terminal.onFocusChange?(true)
    try await expectSelection(-1)
    controller.reveal(pane: pane)
    pane.terminal.onFocusChange?(true)
    try await expectSelection(table.numberOfRows - 1)
    controller.closeTab(at: 0)
    try await expectSelection(-1)
    let closedCell = try #require(content.tableView(table, viewFor: table.tableColumns.first, row: table.numberOfRows - 1))
    #expect(!descendants(closedCell).compactMap { $0 as? NSTextField }
        .contains { $0.stringValue.contains(L("Open in lightty")) })
    #expect(library.loading == false, "Focus changes must not query the catalog")
    let count = controller.tabCount
    let resumable = AgentSession(key: record.key, title: record.title, workingDirectory: root.path, updatedAt: nil)
    SessionResumeFlow.open(resumable, source: .init(agent: .claude, root: root, executable: "/bin/echo"), in: controller)
    let openDeadline = Date().addingTimeInterval(4)
    while controller.tabCount == count && Date() < openDeadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(controller.tabCount == count + 1, "An ended/closed binding must not intercept a new resume")
    #expect(controller.activePane !== pane)
}
}
