import AppKit
import LighttyCore
import Testing
@testable import lightty

private struct FocusCatalog: CatalogOnlyProvider {
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
    ensureTerminalRuntime()
    let first = TerminalWindowController()
    let other = TerminalWindowController()
    AppState.shared.windowControllers = [first, other]
    defer { first.window?.close(); other.window?.close() }
    first.addTab(initialPane: PaneView())
    let otherTitles = other.snapshot()?.tabs.map(\.title)
    let otherNames = other.panes().map { $0.snapshot().name }
    #expect(otherTitles == [L("Tab %d", 2)], "标签页默认名跨窗口全局编号")
    first.clearTabs()
    #expect(first.snapshot() == nil)
    #expect(first.panes().isEmpty)
    #expect(other.snapshot()?.tabs.map(\.title) == otherTitles)
    #expect(other.panes().map { $0.snapshot().name } == otherNames)
    // 标签页序号回落到别的窗口还在用的最大值，不与它们撞名；终端序号是窗口内的，从 1 重来。
    first.addTab(initialPane: PaneView())
    #expect(first.snapshot()?.tabs.first?.title == L("Tab %d", 3))
    #expect(first.panes().first?.snapshot().name == L("Terminal %d", 1))
    first.addTab(initialPane: PaneView())
    #expect(first.snapshot()?.tabs.last?.title == L("Tab %d", 4))
    #expect(first.panes().last?.snapshot().name == L("Terminal %d", 2))
}

/// 焦点只存一处：切换标签页、移动、关闭、跨窗口移出之后，侧栏高亮的行、会话库的选中项
/// 都等于控制器的 `activePane`，而切回一个标签页时回到它自己最近聚焦的 pane。
@MainActor
@Test func sidebarHighlightAndSessionSelectionFollowTheActivePane() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let previous = AppState.shared
    AppState.shared = AppState(taskDirectory: root, sweepStalePanes: false)
    defer { AppState.shared = previous ?? AppState.shared; try? FileManager.default.removeItem(at: root) }
    ensureTerminalRuntime()
    let source = TerminalWindowController()
    let destination = TerminalWindowController()
    AppState.shared.windowControllers = [source, destination]
    defer { source.window?.close(); destination.window?.close(); AppState.shared.windowControllers = [] }
    func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    func mount(_ controller: TerminalWindowController) throws -> TabColumnView {
        let column = TabColumnView()
        try #require(controller.window?.contentView).addSubview(column)
        column.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        return column
    }
    let column = try mount(source)
    func expectConsistent(_ expected: PaneView, _ comment: Comment,
                          sourceLocation: SourceLocation = #_sourceLocation) async throws {
        // 会话库的变更通知合流到下一拍。
        try await Task.sleep(for: .milliseconds(30))
        column.layoutSubtreeIfNeeded()
        descendants(column).compactMap { $0 as? NSTableView }.first?.layoutSubtreeIfNeeded()
        let active = source.activePane
        #expect(active === expected, comment, sourceLocation: sourceLocation)
        #expect(column.highlightedPaneIDs == active.map { [$0.dragIdentifier] }, comment, sourceLocation: sourceLocation)
        #expect(source.sessionLibrary.selectedPane(in: source.sessionWindowID) == active?.dragIdentifier,
                comment, sourceLocation: sourceLocation)
    }

    let a = try #require(source.activePane)
    source.split(a, direction: .right)
    let b = try #require(source.panes().first { $0 !== a })
    try await expectConsistent(b, "分屏出来的新 pane 拿到焦点")
    let c = PaneView()
    source.addTab(initialPane: c)
    try await expectConsistent(c, "新标签页")
    source.selectTab(at: 0)
    try await expectConsistent(b, "切回标签页，回到它自己最近聚焦的 pane，而不是第一个")
    source.reveal(pane: a)
    try await expectConsistent(a, "侧栏跳转")
    #expect(source.movePane(withID: c.dragIdentifier, to: a, zone: .right))
    try await expectConsistent(c, "移进当前标签页的 pane 拿到焦点")
    source.close(pane: c)
    try await expectConsistent(a, "关掉焦点 pane，交给同标签页第一个")
    b.focusTerminal()
    try await expectConsistent(b, "点进终端")
    let anchor = try #require(destination.activePane)
    #expect(destination.movePane(withID: b.dragIdentifier, to: anchor, zone: .right))
    try await expectConsistent(a, "焦点 pane 被移到别的窗口，源窗口的焦点由模型修正")
    #expect(destination.activePane === b)
}

@MainActor
@Test func sessionSelectionFollowsTabInsteadOfLastClick() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let previous = AppState.shared
    defer { AppState.shared = previous ?? AppState.shared; try? FileManager.default.removeItem(at: root) }
    let library = SessionLibrary(fileURL: root.appendingPathComponent("organization.json"),
        providers: [FocusCatalog(source: .init(agent: .claude, root: root, executable: "/bin/false", configuration: .custom(root.path)))])
    AppState.shared = AppState(taskDirectory: root, sweepStalePanes: false, sessionLibrary: library)
    ensureTerminalRuntime()
    let controller = TerminalWindowController()
    AppState.shared.windowControllers = [controller]
    defer { controller.window?.close() }
    let content = SessionsSidebarContent(library: library)
    controller.window?.contentView?.addSubview(content)
    content.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
    library.start()
    content.activate()
    try await awaitUntil("catalog loaded") { library.loaded && !library.loading }
    // 循环在 `loading` 转 false 的那一刻就退出，而那之后才广播通知；会话库的通知
    // 合流到下一拍再重算（见 `Coalescer`），所以这里必须再让出一拍，否则读到的
    // 还是上一轮的行。真实 app 里主 runloop 一直在转，这一拍是几微秒。
    try await Task.sleep(for: .milliseconds(50))
    func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    let table = try #require(descendants(content).compactMap { $0 as? NSTableView }.first)
    func expectSelection(_ row: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await awaitUntil("row \(row) selected", sourceLocation: sourceLocation) { table.selectedRow == row }
    }
    let record = try #require(library.records.first)
    // 下面按 `numberOfRows - 1` 取行，空表会越界 trap。
    try await awaitUntil("session rows shown") { table.numberOfRows > 0 }
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
    SessionResumeFlow.open(record, source: .init(agent: .claude, root: root, executable: "/bin/false", configuration: .custom(root.path)),
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
    SessionResumeFlow.open(resumable, source: .init(agent: .claude, root: root, executable: "/bin/echo", configuration: .custom(root.path)), in: controller)
    try await awaitUntil("An ended/closed binding must not intercept a new resume") { controller.tabCount != count }
    #expect(controller.tabCount == count + 1, "An ended/closed binding must not intercept a new resume")
    #expect(controller.activePane !== pane)
}
}
