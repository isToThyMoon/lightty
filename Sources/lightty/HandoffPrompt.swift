import Foundation

/// 「Handoff」「Restore」注入 PTY 的指令模板（HANDOVER 7.4：UI 主动触发，替代已否决的 hooks 方案）。
/// 对 claude/codex 通用：指令是纯自然语言 + 文件路径，由 pane 内正在跑的 agent
/// 用自身会话上下文执行。pane 内没跑 agent 时文本会打进 shell（无害，已知限制）。
/// 任务文件路径在点击时实时嵌入（LIGHTTY_TASK 环境变量已整体移除）。
///
/// 协议语言为英文（2026-08-30 起）：提示词与文档节头是跨会话数据格式，不随
/// 界面语言变化。旧任务文件的中文节头由 RestoreFlow.summarize 兼容解析。
enum HandoffPrompt {
    /// Handoff：让 agent 把 handoff 快照原子写入任务文件正文
    static func finish(taskFilePath: String) -> String {
        """
        Please write a handoff document for the current session into the task file: \(taskFilePath)
        Requirements:
        1. Rewrite only the body after the frontmatter terminator (the second `---` line). Keep the frontmatter as is, except refresh `updated` to the current UTC time (ISO8601, e.g. 2026-08-22T10:00:00Z).
        2. Structure the body as follows (the reader is the next agent taking over — write for continuing the work, not for reporting to a human):
           ## Next steps
           ## Current state
           ## Key decisions & constraints (reference, don't copy: point commits / file paths / URLs at existing artifacts)
           ## Blockers & risks
           ## Suggested commands & skills
        3. Keep any existing dated human milestone sections in the body; do not overwrite them.
        4. Redact: never write API keys, passwords, or PII into the file.
        5. Atomic write: write a temp file in the same directory then mv it over the target; never truncate in place.
        """
    }

    /// Restore：恢复场景，让 agent 读 handoff 按「Next steps」继续
    static func resume(taskFilePath: String) -> String {
        """
        Please read the task handoff document: \(taskFilePath)
        It was left by this task's previous sessions. After reading, continue working per its "Next steps" section; consult the files and links referenced in "Key decisions & constraints" as needed. Before starting, restate your understanding of the task's current state in one or two sentences.
        """
    }
}
