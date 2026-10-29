import Foundation
import OSLog

/// 对接链路的诊断词汇。只走系统日志，不写 hook 的 stdout/stderr、不保存业务正文。
/// debug 级别供 `log stream --level debug` 复现时采集；不增加文件、锁或网络请求。
public struct AgentDiagnostic: Equatable, Sendable {
    public enum Stage: String, Sendable {
        case hookRoute, hookSend, handoff, statusIngest, daemonConnection, daemonEvent, sessionRoute, titleRefresh
    }

    public enum Reason: String, Sendable {
        case inheritedTerminal, sessionRecord, nestedSession, missingRoute, ignoredSessionEnd, unsupportedPayload
        case sent, sendFailed, noTask, alreadyInjected, unreadableTask, outputWritten, outputFailed
        case accepted, detachedPane, staleTimestamp, staleSession, staleProcess, settledTurn
        case connecting, connected, disconnected, handshakeTimeout, launchFailed, lookupFailed
        case declaredSession, resumeArgument, uniqueDirectory, nearestStart, unresolved, removed, writeFailed
        case foreground, titleMatched, titleUnmatched, list, requested
    }

    public let stage: Stage
    public let reason: Reason
    public let agent: SessionAgent?
    public let pane: UUID?
    public let session: String?
    public let hook: String?
    public let activity: PaneActivity?

    /// 两家会话 ID 都是 UUID。只公开规范化后的标识，异常输入不进入日志；
    /// OSLog 的 private hash 每进程不同，不能用来关联 app 与短命 hook。
    public var sessionIdentifier: String? { session.flatMap(UUID.init(uuidString:))?.uuidString }

    private static let hooks = Set(SessionAgent.allCases.flatMap { $0.spec.hookEvents })
    private static let logger = Logger(subsystem: "com.lightty.agent", category: "integration")

    public init(_ stage: Stage, _ reason: Reason, agent: SessionAgent? = nil,
                pane: UUID? = nil, session: String? = nil, hook: String? = nil, activity: PaneActivity? = nil) {
        self.stage = stage
        self.reason = reason
        self.agent = agent
        self.pane = pane
        self.session = session
        self.activity = activity
        // 外部事件名也不能作为任意公开字符串写入日志。
        self.hook = hook.flatMap { Self.hooks.contains($0) ? $0 : nil }
    }

    public static func emit(_ entry: AgentDiagnostic) {
        let level: OSLogType = [.writeFailed, .outputFailed, .launchFailed].contains(entry.reason) ? .error : .debug
        logger.log(level: level, "stage=\(entry.stage.rawValue, privacy: .public) reason=\(entry.reason.rawValue, privacy: .public) agent=\(entry.agent?.rawValue ?? "unknown", privacy: .public) pane=\(entry.pane?.uuidString ?? "none", privacy: .public) session=\(entry.sessionIdentifier ?? "unknown", privacy: .public) hook=\(entry.hook ?? "none", privacy: .public) activity=\(entry.activity?.rawValue ?? "none", privacy: .public)")
    }
}
