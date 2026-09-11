import Foundation
import LighttyCore

extension Notification.Name {
    static let lighttySessionLibraryDidChange = Notification.Name("lighttySessionLibraryDidChange")
}

/// Application session model: catalog, organization, pane bindings and window selection.
/// Views consume SessionChange + value snapshots; only this module reconciles runtime identity.
/// All state transitions and publications run on the main thread, like PaneStatusStore.
final class SessionLibrary {
    private struct ObservedProcess {
        let external: Bool
        let source: DispatchSourceProcess
    }
    private let hostProcessID: Int32
    private var observedProcesses: [AgentProcessIdentity: ObservedProcess] = [:]
    private let statusStore: PaneStatusStore
    var statusSocketPath: URL { statusStore.socketPath }
    private var runtime = SessionRuntime()
    private var recordIndex: [AgentSessionKey: AgentSession] = [:]
    private var started = false
    private var pendingChange = SessionChange()
    private lazy var notifications = Coalescer(.nextTick) { [weak self] in
        guard let self else { return }
        let change = self.pendingChange
        self.pendingChange = SessionChange()
        guard !change.isEmpty else { return }
        NotificationCenter.default.post(name: .lighttySessionLibraryDidChange, object: self,
                                        userInfo: ["change": change])
    }
    private struct MetadataRequest { let baseline: AgentSession?; var attempts: Int }
    private var metadataRequests: [AgentSessionKey: MetadataRequest] = [:]
    private let metadataRefreshDelay: TimeInterval
    private lazy var metadataRefreshes = Coalescer(.after(metadataRefreshDelay)) { [weak self] in
        guard let self, !self.loading, !self.metadataRequests.isEmpty else { return }
        for key in self.metadataRequests.keys { self.metadataRequests[key]?.attempts -= 1 }
        self.refresh()
    }
    private(set) var records: [AgentSession] = []
    private(set) var organization = SessionOrganization()
    private(set) var errors: [SessionAgent: String] = [:]
    private(set) var storageError: String?
    private(set) var loading = false
    private struct Query: Hashable { let agent: SessionAgent; let archived: Bool }
    private var cursors: [Query: String] = [:]
    private var seen: [Query: Set<AgentSessionKey>] = [:]
    private var visited: [Query: Set<String>] = [:]
    private var activeRequests = 0
    private var activeProviders: [SessionCatalogProvider] = []
    func hasMore(archived: Bool? = nil) -> Bool { cursors.keys.contains { archived == nil || $0.archived == archived } }
    private(set) var saving = false
    private(set) var loaded = false
    private(set) var organizationReady = false
    private let providers: [SessionCatalogProvider]?
    private let fileURL: URL
    private let diskQueue = DispatchQueue(label: "lightty.session-library.storage")
    private var generation = 0
    private var cancellation: CatalogCancellation?
    private var deletionReconciliation = Set<AgentSessionKey>()
    private var deletedKeys = Set<AgentSessionKey>()

    func didDelete(_ key: AgentSessionKey) {
        records.removeAll { $0.key == key }
        deletedKeys.insert(key)
        deletionReconciliation.insert(key)
        refresh()
    }

