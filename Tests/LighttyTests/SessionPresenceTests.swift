import AppKit
import LighttyCore
import Testing
@testable import lightty

@MainActor
private func presenceLabels(in view: NSView) -> Set<String> {
    view.subviews.reduce(into: Set<String>()) { labels, child in
        if let field = child as? NSTextField { labels.insert(field.stringValue) }
        labels.formUnion(presenceLabels(in: child))
    }
}

extension SessionAssociationTests {
    @Test func closingLocalTabDoesNotTurnCachedRunningMetadataIntoAnExternalSession() async throws {
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let identity = try #require(AgentProcessIdentity.read(process.processIdentifier))
        let record = f.record(processes: [identity])
        f.catalog.records = [record]
        let pane = PaneView(sessionLibrary: f.library)
        pane.terminal.removeFromSuperview()
        pane.associateSession(f.association(record))
        let controller = TerminalWindowController(initialPane: pane)
        AppState.shared.windowControllers = [controller]
        defer { controller.window?.close() }
        let list = SessionsSidebarContent(library: f.library)
        let host = try #require(controller.window?.contentView)
        host.addSubview(list)
        list.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
        f.library.start()
        try await f.wait { !f.library.loading && f.library.records == [record] }
        try await f.wait { presenceLabels(in: list).contains(L("Open in lightty")) }
        let shell = PaneView(sessionLibrary: f.library)
        shell.terminal.removeFromSuperview()
        controller.addTab(initialPane: shell)
        controller.closeTab(at: 0)
        #expect(controller.tabCount == 1)
        #expect(f.library.openPaneIDs(for: record.key).isEmpty)
        try await Task.sleep(for: .milliseconds(30))
        let detail = list.detailTextForTesting(record)
        #expect(!detail.contains(L("Open in lightty")))
        #expect(!detail.contains(L("Open in another terminal")),
                "Closing our only terminal cannot establish that another terminal exists")
        try await f.wait { presenceLabels(in: list).contains(record.title)
            && !presenceLabels(in: list).contains(L("Open in lightty")) }
        #expect(!presenceLabels(in: list).contains(L("Open in another terminal")))
        #expect(f.library.records.map(\.key) == [record.key], "Closing a tab must preserve its history")
    }

    @Test func externalExitUpdatesTheMaterializedSidebarCellWithoutRefreshingTheCatalog() async throws {
        _ = NSApplication.shared
        let host = Process(), peer = Process()
        for process in [host, peer] {
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["30"]
        }
        try host.run()
        defer { if host.isRunning { host.terminate(); host.waitUntilExit() } }
        try peer.run()
        defer { if peer.isRunning { peer.terminate(); peer.waitUntilExit() } }
        let f = try SessionModelFixture(hostProcessID: host.processIdentifier)
        defer { f.close() }
        let identity = try #require(AgentProcessIdentity.read(peer.processIdentifier))
        let record = f.record(processes: [identity])
        f.catalog.records = [record]
        let list = SessionsSidebarContent(library: f.library)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = list
        defer { window.close() }
        f.library.start()
        try await f.wait { presenceLabels(in: list).contains(L("Open in another terminal")) }
        let reads = f.catalog.requestCount
        peer.terminate()
        try await f.wait { !presenceLabels(in: list).contains(L("Open in another terminal")) }
        #expect(presenceLabels(in: list).contains(record.title))
        #expect(f.library.presence(for: record.key) == .unknown)
        #expect(f.catalog.requestCount == reads)
        #expect(f.library.records == [record])
    }
}

@MainActor
struct SessionPresenceModelTests {
    private func sleepingProcess() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return process
    }

    @Test(arguments: SessionAgent.allCases)
    func presenceDistinguishesTwoWindowsFromAnExternalProcessAndObservesItsExit(agent: SessionAgent) async throws {
        let host = try sleepingProcess()
        defer { if host.isRunning { host.terminate(); host.waitUntilExit() } }
        let peer = try sleepingProcess()
        defer { if peer.isRunning { peer.terminate(); peer.waitUntilExit() } }
        // Two real, separate process trees; this fixture models the first as the app host.
        let f = try SessionModelFixture(agent: agent, hostProcessID: host.processIdentifier)
        defer { f.close() }
        let local = try #require(AgentProcessIdentity.read(host.processIdentifier))
        let external = try #require(AgentProcessIdentity.read(peer.processIdentifier))
        let record = f.record(processes: [local, external])
        try await f.load([record])
        let reads = f.catalog.requestCount
        #expect(f.library.presence(for: record.key) == .elsewhere)
        let first = f.pane(), second = f.pane(), a = UUID(), b = UUID()
        for pane in [first, second] { f.library.associate(.attached(f.association(record)), with: pane) }
        f.library.updateWindow(a, panes: [first], selected: first)
        f.library.updateWindow(b, panes: [second], selected: second)
        #expect(f.library.presence(for: record.key) == .inLightty)
        f.library.updateWindow(a, panes: [], selected: nil)
        #expect(f.library.presence(for: record.key) == .inLightty)
        f.library.removeWindow(b)
        #expect(f.library.presence(for: record.key) == .elsewhere, "A real external process must not be hidden by a local close")
        try await Task.sleep(for: .milliseconds(20)) // Drain the window-change notification before observing exit.
        var affected = Set<AgentSessionKey>()
        let observer = NotificationCenter.default.addObserver(forName: .lighttySessionLibraryDidChange,
            object: f.library, queue: nil) { notification in
            MainActor.assumeIsolated {
                if let change = SessionChange.from(notification) { affected.formUnion(change.sessions) }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        peer.terminate()
        try await f.wait { f.library.presence(for: record.key) == .unknown }
        try await f.wait { affected.contains(record.key) }
        #expect(host.isRunning, "The still-alive owned process is not another terminal")
        #expect(f.catalog.requestCount == reads, "Kernel exit notification needs no catalog polling")
        #expect(f.library.records == [record], "Cached metadata can remain; it is not live presence")
        try await f.load([record])
        #expect(f.library.presence(for: record.key) == .unknown, "Re-reading stale evidence cannot resurrect an exited process")
    }

    @Test func reusedProcessIDsCannotBecomePresenceEvidence() async throws {
        let parent = try #require(AgentProcessIdentity.parent(of: ProcessInfo.processInfo.processIdentifier))
        let live = try #require(AgentProcessIdentity.read(parent))
        let reused = AgentProcessIdentity(pid: live.pid, startedSeconds: live.startedSeconds - 1,
                                         startedMicroseconds: live.startedMicroseconds)
        let f = try SessionModelFixture()
        defer { f.close() }
        let record = f.record(processes: [live])
        try await f.load([record])
        #expect(f.library.presence(for: record.key) == .elsewhere)
        try await f.load([f.record(processes: [reused])])
        #expect(f.library.presence(for: record.key) == .unknown)
        #expect(live.liveness == .running)
    }
}
