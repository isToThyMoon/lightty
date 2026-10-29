import Foundation

/// 两家 Hook 的外部载荷与 additionalContext 回复格式。
/// 只转换数据；进程身份、pane 路由、任务绑定与 IO 留给 lightty-hook。
public struct AgentHookEvent: Sendable {
    public let name: String
    public let activity: PaneActivity
    public let sessionID: String?
    public let tool: String?
    public let detail: String?
    public let workingDirectory: String?
    public let transcriptPath: String?
    private let originalTranscriptPath: String?

    /// 可选字段逐个读取，保留旧 helper 的容错：一个可选字段类型变了，不丢整发状态。
    /// 不认识/不需要处理的事件以及无效 JSON 返回 nil。
    public init?(_ data: Data) {
        guard let wire = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = Self.string(wire["hook_event_name"]),
              let activity = PaneActivity(hookEventName: name,
                  notificationType: Self.string(wire["notification_type"]),
                  interrupted: (wire["is_interrupt"] as? Bool) == true) else { return nil }
        self.name = name
        self.activity = activity
        sessionID = Self.string(wire["session_id"])
        tool = Self.string(wire["tool_name"])
        workingDirectory = Self.string(wire["cwd"])
        // PostToolUse 的输入只是回声，细节只在工具开始时展示。
        detail = name == "PreToolUse" ? Self.detail(wire["tool_input"]) : nil
        originalTranscriptPath = Self.string(wire["transcript_path"])
        // 状态报文有 4KB 上限。Agent 推断仍使用原始路径，保持旧插件兼容行为。
        transcriptPath = originalTranscriptPath.flatMap { $0.utf8.count <= 1024 ? $0 : nil }
    }

    /// 仅用于没有 --agent 声明的旧插件。显式声明的优先级由调用方保证。
    public func inferredAgent(environment: [String: String]) -> String? {
        HookAgentDetection.agent(transcriptPath: originalTranscriptPath, environment: environment)
    }

    /// 与收到的事件名绑定，正文只经 JSONEncoder 转义；不在这里做输出或标记注入成功。
    public func contextOutput(_ context: String) throws -> Data {
        try JSONEncoder().encode(ContextOutput(hookSpecificOutput: .init(
            hookEventName: name, additionalContext: context)))
    }

    private struct ContextOutput: Encodable {
        struct Specific: Encodable {
            let hookEventName: String
            let additionalContext: String
        }
        let hookSpecificOutput: Specific
    }

    private static func string(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let detailKeys = [
        "file_path", "path", "notebook_path", "command", "pattern", "url", "query", "description",
    ]

    private static func detail(_ input: Any?) -> String? {
        guard let fields = input as? [String: Any] else { return nil }
        for key in detailKeys {
            if let value = string(fields[key]) { return summarize(value) }
        }
        return nil
    }

    private static func summarize(_ value: String, limit: Int = 80) -> String {
        let flat = value.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard flat.count > limit else { return flat }
        // 路径保留尾部文件名，命令/描述保留头部。按字符截断，不能截坏 Unicode。
        if flat.contains("/") { return "…" + String(flat.suffix(limit - 1)) }
        return String(flat.prefix(limit - 1)) + "…"
    }
}
