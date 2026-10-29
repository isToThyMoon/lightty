import Foundation

/// Codex 后台会话协议 → lightty 的会话事实。只解析，不关联 pane、不修改状态。
/// 广播与 thread/read 共用同一套状态解释；上游字段变化集中在这里适配。
enum CodexSessionEvents {
    enum Method: String, CaseIterable {
        case started = "thread/started"
        case statusChanged = "thread/status/changed"
        case turnCompleted = "turn/completed"
        case closed = "thread/closed"
        case renamed = "thread/name/updated"
    }

    struct Thread: Equatable {
        let id: String?
        let directory: String?
        let createdAt: Date?
        let activity: PaneStatusStore.CodexActivity?
        let isShownInTerminal: Bool

        init(_ wire: [String: Any]) {
            id = wire["id"] as? String
            directory = wire["cwd"] as? String
            createdAt = (wire["createdAt"] as? Double).map(Date.init(timeIntervalSince1970:))
            activity = CodexSessionEvents.activity(wire["status"] as? [String: Any])
            // 标题生成等临时会话与用户会话可能同目录，不能参与 pane 路由。
            // 旧版没有 threadSource 时仍按 user 解释，保持已有兼容行为。
            isShownInTerminal = wire["parentThreadId"] as? String == nil
                && (wire["ephemeral"] as? Bool) != true
                && (wire["threadSource"] as? String ?? "user") == "user"
        }
    }

    enum Event: Equatable {
        case started(Thread)
        case activityChanged(threadID: String, activity: PaneStatusStore.CodexActivity?)
        case turnCompleted(threadID: String, activity: PaneStatusStore.CodexActivity?)
        case closed(String)
        case renamed(String)
    }

    enum Failure: Error { case malformedNotification }

    /// 不订阅的广播返回 nil；认识的方法缺少必要结构才报格式错误。
    /// 未知状态保留为 nil，仍交出会话身份：Router 必须更新 revision，防止旧快照覆盖新事件。
    static func decode(_ method: String, params: [String: Any]) throws -> Event? {
        guard let method = Method(rawValue: method) else { return nil }
        func threadID() throws -> String {
            guard let id = params["threadId"] as? String else { throw Failure.malformedNotification }
            return id
        }
        switch method {
        case .started:
            guard let thread = params["thread"] as? [String: Any] else { throw Failure.malformedNotification }
            return .started(Thread(thread))
        case .statusChanged:
            return .activityChanged(threadID: try threadID(), activity: activity(params["status"] as? [String: Any]))
        case .turnCompleted:
            guard let turn = params["turn"] as? [String: Any] else { throw Failure.malformedNotification }
            let completed: PaneStatusStore.CodexActivity?
            switch turn["status"] as? String {
            case "completed": completed = .completed
            case "interrupted": completed = .interrupted
            case "failed": completed = .failed
            default: completed = nil
            }
            return .turnCompleted(threadID: try threadID(), activity: completed)
        case .closed: return .closed(try threadID())
        case .renamed: return .renamed(try threadID())
        }
    }

    private static let waitingFlags: Set<String> = ["waitingOnApproval", "waitingOnUserInput"]

    private static func activity(_ status: [String: Any]?) -> PaneStatusStore.CodexActivity? {
        switch status?["type"] as? String {
        case "active":
            let flags = Set(status?["activeFlags"] as? [String] ?? [])
            return flags.isDisjoint(with: waitingFlags) ? .active : .waiting
        case "idle": return .idle
        default: return nil
        }
    }
}
