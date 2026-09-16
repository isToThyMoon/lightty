import Foundation

/// 一家 Agent 的全部**事实**：可执行名、配置根、显示名、命令行写法、hook 与插件约定。
///
/// 这是纯数据，没有行为。每家的值写在 `Sources/LighttyCore/Agents/<家名>Agent.swift` 里，
/// 全 app 只有 `SessionAgent.spec` 一个穷举 switch 把枚举换成它。这样多一家 Agent 是
/// 「加一个文件 + 加一个 case」，而不是去十来个文件里各补一行 —— 后者漏掉一处不是
/// 编译错误，是一个静默走 Claude 分支的 bug。
///
/// 什么该进来：现在散在各处、按家返回常量的那些 switch。
/// 什么不该进来：需要构造对象的工厂（`SessionCatalogSource.makeProvider`、图标加载）、
/// 读写两家配置格式的解析器 —— 那些是行为，且 LighttyCore 不依赖 app 目标。
public struct AgentSpec: Sendable {

    /// 续接一段会话时，CLI 自己的命令形状。两家不一样，而且参数的位置也跟着不一样。
    public enum ResumeShape: Sendable, Equatable {
        /// `claude [参数] --resume <id>`：续接是个标志，启动参数排在它前面。
        case flag(String)
        /// `codex resume [参数] <id>`：续接是个子命令，**必须**排在最前，启动参数跟在后面。
        case subcommand(String)
    }

    /// CLI 往哪种格式的配置文件里写插件声明。我们**只读**它，用来判断装没装。
    public enum HookConfigFormat: Sendable, Equatable {
        case json
        case toml
    }

    // MARK: - 进程与配置

    /// PATH 上的可执行文件名。
    public let executableName: String

    /// CLI 用来改写配置根的环境变量。
    public let configurationVariable: String

    /// 标准配置根相对家目录的名字。
    public let standardConfigurationDirectory: String

    // MARK: - 显示

    /// 会话来源的名字：Sessions 侧栏的筛选、错误前缀、搜索结果标签。
    public let sourceName: String

    /// 启动选择里的短名（启动浮层、设置页）。
    public let launchName: String

    /// 会话行图标的提示文字。
    public let iconToolTip: String

    /// bundle 里那张标识的资源名（`agent-<名>.svg`）。
    public let iconAssetName: String

    // MARK: - 命令行

    /// 续接命令的形状，见 `ResumeShape`。
    public let resumeShape: ResumeShape

    /// 打开 CLI 自带会话选择器时补在命令尾部的参数。
    /// codex 默认只列当前目录的会话，`--all` 才是全部；claude 的选择器不带尾巴。
    public let pickerArguments: [String]

    /// 这家 CLI 表达「跳过权限确认」的原生写法。开关是一个而不是每家一个：
    /// 用户表达的是意图，具体参数是 lightty 对内部 Agent 的翻译。
    public let bypassArguments: [String]

    /// 调用插件技能的前缀。Codex 的 `$` 是 CLI 层的输入解析，不是写给模型看的约定
    /// ——纯文本粘进去也会展开，正合我们往 PTY 里敲字这条路。
    public let skillInvocationSigil: String

    // MARK: - hook 与插件

    /// 我们订阅的 hook 事件。事件 key **必须是 PascalCase**（实测：snake_case /
    /// camelCase 均不触发）。状态机映射见 docs/specs/pane-status.md §4.3。
    public let hookEvents: [String]

    /// CLI 会往里写插件声明的那份文件，相对配置根。
    public let hookConfigFile: String

    /// 上面那份文件的格式，决定用哪个只读解析器。
    public let hookConfigFormat: HookConfigFormat

    /// 这家 CLI 是否对 hook 按内容做信任校验、首次需用户批准。
    /// 我们不绕过，也绝不该绕过——但必须**事先**告诉用户，否则下次跑 CLI
    /// 冒出来的审核提示看起来就像中招了。
    public let requiresHookTrustPrompt: Bool

    /// `<cli> plugin <动词> lightty@lightty`：首次安装的动词。
    public let pluginInstallVerb: String

    /// 同上，插件**已装**时的动词。Claude Code 的 `install` 在已装时是空操作，
    /// 哪怕 marketplace 里的版本变了也不会重新拷贝，所以必须换成 `update`；
    /// Codex 的 `add` 每次都重新拷贝，一个词兼任安装与更新。
    public let pluginUpdateVerb: String

    /// 同上，卸载的动词。
    public let pluginRemoveVerb: String

    /// 这家读的那份 marketplace 清单，相对 marketplace 根。
    public let marketplaceManifestPath: String

    /// 这家读的那份插件清单，相对插件目录。
    public let pluginManifestPath: String

    /// 这家读的那份 hook 定义，相对插件目录。Claude Code 走 `hooks/` 目录约定，
    /// Codex 不看目录、由它自己那份清单指路。
    public let hooksDocumentPath: String

    /// 这家经 OSC 0 写进终端标题的形状：哪些前缀表示忙、闲、等用户处理，见 `AgentTerminalTitle`。
    public let terminalTitle: TerminalTitleShape

    public init(
        executableName: String,
        configurationVariable: String,
        standardConfigurationDirectory: String,
        sourceName: String,
        launchName: String,
        iconToolTip: String,
        iconAssetName: String,
        resumeShape: ResumeShape,
        pickerArguments: [String],
        bypassArguments: [String],
        skillInvocationSigil: String,
        hookEvents: [String],
        hookConfigFile: String,
        hookConfigFormat: HookConfigFormat,
        requiresHookTrustPrompt: Bool,
        pluginInstallVerb: String,
        pluginUpdateVerb: String,
        pluginRemoveVerb: String,
        marketplaceManifestPath: String,
        pluginManifestPath: String,
        hooksDocumentPath: String,
        terminalTitle: TerminalTitleShape
    ) {
        self.executableName = executableName
        self.configurationVariable = configurationVariable
        self.standardConfigurationDirectory = standardConfigurationDirectory
        self.sourceName = sourceName
        self.launchName = launchName
        self.iconToolTip = iconToolTip
        self.iconAssetName = iconAssetName
        self.resumeShape = resumeShape
        self.pickerArguments = pickerArguments
        self.bypassArguments = bypassArguments
        self.skillInvocationSigil = skillInvocationSigil
        self.hookEvents = hookEvents
        self.hookConfigFile = hookConfigFile
        self.hookConfigFormat = hookConfigFormat
        self.requiresHookTrustPrompt = requiresHookTrustPrompt
        self.pluginInstallVerb = pluginInstallVerb
        self.pluginUpdateVerb = pluginUpdateVerb
        self.pluginRemoveVerb = pluginRemoveVerb
        self.marketplaceManifestPath = marketplaceManifestPath
        self.pluginManifestPath = pluginManifestPath
        self.hooksDocumentPath = hooksDocumentPath
        self.terminalTitle = terminalTitle
    }

    /// 两家都订阅的事件。各家在自己的文件里只写「我比共有的多哪几个」，
    /// 共有的这一份不抄两遍：抄两遍就会出现「给一家加了事件、另一家忘了」。
    public static let sharedHookEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd",
    ]
}

extension SessionAgent {
    /// **全 app 唯一**按 Agent 穷举的 switch。多一家 Agent 时这里是编译错误，
    /// 而不是别处默默被当成 Claude。
    public var spec: AgentSpec {
        switch self {
        case .claude: return ClaudeAgent.spec
        case .codex: return CodexAgent.spec
        }
    }
}
