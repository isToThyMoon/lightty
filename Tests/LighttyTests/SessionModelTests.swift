import Foundation
import LighttyCore
import Testing
@testable import lightty

/// The same provider seam used by the application, with mutable official metadata fixtures.
final class SessionModelCatalog: SessionCatalogProvider {
    let source: SessionCatalogSource
    let pageSize: Int
    private let lock = NSLock()
    private var values: [AgentSession] = []
    private var reads = 0
    var records: [AgentSession] {
        get { lock.lock(); defer { lock.unlock() }; return values }
        set { lock.lock(); defer { lock.unlock() }; values = newValue }
    }
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    init(root: URL, pageSize: Int = 100, agent: SessionAgent = .codex) {
        source = .init(agent: agent, root: root, executable: "/bin/echo")
        self.pageSize = pageSize
    }
    func page(archived: Bool, cursor: String?, cancelled: () -> Bool) throws -> SessionCatalogPage {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        let records = values.filter { $0.sourceArchived == archived }
        let offset = cursor.flatMap(Int.init) ?? 0
        let page = Array(records.dropFirst(offset).prefix(pageSize))
        let next = offset + page.count
        return .init(sessions: page, nextCursor: next < records.count ? String(next) : nil)
    }
}

@MainActor
final class SessionModelFixture {
    let root: URL
    let catalog: SessionModelCatalog
    let statuses: PaneStatusStore
    let library: SessionLibrary
    private var paneIDs: [UUID] = []

