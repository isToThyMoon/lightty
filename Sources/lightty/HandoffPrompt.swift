import Foundation

/// 「收工」「注入」注入 PTY 的指令模板（HANDOVER 7.4：UI 主动触发，替代已否决的 hooks 方案）。
/// 对 claude/codex 通用：指令是纯自然语言 + 文件路径，由 pane 内正在跑的 agent
/// 用自身会话上下文执行。pane 内没跑 agent 时文本会打进 shell（无害，已知限制）。
/// 任务文件路径在点击时实时嵌入（LIGHTTY_TASK 环境变量已整体移除）。
enum HandoffPrompt {
    /// 收工：让 agent 把 handoff 快照原子写入任务文件正文
    static func finish(taskFilePath: String) -> String {
        """
        请为当前会话生成 handoff 交接文档，并写入任务文件：\(taskFilePath)
        要求：
        1. 只重写 frontmatter 结束符（第二个 `---` 行）之后的正文，frontmatter 原样保留，仅把 updated 刷新为当前 UTC 时间（ISO8601，如 2026-08-22T10:00:00Z）。
        2. 正文按以下结构写（读者是接手的新 agent，为"继续干活"写，不为人类汇报写）：
           ## 下一步
           ## 当前状态
           ## 关键决策与约束（引用不复制：commit/文件路径/URL 指向已有产物）
           ## 卡点与风险
           ## 建议命令与技能
        3. 正文中已有的带日期的人工里程碑段落保留，不要覆盖。
        4. 脱敏：API key、密码、PII 不写入。
        5. 原子写：先写同目录临时文件再 mv 覆盖，禁止原地截断写。
        """
    }

    /// 注入：恢复场景，让 agent 读 handoff 按「下一步」继续
    static func resume(taskFilePath: String) -> String {
        """
        请读取任务交接文档：\(taskFilePath)
        这是本任务此前会话留下的 handoff。读完后按其中「下一步」一节继续工作；\
        「关键决策与约束」里引用的文件与链接按需自行查阅。开始前用一两句话复述你理解的任务现状。
        """
    }
}
