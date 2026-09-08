import Foundation
import LighttyCore

extension Notification.Name {
    static let lighttySessionLibraryDidChange = Notification.Name("lighttySessionLibraryDidChange")
}

/// App-owned catalog and user organization. Windows observe snapshots, not provider formats.
final class SessionLibrary {
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

    init(fileURL: URL, providers: [SessionCatalogProvider]? = nil) {
        self.fileURL = fileURL
        self.providers = providers
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
        NotificationCenter.default.post(name: .lighttySessionLibraryDidChange, object: self)
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
    deinit { cancellation?.cancel() }
}

private final class CatalogCancellation {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}
