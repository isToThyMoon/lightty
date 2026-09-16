import Foundation

/// 判断一发 hook 事件来自哪家 agent。纯函数：证据由调用方收集，便于测试。
///
/// **整个类型已只是兼容退路**：hooks 文件是 lightty 自己生成的，命令行里写死了
/// `--agent <名>`（见 `HookMarketplace.hookCommand`），只有用户装的还是旧版插件时才走到这里。
/// 按父进程链上的可执行路径猜哪一家的那一段已经删掉——它随安装方式变（原生是
/// `versions/<版本号>`、npm 是 `claude.exe`），是最后一处「按名字认」的知识；
/// 找 agent 进程与判断子会话改看终端作业结构，见 `AgentProcessIdentity.foregroundJobLeader(in:)`。
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
    ///   - transcriptPath: 载荷里的 `transcript_path`。Claude 在 `~/.claude/projects/<slug>/<uuid>.jsonl`，
    ///     Codex 在 `~/.codex/sessions/…/rollout-*.jsonl`。
    ///   - environment: hook 进程的环境，只作兜底。
    /// - Returns: `"claude"` / `"codex"`；认不出返回 nil——`agent` 是可选字段，猜错比留空更糟。
    public static func agent(transcriptPath: String?, environment: [String: String]) -> String? {
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
}
