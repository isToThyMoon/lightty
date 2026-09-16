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
    /// 没有 hook 绑定时，从终端标题的形状认出来的这家 agent（见 `SessionLibrary.noteTerminalTitle`）。
    /// agent 退出（shell 集成的命令结束标记）后清空。
    var titleAgent: SessionAgent?
    /// agent 经 OSC 0 写的标题原文（带它自己的状态前缀），只在 `titleAgent` 期间保留。
    var agentTitle: String?
    var shellDirectory: String?
    var binding: Binding = .none
    var status: PaneStatus?
    var isUnread = false
    var session: AgentSession?

    var sessionKey: AgentSessionKey? { binding.sessionKey }
    /// 图标用的 agent：hook 绑定了会话就是它；没有绑定但标题认出了 agent 在跑，也给图标——
    /// Codex TUI 到第一句提交才建线程、才跑 `SessionStart`，启动那一段只有标题能说明它是谁。
    /// 只用于显示，会话关联与恢复仍只认 `sessionKey`。
    var displayAgent: SessionAgent? { sessionKey?.agent ?? titleAgent }
    /// 显示的标题，同一时刻只有一个来源，来源之间不穿插（穿插就是闪）：
    /// - hook 绑定了会话：官方目录的标题；目录还没读到时用 pane 名，目录到达换一次。
    /// - 没有绑定、但标题看得出是 agent 写的：原文照显示，和原生终端一样，hook 没装也看得见
    ///   它的状态前缀；改名走 `/rename`，前缀由 agent 自己更新。
    /// - 都没有：pane 名，完全归 lightty 和用户。shell 写的标题不显示。
    var title: String {
        if binding.sessionKey != nil {
            let title = session?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.isEmpty ? terminalName : title
        }
        let agentTitle = agentTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return agentTitle.isEmpty ? terminalName : agentTitle
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
        var titleAgent: SessionAgent?
        var agentTitle: String?
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
        let next = PaneSessionState(paneID: id, terminalName: input.name, titleAgent: input.titleAgent,
            agentTitle: input.agentTitle, shellDirectory: input.directory,
            binding: binding, status: currentStatus, isUnread: currentStatus != nil && isUnread,
            session: binding.sessionKey.flatMap { records[$0] })
        panes[id] = next
        guard previous != next else { return SessionChange() }
        var fields: SessionChange.Fields = []
        if previous?.binding != next.binding { fields.insert(.identity) }
        if previous?.session != next.session || previous?.title != next.title { fields.insert(.metadata) }
        if previous?.status != next.status || previous?.isUnread != next.isUnread { fields.insert(.activity) }
        if previous?.workingDirectory != next.workingDirectory { fields.insert(.directory) }
        return SessionChange(panes: [id: fields],
            sessions: Set([previous?.sessionKey, next.sessionKey].compactMap { $0 }))
    }
}
