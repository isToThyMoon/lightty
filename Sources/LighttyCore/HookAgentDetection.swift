import Foundation

/// 判断一发 hook 事件来自哪家 agent。纯函数：证据由调用方收集，便于测试。
///
/// 为什么不能只看环境变量：Codex 不给 hook 子进程设 `CODEX_HOME` / `CODEX_SANDBOX`，
/// 而它的载荷沿用 Claude 兼容的 schema、带 `transcript_path`，只看环境加 `transcript_path`
/// 会把每一发 Codex 事件认成 claude，快照据此生成 `claude --resume <codex id>`，
/// 重开 app 后 Codex 会话就恢复不了（实测 2026-09-07）。另一头，`CLAUDECODE` 会从
/// 上层 Claude 会话泄漏给它里面启动的 codex，所以环境变量只能垫底。
public enum HookAgentDetection {
    public static let claude = "claude"
    public static let codex = "codex"

    /// - Parameters:
    ///   - ancestorExecutablePaths: hook 进程父进程链上各进程的可执行文件**绝对路径**，
    ///     最近的在前。agent 直接或经 shell 拉起 hook，链上必有它自己的二进制，这是
    ///     最可靠的证据。必须是整条路径：claude 经 symlink 解析后可执行名是版本号
    ///     （`.../share/claude/versions/2.1.263`），只看 basename 认不出，但路径含 `claude` 段。
    ///   - transcriptPath: 载荷里的 `transcript_path`。Claude 在 `~/.claude/projects/<slug>/<uuid>.jsonl`，
    ///     Codex 在 `~/.codex/sessions/…/rollout-*.jsonl`。
    ///   - environment: hook 进程的环境，只作兜底。
    /// - Returns: `"claude"` / `"codex"`；认不出返回 nil——`agent` 是可选字段，猜错比留空更糟。
    public static func agent(
        ancestorExecutablePaths: [String], transcriptPath: String?, environment: [String: String]
    ) -> String? {
        for path in ancestorExecutablePaths {
            if let hit = agentInPath(path) { return hit }
        }
        if let transcriptPath {
            let lowered = transcriptPath.lowercased()
            let last = (lowered as NSString).lastPathComponent
            let segments = lowered.split(separator: "/").map(String.init)
            if segments.contains(".codex") || last.hasPrefix("rollout-") { return codex }
            if segments.contains(".claude") { return claude }
        }
        if environment["CODEX_HOME"] != nil || environment["CODEX_SANDBOX"] != nil { return codex }
        if environment["CLAUDECODE"] != nil || environment["CLAUDE_CODE_ENTRYPOINT"] != nil { return claude }
        if transcriptPath != nil { return claude }
        return nil
    }

    /// hook 所属的 agent 是不是别的会话从工具里拉起的子会话（例如 Bash 工具里跑 `claude -p`）。
    ///
    /// 子会话继承了 pane 的环境变量，不拦的话它的 SessionStart / SessionEnd 会顶掉主会话的
    /// 状态和会话绑定。判据：父进程链（最近的在前，只到 lightty 为止）里最近的 agent 之上，
    /// 隔着非 agent 进程还有另一个 agent。紧挨着的 agent 进程算同一个（启动器、re-exec）。
    public static func isNestedSession(ancestorExecutablePaths paths: [String]) -> Bool {
        guard let nearest = paths.firstIndex(where: { agentInPath($0) != nil }) else { return false }
        return paths[(nearest + 1)...]
            .drop { agentInPath($0) != nil }
            .contains { agentInPath($0) != nil }
    }

    /// 一条可执行文件路径归属哪家 agent。codex 的二进制名就是 `codex`；claude 解析后
    /// 是版本号，靠路径里的 `claude` 段认。用路径分段避免把随便含 "codex" 子串的路径误判。
    private static func agentInPath(_ path: String) -> String? {
        let lowered = path.lowercased()
        let last = (lowered as NSString).lastPathComponent
        let segments = lowered.split(separator: "/").map(String.init)
        if last == codex || last.hasPrefix("codex-") || segments.contains(".codex") || segments.contains("codex") {
            return codex
        }
        if last == claude || last.hasPrefix("claude-") || segments.contains(".claude") || segments.contains("claude") {
            return claude
        }
        return nil
    }
}
