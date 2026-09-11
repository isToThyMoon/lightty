import Foundation
import LighttyCore

/// Presence is evidence-based. Absence of an app pane is not evidence of an external terminal.
enum SessionPresence: Equatable {
    case inLightty
    case elsewhere
    case unknown
}

/// App-owned runtime state. A terminal, a conversation and a task remain distinct identities.
struct PaneSessionState: Equatable {
    enum Binding: Equatable {
        case none
        case restoring(PaneSessionAssociation)
        case attached(PaneSessionAssociation)
        case unavailable(PaneSessionAssociation)

        var association: PaneSessionAssociation? {
            switch self {
            case .none: return nil
            case .restoring(let value), .attached(let value), .unavailable(let value): return value
            }
        }
        var sessionKey: AgentSessionKey? {
            if case .unavailable = self { return nil }
            return association?.key
        }
    }

    let paneID: UUID
    var terminalName: String
    var shellDirectory: String?
    var binding: Binding = .none
    var status: PaneStatus?
    var isUnread = false
    var session: AgentSession?

    var sessionKey: AgentSessionKey? { binding.sessionKey }
    var title: String {
        let title = session?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? terminalName : title
    }
    var workingDirectory: String? { shellDirectory ?? binding.association?.workingDirectory ?? session?.workingDirectory }
    var acceptsInput: Bool { status?.state != .thinking && status?.state != .tool }
    var processIdentity: AgentProcessIdentity? { sessionKey == nil ? nil : status?.agentProcess }
}

/// One notification contract for every session consumer. State is committed before publication.
/// Catalog/organization changes may alter list structure; pane activity never implies a list reload.
struct SessionChange {
    struct Fields: OptionSet {
        let rawValue: Int
        static let identity = Self(rawValue: 1 << 0)
        static let metadata = Self(rawValue: 1 << 1)
        static let activity = Self(rawValue: 1 << 2)
        static let directory = Self(rawValue: 1 << 3)
        static let all: Self = [.identity, .metadata, .activity, .directory]
    }
    var catalog = false
    var panes: [UUID: Fields] = [:]
    var windows: Set<UUID> = []
    var sessions: Set<AgentSessionKey> = []
    var isEmpty: Bool { !catalog && panes.isEmpty && windows.isEmpty && sessions.isEmpty }

    mutating func merge(_ other: Self) {
        catalog = catalog || other.catalog
        for (id, fields) in other.panes { panes[id, default: []].formUnion(fields) }
        windows.formUnion(other.windows)
        sessions.formUnion(other.sessions)
    }

    static func from(_ notification: Notification) -> Self? {
        notification.userInfo?["change"] as? Self
    }
}

/// Pure runtime implementation behind SessionLibrary; it has no views, providers or notifications.
struct SessionRuntime {
    struct Input {
        var name: String
        var directory: String?
        var intent: PaneSessionState.Binding = .none
        var associatedAt = Date.distantPast
        var supersededStatus: PaneStatus?
        var exited = false
    }
    struct Window: Equatable {
        var panes: Set<UUID>
        var selected: UUID?
    }
    var inputs: [UUID: Input] = [:]
    private(set) var panes: [UUID: PaneSessionState] = [:]
    var windows: [UUID: Window] = [:]

    var openedPaneIDs: Set<UUID> { windows.values.reduce(into: []) { $0.formUnion($1.panes) } }
    var openedSessionKeys: Set<AgentSessionKey> { Set(openedPaneIDs.compactMap { panes[$0]?.sessionKey }) }

    mutating func update(_ id: UUID, status: PaneStatus?, isUnread: Bool,
                         records: [AgentSessionKey: AgentSession], home: URL) -> SessionChange {
        let previous = panes[id]
        guard let input = inputs[id] else {
            panes.removeValue(forKey: id)
            return SessionChange(panes: [id: .all], sessions: Set([previous?.sessionKey].compactMap { $0 }))
        }
        // A newly launched/resumed association supersedes an old shell completion/end hook.
        let currentStatus = status == input.supersededStatus ? nil : status
        let association = PaneSessionAssociation.resolve(status: currentStatus,
            fallback: input.intent.association, processExited: input.exited,
            candidates: Array(records.keys), home: home)
        let binding: PaneSessionState.Binding
        if let association {
            if currentStatus == nil {
                switch input.intent {
                case .restoring: binding = .restoring(association)
                case .unavailable: binding = .unavailable(association)
                default: binding = .attached(association)
                }
            } else { binding = .attached(association) }
        } else { binding = .none }
        let next = PaneSessionState(paneID: id, terminalName: input.name, shellDirectory: input.directory,
            binding: binding, status: currentStatus, isUnread: currentStatus != nil && isUnread,
            session: binding.sessionKey.flatMap { records[$0] })
        panes[id] = next
        guard previous != next else { return SessionChange() }
        var fields: SessionChange.Fields = []
        if previous?.binding != next.binding { fields.insert(.identity) }
        if previous?.session != next.session || previous?.terminalName != next.terminalName { fields.insert(.metadata) }
        if previous?.status != next.status || previous?.isUnread != next.isUnread { fields.insert(.activity) }
        if previous?.workingDirectory != next.workingDirectory { fields.insert(.directory) }
        return SessionChange(panes: [id: fields],
            sessions: Set([previous?.sessionKey, next.sessionKey].compactMap { $0 }))
    }
}