    init(pageSize: Int = 100, agent: SessionAgent = .codex,
         hostProcessID: Int32 = ProcessInfo.processInfo.processIdentifier) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        catalog = SessionModelCatalog(root: root, pageSize: pageSize, agent: agent)
        statuses = PaneStatusStore(socketPath: URL(fileURLWithPath: "/tmp/lt-\(UUID().uuidString).sock"))
        library = SessionLibrary(fileURL: root.appendingPathComponent("organization.json"), providers: [catalog],
                                 statusStore: statuses, metadataRefreshDelay: 0.01, hostProcessID: hostProcessID)
    }
    func record(_ id: String = "fixture", title: String = "Conversation", directory: String? = nil,
                archived: Bool = false, processes: Set<AgentProcessIdentity> = []) -> AgentSession {
        .init(key: .init(agent: catalog.source.agent, sourceRoot: root.path, nativeID: id), title: title,
              workingDirectory: directory ?? root.path, updatedAt: nil, sourceArchived: archived, sourceProcesses: processes)
    }
    func association(_ record: AgentSession) -> PaneSessionAssociation {
        .init(key: record.key, configuration: .custom(record.key.sourceRoot), workingDirectory: root.path)
    }
    func pane(name: String = "My terminal") -> UUID {
        let id = UUID()
        paneIDs.append(id)
        library.registerPane(id, name: name, directory: nil)
        return id
    }
    func close() {
        paneIDs.forEach { library.removePane($0) }
        library.cancelLoading()
        statuses.stop()
        try? FileManager.default.removeItem(at: root)
    }
    func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }
    func load(_ records: [AgentSession]) async throws {
        catalog.records = records
        library.refresh()
        try await wait { !library.loading }
        // Delivery is coalesced; give consumers a runloop turn after the committed snapshot.
        try await Task.sleep(for: .milliseconds(20))
    }
    func status(_ state: PaneActivity, event: String, pane: UUID, record: AgentSession,
                directory: String? = nil) async throws {
        #expect(statuses.start())
        let value = PaneStatus(ts: Date(), state: state, agent: record.key.agent.rawValue,
            sessionID: record.key.nativeID, sourceRoot: record.key.sourceRoot,
            cwd: directory ?? root.path, event: event)
        _ = PaneStatusDatagram(pane: pane, status: value).send(to: statuses.socketPath)
        try await wait { library.paneState(for: pane)?.status?.event == event }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
struct SessionModelTests {
    @Test func markAllReadAcknowledgesRequestsWithoutErasingThemOrRefetchingMetadata() async throws {
        let f = try SessionModelFixture()
        defer { f.close() }
        let record = f.record(), first = f.pane(), second = f.pane(), completed = f.pane()
        try await f.load([record])
        try await f.status(.done, event: "Stop", pane: completed, record: record)
        try await f.status(.attention, event: "PermissionRequest", pane: first, record: record)
        try await f.status(.attention, event: "Notification", pane: second, record: record)
        try await f.wait { !f.library.loading }
        // Completion may have scheduled bounded metadata retries. Finish that setup
        // before measuring whether the read operation itself starts catalog work.
        f.library.cancelLoading()
        try await Task.sleep(for: .milliseconds(20))
        let reads = f.catalog.requestCount
        var changes: [SessionChange] = []
        let observer = NotificationCenter.default.addObserver(forName: .lighttySessionLibraryDidChange,
            object: f.library, queue: nil) { note in
            MainActor.assumeIsolated { if let change = SessionChange.from(note) { changes.append(change) } }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        #expect(f.statuses.hasUnreadReminders)
        f.statuses.markAllRead()
        #expect(!f.statuses.hasUnreadReminders)
        #expect(f.statuses.attentionCount == 2 && f.statuses.unreadCount == 0)
        for id in [first, second] {
            #expect(f.library.paneState(for: id)?.status?.state == .attention)
            #expect(f.library.paneState(for: id)?.isUnread == false)
        }
        #expect(f.library.paneState(for: completed)?.status?.state == .idle)
        try await f.wait { changes.contains { $0.panes[first]?.contains(.activity) == true
            && $0.panes[second]?.contains(.activity) == true } }
        #expect(f.catalog.requestCount == reads)
        #expect(changes.allSatisfy { !$0.catalog })

        // Re-delivery of the same request is not a new unread request. The following
        // pane event is a receive-queue barrier, so no arbitrary sleep is needed.
        let duplicate = try #require(f.statuses.status(for: first))
        _ = PaneStatusDatagram(pane: first, status: duplicate).send(to: f.statuses.socketPath)
        try await f.status(.thinking, event: "UserPromptSubmit", pane: second, record: record)
        #expect(f.library.paneState(for: first)?.isUnread == false)
        try await f.status(.attention, event: "Notification", pane: first, record: record)
        #expect(f.library.paneState(for: first)?.isUnread == true)
        #expect(f.statuses.unreadActivity(for: first) == .attention)
    }

    @Test(arguments: [false, true])
    func restoreHydratesSharedBindingsBeyondPageOneWithoutViews(catalogAlreadyLoaded: Bool) async throws {
        let f = try SessionModelFixture(pageSize: 1)
        defer { f.close() }
        let target = f.record("older", title: "Restored conversation")
        f.catalog.records = [f.record("recent"), target, f.record("unneeded")]
        if catalogAlreadyLoaded {
            f.library.refresh()
            try await f.wait { !f.library.loading }
            #expect(f.catalog.requestCount == 2)
        }
        let first = f.pane(), second = f.pane()
        for id in [first, second] { f.library.associate(.restoring(f.association(target)), with: id) }
        let a = UUID(), b = UUID()
        f.library.updateWindow(a, panes: [first], selected: first)
        f.library.updateWindow(b, panes: [second], selected: second)
        f.library.start()
        try await f.wait { f.library.paneState(for: second)?.session == target && !f.library.loading }
        #expect(f.library.paneState(for: first)?.session == target)
        #expect(f.library.paneState(for: first)?.binding == .restoring(f.association(target)))
        #expect(f.library.openPaneIDs(for: target.key) == [first, second])
        #expect(f.library.selectedSession(in: a) == target.key)
        #expect(f.library.selectedSession(in: b) == target.key)
        #expect(f.catalog.requestCount == 3, "Stop paging as soon as associated records are hydrated")
    }

    @Test func metadataIsCommittedForEveryPaneBeforeOneTypedNotification() async throws {
        let f = try SessionModelFixture()
        defer { f.close() }
        let process = try #require(AgentProcessIdentity.read(ProcessInfo.processInfo.processIdentifier))
        let old = f.record(), changed = f.record(title: "New name", directory: "/new-folder", processes: [process])
        let first = f.pane(), second = f.pane(), unrelated = f.pane()
        for id in [first, second] { f.library.associate(.attached(f.association(old)), with: id) }
        try await f.load([old])
        var changes: [SessionChange] = []
        let observer = NotificationCenter.default.addObserver(forName: .lighttySessionLibraryDidChange,
            object: f.library, queue: nil) { notification in
            MainActor.assumeIsolated {
                guard let change = SessionChange.from(notification) else { return }
                changes.append(change)
                if change.panes[first] != nil {
                    #expect(f.library.paneState(for: first)?.session == f.library.paneState(for: second)?.session)
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try await f.load([changed])
        #expect(f.library.records == [changed])
        #expect(f.library.paneState(for: first)?.session == changed)
        #expect(f.library.paneState(for: second)?.title == "New name")
        #expect(f.library.paneState(for: first)?.terminalName == "My terminal")
        #expect(changes.contains { $0.panes[first]?.contains(.metadata) == true && $0.panes[second]?.contains(.metadata) == true })
        #expect(changes.allSatisfy { $0.panes[unrelated] == nil })
        #expect(changes.contains { $0.sessions.contains(changed.key) })
    }

    @Test func metadataInvalidationRefreshesACachedSessionBeyondPageOne() async throws {
        let f = try SessionModelFixture(pageSize: 1)
        defer { f.close() }
        let recent = f.record("recent"), target = f.record("older"), id = f.pane()
        f.catalog.records = [recent, target, f.record("unneeded")]
        f.library.associate(.restoring(f.association(target)), with: id)
        f.library.start()
        try await f.wait { f.library.paneState(for: id)?.session == target && !f.library.loading }
        let changed = f.record("older", title: "Changed older session", directory: "/new-folder")
        f.catalog.records = [recent, changed, f.record("unneeded")]
        f.library.invalidateMetadata(for: target.key)
        try await f.wait { f.library.paneState(for: id)?.session == changed && !f.library.loading }
        #expect(f.catalog.requestCount == 6, "Re-read the target page, then stop before unrelated older pages")
    }

    @Test func hooksDirectoryAndExitUseTheSameBindingState() async throws {
        let f = try SessionModelFixture()
        defer { f.close() }
        let record = f.record()
        let id = f.pane()
        try await f.load([record])
        let window = UUID()
        f.library.updateWindow(window, panes: [id], selected: id)
        try await f.status(.idle, event: "SessionStart", pane: id, record: record)
        #expect(f.library.paneState(for: id)?.binding == .attached(f.association(record)))
        #expect(f.library.openedSessionKeys == [record.key])
        try await f.status(.tool, event: "PreToolUse", pane: id, record: record, directory: "/agent-folder")
        #expect(f.library.paneState(for: id)?.acceptsInput == false)
        #expect(f.library.paneState(for: id)?.workingDirectory == "/agent-folder")
        f.library.updateDirectory("/shell-folder", for: id)
        #expect(f.library.paneState(for: id)?.workingDirectory == "/shell-folder")
        try await f.status(.idle, event: "SessionEnd", pane: id, record: record)
        #expect(f.library.paneState(for: id)?.sessionKey == nil)
        #expect(f.library.paneState(for: id)?.title == "My terminal")
        #expect(f.library.selectedSession(in: window) == nil)
        #expect(f.library.openedSessionKeys.isEmpty)
        f.library.associate(.restoring(f.association(record)), with: id)
        #expect(f.library.selectedSession(in: window) == record.key, "An old end hook cannot erase a new resume")
    }

    @Test func unavailableAndDifferentSourcesNeverClaimAnOpenBinding() async throws {
        let f = try SessionModelFixture()
        defer { f.close() }
        let record = f.record(), id = f.pane()
        let intent = f.association(record)
        f.library.associate(.unavailable(intent), with: id)
        f.library.updateWindow(UUID(), panes: [id], selected: id)
        try await f.load([record])
        #expect(f.library.paneState(for: id)?.binding.association == intent)
        #expect(f.library.paneState(for: id)?.session == nil)
        #expect(f.library.openedSessionKeys.isEmpty)
        let other = PaneSessionAssociation(key: .init(agent: .codex, sourceRoot: "/other-source", nativeID: record.key.nativeID),
            configuration: .custom("/other-source"), workingDirectory: f.root.path)
        f.library.associate(.attached(other), with: id)
        #expect(f.library.paneState(for: id)?.session == nil)
        #expect(f.library.openPaneIDs(for: record.key).isEmpty)
    }

    @Test func windowSelectionAndClosingDoNotFetchOrDetachOtherWindows() async throws {
        let f = try SessionModelFixture()
        defer { f.close() }
        let record = f.record(), first = f.pane(), second = f.pane(), shell = f.pane()
        for id in [first, second] { f.library.associate(.attached(f.association(record)), with: id) }
        try await f.load([record])
        let a = UUID(), b = UUID(), reads = f.catalog.requestCount
        f.library.updateWindow(a, panes: [first, shell], selected: first)
        f.library.updateWindow(b, panes: [second], selected: second)
        f.library.updateWindow(a, panes: [first, shell], selected: shell)
        #expect(f.library.selectedSession(in: a) == nil)
        #expect(f.library.selectedSession(in: b) == record.key)
        f.library.removePane(second)
        #expect(f.library.paneState(for: second) == nil)
        #expect(f.library.selectedPane(in: b) == nil)
        #expect(f.library.openPaneIDs(for: record.key) == [first])
        f.library.removeWindow(b)
        #expect(f.library.openPaneIDs(for: record.key) == [first])
        f.library.updateWindow(a, panes: [shell], selected: shell)
        #expect(f.library.openedSessionKeys.isEmpty)
        #expect(f.library.paneState(for: first)?.sessionKey == record.key, "Closing layout is not an Agent exit event")
        #expect(f.catalog.requestCount == reads)
    }

    @Test func metadataRetryIsBoundedAndCancellationSurvivesSelectionChanges() async throws {
        let f = try SessionModelFixture()
        defer { f.close() }
        let record = f.record(), id = f.pane()
        f.library.associate(.attached(f.association(record)), with: id)
        try await f.load([record])
        f.library.invalidateMetadata(for: record.key)
        try await f.wait { f.catalog.requestCount == 12 && !f.library.loading }
        try await Task.sleep(for: .milliseconds(60))
        #expect(f.catalog.requestCount == 12, "Five bounded metadata reads, not a notification feedback loop")
        f.library.invalidateMetadata(for: record.key)
        f.library.cancelLoading()
        f.library.updateWindow(UUID(), panes: [id], selected: id)
        try await Task.sleep(for: .milliseconds(60))
        #expect(f.catalog.requestCount == 12)
        #expect(!f.library.loaded)
    }

    @Test(arguments: ["", "  \n  "])
    func missingOrBlankMetadataUsesTerminalName(title: String) async throws {
        let f = try SessionModelFixture()
        defer { f.close() }
        let record = f.record(title: title), id = f.pane()
        f.library.associate(.restoring(f.association(record)), with: id)
        #expect(f.library.paneState(for: id)?.title == "My terminal")
        try await f.load([record])
        #expect(f.library.paneState(for: id)?.title == "My terminal")
        #expect(f.library.paneState(for: id)?.sessionKey == record.key)
    }
}
