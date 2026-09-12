import AppKit
import LighttyCore
import Testing
@testable import lightty

extension SessionAssociationTests {
    @Test func oneModelUpdatesBothSidebarsAndPaneWithoutReloadingViews() async throws {
        _ = NSApplication.shared
        if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }
        let f = try SessionModelFixture()
        let previous = AppState.shared
        AppState.shared = AppState(taskDirectory: f.root, sweepStalePanes: false, sessionLibrary: f.library)
        defer {
            AppState.shared.windowControllers = []
            AppState.shared = previous ?? AppState.shared
            f.close()
        }
        let record = f.record(), association = f.association(record)
        f.catalog.records = [record]
        let pane = PaneView(sessionLibrary: f.library)
        pane.terminal.removeFromSuperview() // The fixture has no actual Agent process.
        pane.associateSession(association)
        let controller = TerminalWindowController(initialPane: pane)
        AppState.shared.windowControllers = [controller]
        defer { controller.window?.close() }
        let list = SessionsSidebarContent(library: f.library)
        let search = SessionsSidebarContent(library: f.library, searchMode: true)
        let tabs = TabColumnView()
        let host = try #require(controller.window?.contentView)
        host.addSubview(list)
        host.addSubview(search)
        host.addSubview(tabs)
        list.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
        tabs.frame = NSRect(x: 285, y: 0, width: 240, height: 600)
        search.frame = NSRect(x: 0, y: 0, width: 320, height: 600)
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let sessionTable = try #require(descendants(list).compactMap { $0 as? NSTableView }.first)
        let searchTable = try #require(descendants(search).compactMap { $0 as? NSTableView }.first)
        let tabTable = try #require(descendants(tabs).compactMap { $0 as? NSTableView }.first)
        func text(_ view: NSView) -> Set<String> {
            Set(descendants(view).compactMap { ($0 as? NSTextField)?.stringValue })
        }
        f.library.start()
        try await f.wait { pane.header.title == record.title && text(list).contains(record.title) && text(tabs).contains(record.title) }
        try await f.wait { sessionTable.selectedRow >= 0 }
        try await f.wait { text(search).contains(record.title) }
        searchTable.selectRowIndexes([0], byExtendingSelection: false)
        // 单 pane 标签页是一条叶子行，pane 行就在第 0 行（没有容器行在前）。
        let row = try #require(tabTable.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let tabTitles = controller.snapshot()?.tabs.map(\.title)

        let process = try #require(AgentProcessIdentity.read(ProcessInfo.processInfo.processIdentifier))
        let changed = f.record(title: "Renamed conversation", directory: "/catalog-folder", processes: [process])
        try await f.load([changed])
        try await f.wait { pane.header.title == changed.title && text(list).contains(changed.title)
            && text(tabs).contains(changed.title) && text(search).contains(changed.title) }
        #expect(searchTable.selectedRow == 0)
        #expect(tabTable.view(atColumn: 0, row: 0, makeIfNecessary: false) === row,
                "A session metadata update must not rebuild the Tabs list")
        #expect(controller.snapshot()?.tabs.map(\.title) == tabTitles)
        #expect(pane.sessionState.session == changed)

        pane.terminal.setWorkingDirectory("/shell-folder")
        try await f.wait { text(tabs).contains("/shell-folder") }
        try await f.status(.tool, event: "PreToolUse", pane: pane.dragIdentifier, record: changed)
        #expect(!pane.acceptsInjectedCommand)
        #expect(text(tabs).contains(L("Thinking")))
        #expect(tabTable.view(atColumn: 0, row: 0, makeIfNecessary: false) === row)
        #expect(f.library.openedSessionKeys == [record.key])

        // A background pane's completion must not resemble another selected row.
        let other = PaneView(sessionLibrary: f.library)
        other.terminal.removeFromSuperview()
        controller.addTab(initialPane: other)
        try await f.status(.done, event: "Stop", pane: pane.dragIdentifier, record: changed)
        let completedRow = try #require(tabTable.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let completedLabel = try #require(descendants(completedRow).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "✓ \(L("Finished"))" })
        #expect(completedLabel.superview?.layer?.backgroundColor?.alpha == 0)
        #expect(completedLabel.font == .systemFont(ofSize: 11.5, weight: .semibold))
        #expect(completedLabel.accessibilityLabel() == L("Finished"))
        #expect(completedLabel.textColor != ShellStyle.secondaryText)
        f.library.markRead(pane.dragIdentifier)
        try await f.wait { completedLabel.isHidden && completedLabel.stringValue.isEmpty }
        #expect((completedLabel as? PaneStatusLabel)?.breath == nil)
        #expect(tabTable.view(atColumn: 0, row: 0, makeIfNecessary: false) === completedRow)
        controller.selectTab(at: 0)

        try await f.status(.idle, event: "SessionEnd", pane: pane.dragIdentifier, record: changed)
        try await f.wait { sessionTable.selectedRow == -1 && pane.header.sessionAgent == nil }
        #expect(pane.header.title == pane.snapshot().name)
        #expect(text(tabs).contains(pane.snapshot().name))
        #expect(f.library.openedSessionKeys.isEmpty)
        #expect(searchTable.selectedRow == 0, "Search keeps its own keyboard selection when the terminal session ends")
        #expect(f.library.records == [changed], "Ending a process does not delete its saved conversation")
        #expect(tabTable.view(atColumn: 0, row: 0, makeIfNecessary: false) === completedRow)
    }
}
