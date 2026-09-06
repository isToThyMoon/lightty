import AppKit
import LighttyCore
import Testing
@testable import lightty

private final class RestoredTitleCatalog: SessionCatalogProvider {
    let source: SessionCatalogSource
    let record: AgentSession
    private let lock = NSLock()
    private var requests = 0

    init(source: SessionCatalogSource, record: AgentSession) {
        self.source = source
        self.record = record
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    func page(archived: Bool, cursor: String?, cancelled: () -> Bool) throws -> SessionCatalogPage {
        lock.lock(); requests += 1; lock.unlock()
        return .init(sessions: archived ? [] : [record], nextCursor: nil)
    }
}

extension SessionAssociationTests {
    /// Exercise the cold catalog + restored association + presenter notification path.
    /// No sidebar activation, hooks, manual library refresh, or manual title refresh.
    @Test func restoredSessionTitlesLoadInHandoffMode() async throws {
        _ = NSApplication.shared
        if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = AppState.shared
        defer {
            AppState.shared.windowControllers = []
            AppState.shared = previous ?? AppState.shared
            try? FileManager.default.removeItem(at: root)
        }
        let records = SessionAgent.allCases.map { agent in
            AgentSession(key: .init(agent: agent, sourceRoot: root.path, nativeID: "restored-\(agent)"),
                         title: "Restored \(agent) title", workingDirectory: root.path, updatedAt: nil)
        }
        let library = SessionLibrary(fileURL: root.appendingPathComponent("organization.json"),
            providers: records.map { RestoredTitleCatalog(
                source: .init(agent: $0.key.agent, root: root, executable: "/bin/echo"), record: $0) })
        AppState.shared = AppState(taskDirectory: root, sweepStalePanes: false, sessionLibrary: library)
        library.start() // Application startup loads the model before restoring windows.
        let controller = TerminalWindowController(restoring: .init(activeTabIndex: 0,
            tabs: [.init(title: "User tab name", root: .pane(.init(name: "Shell", agentAlive: false)))],
            taskPanelOpen: true, tabSidebarOpen: true, primarySidebarMode: PrimarySidebarMode.handoff.rawValue))
        AppState.shared.windowControllers = [controller]
        defer { controller.window?.close() }
        let panes = records.map { record in
            PaneView.restored(from: .init(name: "Terminal fallback", agentCWD: root.path,
                agentAlive: true, catalogSession: record.key, catalogConfiguration: .custom(root.path)),
                locateExecutable: { _ in "/bin/echo" })
        }
        for pane in panes {
            // The fixture replaces the CLI, not session restoration or title presentation.
            // Keep its surface unattached so /bin/echo cannot exit and detach the session.
            pane.terminal.removeFromSuperview()
            controller.addTab(initialPane: pane, select: false, installPane: false)
        }
        controller.selectTab(at: 1) // Restore one foreground and one background agent pane.
        let deadline = Date().addingTimeInterval(1)
        while panes.map({ $0.header.title }) != records.map(\.title), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.snapshot()?.primarySidebarMode == PrimarySidebarMode.handoff.rawValue)
        #expect(panes.map(\.displayedSessionKey) == records.map(\.key))
        #expect(panes.map { $0.header.title } == records.map(\.title))
        #expect(library.loaded, "Pane titles must load the catalog without opening Sessions")
        #expect(controller.snapshot()?.tabs.first?.title == "User tab name")
        #expect(panes.map { $0.snapshot().name } == ["Terminal fallback", "Terminal fallback"],
                "A session title is derived display, not a rename of the user's pane")

        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        let rootView = try #require(controller.window?.contentView?.superview)
        let column = try #require(descendants(rootView).compactMap { $0 as? TabColumnView }.first)
        let table = try #require(descendants(column).compactMap { $0 as? NSTableView }.first)
        // Let the title-change notification reach the actual sidebar; do not call reload().
        let sidebarDeadline = Date().addingTimeInterval(1)
        func visibleTitles() -> Set<String> {
            table.layoutSubtreeIfNeeded()
            return Set(descendants(table).compactMap { ($0 as? NSTextField)?.stringValue })
        }
        while !Set(records.map(\.title)).isSubset(of: visibleTitles()), Date() < sidebarDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(Set(records.map(\.title)).isSubset(of: visibleTitles()),
                "The Tabs sidebar must update without switching sidebar mode or tabs")
    }

    @Test(arguments: [false, true])
    func titleCatalogBootstrapDoesNotReloadOnNotifications(alreadyLoading: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let record = AgentSession(key: .init(agent: .claude, sourceRoot: root.path, nativeID: "once"),
                                  title: "Once", workingDirectory: nil, updatedAt: nil)
        let provider = RestoredTitleCatalog(
            source: .init(agent: .claude, root: root, executable: "/bin/echo"), record: record)
        let library = SessionLibrary(fileURL: root.appendingPathComponent("organization.json"), providers: [provider])
        let previous = AppState.shared
        AppState.shared = AppState(taskDirectory: root, sweepStalePanes: false, sessionLibrary: library)
        defer {
            AppState.shared = previous ?? AppState.shared
            try? FileManager.default.removeItem(at: root)
        }
        if alreadyLoading { library.refresh() }
        library.start()
        library.start()
        let deadline = Date().addingTimeInterval(1)
        while library.loading, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(library.loaded)
        #expect(!library.loading)
        #expect(provider.requestCount == 2, "One initial read for active and archived sessions")
        library.cancelLoading()
        for _ in 0..<10 {
            library.updateWindow(UUID(), panes: [], selected: nil)
        }
        // Drain the coalesced notifications, including cancelLoading's library notification.
        try await Task.sleep(for: .milliseconds(50))
        #expect(provider.requestCount == 2)
        #expect(!library.loaded, "Presentation notifications must not restart a cancelled load")
    }
}
