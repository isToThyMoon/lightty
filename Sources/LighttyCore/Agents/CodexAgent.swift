import Foundation

/// Codex CLI 的全部事实。改这一家只改这个文件。
public enum CodexAgent {
    /// 桌面通知（OSC 9）里「要你处理」那几类的开头；其余都是回合完成，正文是回复预览。
    /// 只给兜底用：hook 全失效时，lightty 靠 Codex 写进本 pane 的终端信号推状态。
    /// 来源：openai/codex 0.157.0，`codex-rs/tui/src/chatwidget/notifications.rs`
    /// （`Notification::display`）。只在终端没有焦点时发（`tui.notification_condition` 默认）。
    public static let attentionNotificationPrefixes = [
        "Approval requested", "Codex wants to edit", "Plan mode prompt:", "Question:",
    ]

    /// 终端界面建的会话在官方目录里记的 `originator`（建会话那个客户端 `initialize` 报的名字）。
    /// 0.157 起终端界面经共享后台进程建会话，`source` 随 app-server 记成 `vscode`，和桌面端
    /// （`originator` 为 `Codex Desktop`）同一个来源，只能靠它分开；0.156 及以前是 `source: cli`。
    /// 来源：openai/codex 0.157.0，`codex-rs/tui/src/lib.rs`（`client_name`）、
    /// `app-server/src/lib.rs`（`run_main` 默认 `SessionSource::VSCode`）、
    /// `app-server-protocol/src/protocol/v2/thread_data.rs`（`Thread.originator`）。
    public static let terminalOriginator = "codex-tui"

    public static let spec = AgentSpec(
        executableName: "codex",
        configurationVariable: "CODEX_HOME",
        standardConfigurationDirectory: ".codex",
        sourceName: "Codex CLI",
        launchName: "Codex",
        iconToolTip: "OpenAI Codex",
        iconAssetName: "openai",
        resumeShape: .subcommand("resume"),
        // codex 的选择器默认只列当前目录的会话，`--all` 才是全部。
        pickerArguments: ["--all"],
        bypassArguments: ["--yolo"],
        // `$` 是 CLI 层的输入解析，粘纯文本也会展开。
        skillInvocationSigil: "$",
        // 同「需要用户介入」语义的事件在 Codex 侧叫 PermissionRequest；用户主动停止
        // 单独发 Interrupt，不会补一发 Stop，漏订阅就会让 pane 永久停在 thinking/tool。
        hookEvents: AgentSpec.sharedHookEvents + ["PermissionRequest", "Interrupt"],
        hookConfigFile: "config.toml",
        hookConfigFormat: .toml,
        // Codex 对 hook **按内容**做信任校验，首次需用户批准；插件来源并不豁免
        // （实测：`trustStatus` 与 `marketplaceName` 同属一个结构体）。
        requiresHookTrustPrompt: true,
        // `add` 每次都重新拷贝，一条命令兼任安装与更新。
        pluginInstallVerb: "add",
        pluginUpdateVerb: "add",
        pluginRemoveVerb: "remove",
        marketplaceManifestPath: ".agents/plugins/marketplace.json",
        pluginManifestPath: ".codex-plugin/plugin.json",
        // Codex 不看 hooks/ 目录约定，读哪份由它自己那份插件清单指定。
        hooksDocumentPath: "hooks.json",
        // 默认项 `activity | thread-name | project-name`（`tui.terminal_title` 可改）：工作中是 braille
        // 旋转字符（U+2800 区，100 毫秒一帧）+ 空格；空闲时没有前缀；等用户处理时整行以
        // `[ ! ] Action Required`（与 `[ . ]` 每秒交替）开头。`tui.animations = false` 时不写旋转字符。
        // 来源：openai/codex 0.154.0，`codex-rs/tui/src/chatwidget/status_surfaces.rs`
        // （`TERMINAL_TITLE_SPINNER_FRAMES`、`TERMINAL_TITLE_ACTION_REQUIRED_PREFIX`）与
        // `codex-rs/tui/src/bottom_pane/title_setup.rs`（分隔符）。上游换了字符只改这里。
        terminalTitle: TerminalTitleShape(
            busyPrefixes: Set((0x2800...0x28FF).compactMap { Unicode.Scalar($0).map(Character.init) }),
            settledPrefixes: [],
            attentionPrefixes: ["[ ! ] Action Required", "[ . ] Action Required"],
            bareTitleIsSettled: true))
}
