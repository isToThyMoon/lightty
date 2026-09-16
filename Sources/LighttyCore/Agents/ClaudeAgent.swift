import Foundation

/// Claude Code 的全部事实。改这一家只改这个文件。
public enum ClaudeAgent {
    public static let spec = AgentSpec(
        executableName: "claude",
        configurationVariable: "CLAUDE_CONFIG_DIR",
        standardConfigurationDirectory: ".claude",
        sourceName: "Claude Code",
        launchName: "Claude Code",
        iconToolTip: "Claude Code",
        iconAssetName: "claude",
        resumeShape: .flag("--resume"),
        // `claude --resume` 不带尾巴就是它自己的选择器。
        pickerArguments: [],
        bypassArguments: ["--permission-mode", "bypassPermissions"],
        skillInvocationSigil: "/",
        // Notification 是 Claude Code 侧的「需要用户介入」信号，它的 idle_prompt 兼作
        // 「回合已经不在跑了」的旁证；PostToolUseFailure 带 is_interrupt 时是用户中断了工具。
        // Claude Code 没有 Interrupt 事件，Stop 在用户中断时不触发，这两条是仅有的替代。
        hookEvents: AgentSpec.sharedHookEvents + ["PostToolUseFailure", "Notification"],
        hookConfigFile: "settings.json",
        hookConfigFormat: .json,
        requiresHookTrustPrompt: false,
        // 插件已装时 `install` 是空操作，版本变了也不重新拷贝，所以要换成 `update`。
        pluginInstallVerb: "install",
        pluginUpdateVerb: "update",
        pluginRemoveVerb: "uninstall",
        marketplaceManifestPath: ".claude-plugin/marketplace.json",
        pluginManifestPath: ".claude-plugin/plugin.json",
        // 目录约定：Claude Code 自己去插件的 hooks/ 里找。
        hooksDocumentPath: "hooks/hooks.json",
        // `<前缀> <会话标题>`：回合进行中 ◐ ◑ 轮换（960 毫秒），不忙时 ✳（等用户处理对话框时也是 ✳）。
        // 没有前缀的标题不是它写的。
        // 来源：Claude Code 2.1.274 二进制里渲染标题的组件（搜 `SET_TITLE_AND_ICON` 附近的
        // `["\u25D0","\u25D1"]` 与 `"\u2733"`），无公开文档。上游换了字符只改这里，
        // 解析不出来就退回只靠 hook。
        terminalTitle: TerminalTitleShape(
            busyPrefixes: ["\u{25D0}", "\u{25D1}"],
            settledPrefixes: ["\u{2733}"],
            attentionPrefixes: [],
            bareTitleIsSettled: false))
}