    init(fileURL: URL, providers: [SessionCatalogProvider]? = nil,
         statusStore: PaneStatusStore = .shared, metadataRefreshDelay: TimeInterval = 1.5,
         hostProcessID: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.hostProcessID = hostProcessID
        self.fileURL = fileURL
        self.providers = providers
        self.statusStore = statusStore
        self.metadataRefreshDelay = metadataRefreshDelay
        NotificationCenter.default.addObserver(self, selector: #selector(statusDidChange(_:)),
            name: .lighttyPaneStatusDidChange, object: nil)
        diskQueue.async { [weak self] in
            do {
                let value: SessionOrganization
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    let data = try Data(contentsOf: fileURL)
                    try PersistenceFormat.organization.validate(data)
                    value = try JSONDecoder().decode(SessionOrganization.self, from: data)
                } else { value = SessionOrganization() }
                DispatchQueue.main.async {
                    self?.organization = value
                    self?.organizationReady = true
                    self?.publish()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.storageError = L("Project data could not be read. The original file has been preserved.")
                    self?.publish()
                }
            }
        }
    }

    /// Application lifecycle, never view visibility. Calling start again has no effects.
    func start() {
        guard !started else { return }
        started = true
        if !loaded, !loading { refresh() }
        else { hydrateAssociatedSessions() }
    }

    func paneState(for id: UUID) -> PaneSessionState? { runtime.panes[id] }
    func markRead(_ id: UUID) { statusStore.markRead(id) }
    var openedSessionKeys: Set<AgentSessionKey> { runtime.openedSessionKeys }
    func presence(for key: AgentSessionKey) -> SessionPresence {
        if openedSessionKeys.contains(key) { return .inLightty }
        if recordIndex[key]?.sourceProcesses.contains(where: { observedProcesses[$0]?.external == true }) == true {
            return .elsewhere
        }
        return .unknown
    }
    func openPaneIDs(for key: AgentSessionKey) -> Set<UUID> {
        Set(runtime.openedPaneIDs.filter { runtime.panes[$0]?.sessionKey == key })
    }
    func selectedPane(in window: UUID) -> UUID? { runtime.windows[window]?.selected }
    func selectedSession(in window: UUID) -> AgentSessionKey? {
        selectedPane(in: window).flatMap { runtime.panes[$0]?.sessionKey }
    }

    func updateWindow(_ window: UUID, panes: Set<UUID>, selected: UUID?) {
        let next = SessionRuntime.Window(panes: panes, selected: selected.flatMap { panes.contains($0) ? $0 : nil })
        guard runtime.windows[window] != next else { return }
        let before = openedSessionKeys
        runtime.windows[window] = next
        emit(SessionChange(windows: [window], sessions: before.union(openedSessionKeys)))
    }

    func removeWindow(_ window: UUID) {
        let before = openedSessionKeys
        guard runtime.windows.removeValue(forKey: window) != nil else { return }
        emit(SessionChange(windows: [window], sessions: before.union(openedSessionKeys)))
    }

    func registerPane(_ id: UUID, name: String, directory: String?) {
        precondition(runtime.inputs[id] == nil, "A pane must be registered exactly once")
        runtime.inputs[id] = .init(name: name, directory: directory)
        statusStore.attach(id)
        reconcilePane(id)
    }

    func removePane(_ id: UUID) {
        runtime.inputs.removeValue(forKey: id)
        reconcilePane(id)
        for (window, state) in runtime.windows where state.panes.contains(id) {
            updateWindow(window, panes: state.panes.subtracting([id]),
                         selected: state.selected == id ? nil : state.selected)
        }
        statusStore.detach(id)
    }

    func associate(_ binding: PaneSessionState.Binding, with id: UUID, at date: Date = Date()) {
        guard runtime.inputs[id] != nil else { return }
        runtime.inputs[id]?.intent = binding
        runtime.inputs[id]?.associatedAt = date
        runtime.inputs[id]?.supersededStatus = statusStore.status(for: id)
        runtime.inputs[id]?.exited = false
        reconcilePane(id)
        hydrateAssociatedSessions()
    }

    func renamePane(_ id: UUID, to name: String) {
        runtime.inputs[id]?.name = name
        reconcilePane(id)
    }

    func updateDirectory(_ directory: String?, for id: UUID) {
        runtime.inputs[id]?.directory = directory
        reconcilePane(id)
    }

    func commandFinished(in id: UUID, at date: Date) {
        guard let input = runtime.inputs[id], date >= input.associatedAt,
              statusStore.commandFinished(for: id, at: date) else { return }
        runtime.inputs[id]?.intent = .none
        reconcilePane(id)
    }

    func reconcileProcess(in id: UUID, terminalExited: Bool = false) {
        if terminalExited { runtime.inputs[id]?.exited = true }
        statusStore.reconcileProcess(for: id)
        reconcilePane(id)
    }

    /// A CLI operation/hook invalidates metadata, not just its title. All consumers share the read.
    /// Official catalogs can lag the hook; bounded retries stop on changed metadata or cancellation.
    func invalidateMetadata(for key: AgentSessionKey) {
        metadataRequests[key] = .init(baseline: recordIndex[key], attempts: 5)
        metadataRefreshes.schedule()
    }

    @objc private func statusDidChange(_ notification: Notification) {
        guard PaneStatusStore.source(from: notification) === statusStore else { return }
        let ids = PaneStatusStore.paneID(from: notification).map { [$0] } ?? Array(runtime.inputs.keys)
        for id in ids where runtime.inputs[id] != nil {
            let previous = runtime.panes[id]
            reconcilePane(id)
            guard let next = runtime.panes[id], let key = next.sessionKey else { continue }
            if next.sessionKey != previous?.sessionKey ||
                (next.status?.state == .done && next.status != previous?.status) {
                invalidateMetadata(for: key)
            }
        }
    }

    private func reconcilePane(_ id: UUID) {
        emit(runtime.update(id, status: statusStore.status(for: id),
                            isUnread: statusStore.unreadActivity(for: id) != nil, records: recordIndex,
                            home: FileManager.default.homeDirectoryForCurrentUser))
    }

    private func emit(_ change: SessionChange) {
        pendingChange.merge(change)
        if !pendingChange.isEmpty { notifications.schedule() }
    }

    func source(for agent: SessionAgent) -> SessionCatalogSource? {
        if let providers { return providers.first { $0.source.agent == agent }?.source }
        let command = agent == .codex ? "codex" : "claude"
        guard let executable = HookInstaller.locateExecutable(command) else { return nil }
        let configuration = SessionConfigurationLocation.resolve(
            agent: agent, environment: ProcessInfo.processInfo.environment)
        let root = configuration.root(for: agent, home: FileManager.default.homeDirectoryForCurrentUser)
        return SessionCatalogSource(agent: agent, root: root, executable: executable, configuration: configuration)
    }

    func refresh(includeArchived: Bool = true) {
        cancellation?.cancel()
        generation += 1
        cancellation = CatalogCancellation()
        cursors = [:]; seen = [:]; visited = [:]
        activeRequests = 0
        errors = [:]
        let sources = SessionAgent.allCases.compactMap { source(for: $0) }
        activeProviders = providers ?? sources.map {
            $0.agent == .codex ? CodexSessionCatalog(source: $0) as SessionCatalogProvider
                : ClaudeSessionCatalog(source: $0)
        }
        for agent in SessionAgent.allCases where !sources.contains(where: { $0.agent == agent }) {
            errors[agent] = L("CLI was not found on this Mac.")
        }
        for provider in activeProviders {
            request(provider, archived: false, cursor: nil)
            if includeArchived { request(provider, archived: true, cursor: nil) }
        }
        loading = activeRequests > 0
        loaded = true
        publish()
    }

    func loadMore(archived: Bool? = nil) {
        guard !loading else { return }
        for provider in activeProviders {
            for state in [false, true] where archived == nil || archived == state {
                let query = Query(agent: provider.source.agent, archived: state)
                if let cursor = cursors[query] { request(provider, archived: state, cursor: cursor) }
            }
        }
        loading = activeRequests > 0
        publish()
    }

    func cancelLoading() {
        metadataRequests.removeAll()
        metadataRefreshes.cancel()
        cancellation?.cancel()
        generation += 1
        // Keep the next-page cursor usable after the user cancels an in-flight page.
        cancellation = CatalogCancellation()
        activeRequests = 0
        loading = false
        loaded = false
        publish()
    }

    private func request(_ provider: SessionCatalogProvider, archived: Bool, cursor: String?) {
        guard let token = cancellation else { return }
        let current = generation
        let query = Query(agent: provider.source.agent, archived: archived)
        activeRequests += 1
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try provider.page(archived: archived, cursor: cursor, cancelled: { token.cancelled }) }
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                defer {
                    self.activeRequests -= 1
                    self.loading = self.activeRequests > 0
                    self.reconcileDeletedSessions()
                    self.publish()
                    self.hydrateAssociatedSessions()
                    self.settleMetadataRequests()
                }
                switch result {
                case .success(let page):
                    if cursor != nil { self.errors.removeValue(forKey: query.agent) }
                    if let next = page.nextCursor,
                       next == cursor || self.visited[query, default: []].contains(next) {
                        self.errors[query.agent] = SessionCatalogError.protocolFailure.localizedDescription
                        self.cursors.removeValue(forKey: query)
                        return
                    }
                    if self.seen[query, default: []].count + page.sessions.count > 50_000 {
                        self.errors[query.agent] = SessionCatalogError.tooLarge.localizedDescription
                        self.cursors.removeValue(forKey: query)
                        return
                    }
                    if let cursor { self.visited[query, default: []].insert(cursor) }
                    let keys = Set(page.sessions.map(\.key))
                    self.seen[query, default: []].formUnion(keys)
                    // Merge partial pages; prune stale records only once the source completes.
                    self.records.removeAll { keys.contains($0.key) }
                    self.records += page.sessions
                    self.cursors[query] = page.nextCursor
                    if page.nextCursor == nil {
                        self.records.removeAll {
                            $0.key.agent == query.agent && $0.sourceArchived == archived
                                && !self.seen[query, default: []].contains($0.key)
                        }
                    }
                case .failure(let error):
                    if !(error is CancellationError) {
                        self.errors[query.agent] = (error as? LocalizedError)?.errorDescription
                            ?? L("Could not read this CLI session source.")
                    }
                }
            }
        }
    }

    func updateOrganization(_ edit: (inout SessionOrganization) -> Void) {
        guard organizationReady, !saving, storageError == nil else { return }
        var next = organization
        edit(&next)
        saving = true
        publish()
        let value = next
        let fileURL = fileURL
        diskQueue.async { [weak self] in
            do {
                let data = try JSONEncoder().encode(value)
                try PersistenceFormat.organization.validate(data)
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    let existing = try Data(contentsOf: fileURL)
                    try PersistenceFormat.organization.validate(existing)
                    _ = try JSONDecoder().decode(SessionOrganization.self, from: existing)
                }
                try data.write(to: fileURL, options: .atomic)
                DispatchQueue.main.async {
                    self?.organization = value
                    self?.saving = false
                    self?.reconcileDeletedSessions()
                    self?.publish()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.saving = false
                    self?.storageError = L("Project changes could not be saved. The previous data has been preserved.")
                    self?.publish()
                }
            }
        }
    }

    private func publish() {
        let next = Dictionary(records.map { ($0.key, $0) }, uniquingKeysWith: { _, new in new })
        let changed = Set(recordIndex.keys).union(next.keys).filter { recordIndex[$0] != next[$0] }
        recordIndex = next
        observeSourceProcesses()
        if !changed.isEmpty {
            for id in runtime.inputs.keys { reconcilePane(id) }
        }
        emit(SessionChange(catalog: true, sessions: changed))
    }

    private func observeSourceProcesses() {
        let identities = recordIndex.values.reduce(into: Set<AgentProcessIdentity>()) { $0.formUnion($1.sourceProcesses) }
        for (identity, observation) in observedProcesses where !identities.contains(identity) {
            observation.source.cancel()
            observedProcesses.removeValue(forKey: identity)
        }
        for identity in identities where observedProcesses[identity] == nil {
            guard identity.liveness == .running, let external = isExternalProcess(identity) else { continue }
            let source = DispatchSource.makeProcessSource(identifier: identity.pid, eventMask: .exit, queue: .main)
            observedProcesses[identity] = .init(external: external, source: source)
            source.setEventHandler { [weak self] in self?.sourceProcessExited(identity) }
            source.activate()
            // The process may exit between inspection and registering the kernel notification.
            if identity.liveness == .exited { sourceProcessExited(identity) }
        }
    }

    /// Record ownership while the process tree exists; closing a pane never reclassifies its
    /// process as external. An unreadable ancestry is unknown, not evidence of another terminal.
    private func isExternalProcess(_ identity: AgentProcessIdentity) -> Bool? {
        // A common ancestor also proves separate process trees; inspecting launchd or another
        // protected system ancestor is unnecessary. Keep start times to avoid PID-reuse matches.
        var hostAncestors = Set<AgentProcessIdentity>()
        var ancestor = AgentProcessIdentity.parent(of: hostProcessID)
        for _ in 0..<64 {
            guard let pid = ancestor, let process = AgentProcessIdentity.read(pid),
                  hostAncestors.insert(process).inserted else { break }
            ancestor = AgentProcessIdentity.parent(of: pid)
        }
        var pid = identity.pid
        var visited = Set<Int32>()
        for _ in 0..<64 {
            if pid == hostProcessID { return false }
            if pid == 1 { return true }
            if let process = AgentProcessIdentity.read(pid), hostAncestors.contains(process) { return true }
            guard pid > 1, visited.insert(pid).inserted,
                  let parent = AgentProcessIdentity.parent(of: pid) else { return nil }
            pid = parent
        }
        return nil
    }

    private func sourceProcessExited(_ identity: AgentProcessIdentity) {
        guard let observation = observedProcesses.removeValue(forKey: identity) else { return }
        observation.source.cancel()
        let affected = Set(recordIndex.values.filter { $0.sourceProcesses.contains(identity) }.map(\.key))
        emit(SessionChange(sessions: affected))
    }

    /// Restored or invalidated sessions need not be on page one. Follow cursors until the
    /// current read reaches their records, the source ends or fails; cached data is not a fresh read.
    private func hydrateAssociatedSessions() {
        guard started, loaded, !loading else { return }
        let requested = Set(runtime.panes.values.compactMap(\.sessionKey)).union(metadataRequests.keys)
        let missing = requested.filter { key in
            if recordIndex[key] == nil { return true }
            guard metadataRequests[key] != nil else { return false }
            return ![false, true].contains { archived in
                seen[Query(agent: key.agent, archived: archived)]?.contains(key) == true
            }
        }
        let agents = Set(missing.filter { key in
            errors[key.agent] == nil && source(for: key.agent)?.root.standardizedFileURL.path == key.sourceRoot
        }.map(\.agent))
        for provider in activeProviders where agents.contains(provider.source.agent) {
            for archived in [false, true] {
                let query = Query(agent: provider.source.agent, archived: archived)
                if let cursor = cursors[query] { request(provider, archived: archived, cursor: cursor) }
            }
        }
        if activeRequests > 0 { loading = true; publish() }
    }

    private func settleMetadataRequests() {
        guard !loading else { return }
        metadataRequests = metadataRequests.filter { key, request in
            request.attempts > 0 && recordIndex[key] == request.baseline
        }
        if !metadataRequests.isEmpty { metadataRefreshes.schedule() }
    }
    private func reconcileDeletedSessions() {
        guard !loading, !saving, organizationReady, storageError == nil else { return }
        // Deletion can remove descendants beyond the first catalog page.
        // Only reconcile organization after a complete, successful provider read.
        if cursors.keys.contains(where: { query in
            errors[query.agent] == nil && deletionReconciliation.contains { $0.agent == query.agent }
        }) {
            loadMore()
            return
        }
        let completed = deletionReconciliation.filter { key in
            errors[key.agent] == nil && !cursors.keys.contains { $0.agent == key.agent }
                && source(for: key.agent)?.root.standardizedFileURL.path == key.sourceRoot
        }
        deletionReconciliation.subtract(completed)
        let present = Set(records.map(\.key))
        let stale = Set(organization.assignments.map(\.session)).union(organization.archivedSessions)
            .filter { candidate in completed.contains { $0.agent == candidate.agent && $0.sourceRoot == candidate.sourceRoot }
                && !present.contains(candidate) }
        let removed = stale.union(deletedKeys)
        deletedKeys.removeAll()
        if !removed.isEmpty { updateOrganization { $0.forgetSessions(removed) } }
    }
    deinit {
        NotificationCenter.default.removeObserver(self)
        cancellation?.cancel()
        observedProcesses.values.forEach { $0.source.cancel() }
    }
}

private final class CatalogCancellation {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}
