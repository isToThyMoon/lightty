import Darwin
import Foundation
import LighttyCore

/// 把 lightty 的状态 hook 注册进用户已装的 agent（Claude Code / Codex）。
///
/// **我们不再改写用户的配置文件**。hook 定义住在我们自己的 marketplace 里
/// （`HookMarketplace`），注册由**两家自己的 CLI** 完成：
///
/// ```
/// claude plugin marketplace add ~/.lightty/marketplace
/// claude plugin install lightty@lightty
///
/// codex plugin marketplace add ~/.lightty/marketplace
/// codex plugin add lightty@lightty          # plugin@marketplace 形式是强制的
/// ```
///
/// 于是全项目风险最高的那段「读 → 合并 → 备份 → 原子写用户配置」机器整体退役：
/// 我们既不需要理解它们的配置格式，也就不可能写坏它。留在这里的只有三件事：
///
/// 1. **shim**（`refreshShim`）——生成的 hooks 指向它，路径必须稳定。
/// 2. **只读探测**——判断装没装。读用户配置，一个字节都不写。
/// 3. **跑 CLI**——带超时的子进程，输出原样带回，非零退出变成结构化错误。
///
/// 本类型有意不依赖 AppKit，也不引用 `L()`：纯逻辑便于测试，
/// 错误只携带结构化数据，文案由 `HookSetupOverlay` 负责。
enum HookInstaller {
    /// bundle 内真实 helper 的可执行文件名（与 Package.swift 的 target 名一致）
    static let helperName = "lightty-hook"

    // MARK: - 稳定 shim

    /// `~/.lightty/bin`
    static var shimDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lightty/bin", isDirectory: true)
    }

    /// `~/.lightty/bin/lightty-hook`——写进 hooks.json 的就是这个绝对路径。
    static var shimPath: URL {
        shimDirectory.appendingPathComponent(helperName)
    }

    /// bundle 内 helper 的当前位置。
    ///
    /// `.app` 里是 `Contents/MacOS/lightty-hook`，`swift run` 时是 `.build/debug/lightty-hook`：
    /// 两种布局下 helper 都与主可执行文件同级，一条规则通吃，不必分支判断运行方式。
    static var bundledHelper: URL {
        let executable = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "")
        return executable.deletingLastPathComponent().appendingPathComponent(helperName)
    }

    enum ShimStatus: Equatable {
        /// symlink 已指向 target
        case linked(target: URL)
        /// helper 不在预期位置（开发期没 build lightty-hook target 就会这样）
        case helperMissing(expected: URL)
        case failed(reason: String)
    }

    /// **每次启动都要调用**。
    ///
    /// hooks.json 里写的是绝对路径，用户把 app 从下载目录拖进 `/Applications` 后
    /// bundle 内路径就断了。这层 symlink 是稳定的间接层：路径不变，指向每次启动刷新。
    /// 路径稳定还有第二重好处——hooks.json 的内容不随 app 位置变，插件版本
    /// （见 `HookMarketplace.version`）也就不会因为挪个位置就要求重装。
    @discardableResult
    static func refreshShim() -> ShimStatus {
        let fm = FileManager.default
        let target = bundledHelper

        // helper 不存在时**不动现有 symlink**：开发期跑未 build helper 的构建，
        // 不该把用户已经装好的、指向正式 app 的链接删掉。
        guard fm.isExecutableFile(atPath: target.path) else {
            return .helperMissing(expected: target)
        }

        do {
            try fm.createDirectory(at: shimDirectory, withIntermediateDirectories: true)
            // attributesOfItem 不跟随最后一级 symlink（lstat 语义），
            // 断链的 symlink 也能被识别出来并清掉——fileExists 对断链返回 false，不能用。
            if let attributes = try? fm.attributesOfItem(atPath: shimPath.path) {
                if attributes[.type] as? FileAttributeType == .typeSymbolicLink,
                   (try? fm.destinationOfSymbolicLink(atPath: shimPath.path)) == target.path {
                    return .linked(target: target)
                }
                try fm.removeItem(at: shimPath)
            }
            try fm.createSymbolicLink(at: shimPath, withDestinationURL: target)
            return .linked(target: target)
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    /// **启动时调这个**：刷 shim，顺带把 marketplace 重新生成一遍。
    ///
    /// 两件事必须同时做——marketplace 里的 hooks 写的就是 shim 路径，只刷一半
    /// 等于让插件指向一个可能已经不对的位置。生成失败在这里**静默**：它不影响
    /// 已经装好的插件（两家都是安装时拷贝走的），而真正需要这棵树的是安装，
    /// 那条路径会带着 `writeFailed` 把原因报给用户。
    @discardableResult
    static func refresh() -> ShimStatus {
        let status = refreshShim()
        if case .linked = status {
            _ = try? HookMarketplace.generate(command: shimPath.path)
        }
        return status
    }

    // MARK: - 测试缝

    /// 所有「会碰真实文件系统 / 会起子进程」的入口集中成一处参数。
    ///
    /// 测试全部注入自己的 `Context`：这样「安装器从不写 agent 配置」这条断言
    /// 可以被真正验证——`run` 是个只记账不执行的假实现，配置文件是临时目录里的 fixture。
    struct Context {
        var marketplaceRoot: URL
        var shimPath: URL
        /// 我们自己的台账目录：**一个 agent 一个文件**
        var stateDirectory: URL
        /// agent → CLI 绝对路径；nil = PATH 上找不到
        var executable: (HookAgent) -> String?
        /// agent → 我们**只读**解析的那份配置
        var configFile: (HookAgent) -> URL
        /// 跑一条命令，返回 stdout+stderr 合流的输出；失败抛 `HookCLIError`
        var run: (_ executable: String, _ arguments: [String]) throws -> String

        static var live: Context {
            Context(
                marketplaceRoot: HookMarketplace.root,
                shimPath: HookInstaller.shimPath,
                stateDirectory: HookInstaller.stateDirectory,
                executable: { locateExecutable($0.executableName) },
                configFile: { $0.configFile },
                run: { try HookCLI.run($0, $1) })
        }
    }

    /// `~/.lightty/hook-plugins`——台账目录，每个 agent 一个 `<agent>.version` 文件。
    ///
    /// 一开始这里是一份两家共用的 JSON，靠读-改-写维护。那是错的：两个 agent
    /// 的安装本就互不相干，凑在一个文件里就制造出一份共享可变状态，并发写会丢条目。
    /// 拆成一个 agent 一个文件之后，两条路径不再有任何交集，正确性也就不依赖
    /// 「调用方恰好串行」这个外部条件。
    static var stateDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lightty/hook-plugins", isDirectory: true)
    }

    // MARK: - 探测（全程只读）

    /// 单个 agent 的探测结果，UI 直接消费。
    struct Report {
        let agent: HookAgent
        /// 装没装这个 agent。**以 CLI 在不在为准**——注册要靠它们自己的 CLI 完成，
        /// 光有配置目录我们什么也做不了。
        let isAgentPresent: Bool
        let executablePath: String?
        let state: State
        /// 已装，但装进去的是旧内容（**这个 agent 自己的**事件表变过）。
        /// 两家都在安装时拷贝插件，改 marketplace 不会自动生效，得让 CLI 再跑一次。
        let needsUpdate: Bool
        /// 该 agent 当前应装的插件版本，`0.1.0+<自己那份 hooks 的哈希>`
        let version: String
    }

    enum State: Equatable {
        /// 没装这个 agent（CLI 找不到）
        case agentMissing
        /// 装了 agent，配置里没有我们的声明
        case notInstalled
        /// marketplace 与插件开关只声明了一半（手工改过配置，或卸载只卸了一半）
        case partial(missing: [String])
        case installed
        /// 配置文件存在但读不懂——**这种情况下我们本来也不写，只是没法判断状态**
        case unreadable(reason: String)
    }

    static func report(for agent: HookAgent, in context: Context = .live) -> Report {
        let executable = context.executable(agent)
        let version = HookMarketplace.version(for: agent, command: context.shimPath.path)
        guard let executable else {
            return Report(
                agent: agent, isAgentPresent: false, executablePath: nil,
                state: .agentMissing, needsUpdate: false, version: version)
        }

        let state: State
        var needsUpdate = false
        do {
            let declaration = try agent.readDeclaration(at: context.configFile(agent))
            switch (declaration.marketplaceDeclared, declaration.pluginEnabled) {
            case (true, true):
                state = .installed
                // 台账里没有记录也当成要更新：宁可让 CLI 空跑一次幂等命令，
                // 也不要让用户的 agent 悄悄跑着旧事件表。
                needsUpdate = installedVersion(of: agent, in: context) != version
            case (false, false):
                state = .notInstalled
            case (true, false):
                state = .partial(missing: [HookMarketplace.pluginID])
            case (false, true):
                state = .partial(missing: [HookMarketplace.marketplaceName])
            }
        } catch {
            state = .unreadable(reason: (error as? HookInstallError)?.reason
                ?? error.localizedDescription)
        }
        return Report(
            agent: agent, isAgentPresent: true, executablePath: executable,
            state: state, needsUpdate: needsUpdate, version: version)
    }

    static func reports(in context: Context = .live) -> [Report] {
        HookAgent.allCases.map { report(for: $0, in: context) }
    }

    /// PATH + 常见安装目录里找可执行文件。
    ///
    /// 从 Finder 启动时 PATH 只有 `/usr/bin:/bin:/usr/sbin:/sbin`，用户级安装位置
    /// （npm global、homebrew、claude 自带 installer）全都看不见，只查 PATH 会误判"没装"。
    static func locateExecutable(_ name: String) -> String? {
        let fm = FileManager.default
        for directory in searchPath() {
            let path = (directory as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// 查找目录清单，同时也是子进程 PATH 的来源——`claude` 是个 node 包装脚本，
    /// PATH 里没有 node 它会自己失败，而 Finder 启动的 PATH 恰恰什么都没有。
    static func searchPath() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        directories += [
            "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.cargo/bin",
            "\(home)/.npm-global/bin", "\(home)/.claude/local", "\(home)/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        var seen = Set<String>()
        return directories.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: - 安装 / 卸载

    struct Outcome {
        let agent: HookAgent
        /// CLI 会改写的那份配置。**展示用**——写它的是 CLI，不是我们。
        let configPath: URL
        /// 依次成功执行过的命令行，原样可复制粘贴（出问题时用户能自己重跑一遍）
        let commands: [String]
        /// 本次落地的插件版本
        let version: String
        /// true = 这是一次卸载
        let removed: Bool
    }

    /// **阻塞**：会起子进程并等待。UI 请走 `install(_:completion:)`。
    @discardableResult
    static func install(_ agent: HookAgent, in context: Context = .live) throws -> Outcome {
        // 注册一条指向不存在文件的命令，只会让 agent 每次事件都报错，不如直接拒绝
        guard FileManager.default.isExecutableFile(atPath: context.shimPath.path) else {
            throw HookInstallError.shimUnavailable(expected: context.shimPath.path)
        }
        guard let cli = context.executable(agent) else {
            throw HookCLIError.notFound(executable: agent.executableName)
        }

        let generation = try HookMarketplace.generate(
            command: context.shimPath.path, root: context.marketplaceRoot)
        let declaration = (try? agent.readDeclaration(at: context.configFile(agent)))
            ?? HookAgent.Declaration(marketplaceDeclared: false, pluginEnabled: false)

        var commands: [String] = []
        for arguments in agent.installCommands(
            marketplaceRoot: generation.root, isPluginInstalled: declaration.pluginEnabled) {
            _ = try context.run(cli, arguments)
            commands.append(([cli] + arguments).joined(separator: " "))
        }
        let version = generation.version(for: agent)
        record(version: version, for: agent, in: context)
        return Outcome(
            agent: agent, configPath: context.configFile(agent), commands: commands,
            version: version, removed: false)
    }

    /// **阻塞**：同上。UI 请走 `uninstall(_:completion:)`。
    ///
    /// 只跑「配置里确实有这一条」的那几步：CLI 对着不存在的插件会以非零退出，
    /// 我们没必要把那种噪音当成失败报给用户。
    @discardableResult
    static func uninstall(_ agent: HookAgent, in context: Context = .live) throws -> Outcome {
        guard let cli = context.executable(agent) else {
            throw HookCLIError.notFound(executable: agent.executableName)
        }
        let declaration = (try? agent.readDeclaration(at: context.configFile(agent)))
            ?? HookAgent.Declaration(marketplaceDeclared: false, pluginEnabled: false)

        var commands: [String] = []
        for arguments in agent.uninstallCommands(declaration: declaration) {
            _ = try context.run(cli, arguments)
            commands.append(([cli] + arguments).joined(separator: " "))
        }
        record(version: nil, for: agent, in: context)
        return Outcome(
            agent: agent, configPath: context.configFile(agent), commands: commands,
            version: HookMarketplace.version(for: agent, command: context.shimPath.path),
            removed: true)
    }

    // MARK: - UI 入口（不阻塞主线程）

    /// 串行队列。**它不承担正确性**——两家 agent 的安装没有任何共享可变状态：
    /// 台账一家一个文件，marketplace 生成是原子写且内容不变就不写，
    /// 两条路径并发跑也不会互相破坏。
    ///
    /// 留着它只为两件事：让「连点两下按钮」的完成顺序与点击顺序一致，
    /// 以及避免两个几秒钟的 CLI 同时抢机器。
    private static let queue = DispatchQueue(
        label: "com.lightty.hook-installer", qos: .userInitiated)

    /// 后台执行，**主线程回调**。CLI 起进程要几秒，绝不能压在主线程上。
    static func install(
        _ agent: HookAgent, in context: Context = .live,
        completion: @escaping (Result<Outcome, Error>) -> Void
    ) {
        perform({ try install(agent, in: context) }, completion: completion)
    }

    static func uninstall(
        _ agent: HookAgent, in context: Context = .live,
        completion: @escaping (Result<Outcome, Error>) -> Void
    ) {
        perform({ try uninstall(agent, in: context) }, completion: completion)
    }

    private static func perform(
        _ body: @escaping () throws -> Outcome,
        completion: @escaping (Result<Outcome, Error>) -> Void
    ) {
        queue.async {
            let result = Result { try body() }
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - 版本台账

    /// 该 agent 的台账文件：`~/.lightty/hook-plugins/<agent>.version`，
    /// 内容就是一行版本串——一个值不值得一层 JSON。
    static func versionFile(for agent: HookAgent, in context: Context = .live) -> URL {
        context.stateDirectory.appendingPathComponent("\(agent.rawValue).version")
    }

    /// 我们**只记自己装过什么**，不去读两家的内部安装台账
    /// （`~/.claude/plugins/installed_plugins.json`、`~/.codex/plugins/cache/…`）：
    /// 那是它们的实现细节，随时会变。台账丢了最多让 CLI 多跑一次幂等命令。
    static func installedVersion(of agent: HookAgent, in context: Context = .live) -> String? {
        guard let raw = try? String(
            contentsOf: versionFile(for: agent, in: context), encoding: .utf8) else { return nil }
        let version = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    /// `version == nil` 表示卸载：直接删掉这个 agent 的台账文件。
    ///
    /// 只碰自己那一个文件，读-改-写没有了，两家同时装也不可能互相盖掉。
    private static func record(version: String?, for agent: HookAgent, in context: Context) {
        let file = versionFile(for: agent, in: context)
        guard let version else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        // 台账写失败不影响已经装好的插件，静默即可——下次探测把它当成"没记录"，
        // 最坏结果是多跑一次幂等的 update。
        try? FileManager.default.createDirectory(
            at: context.stateDirectory, withIntermediateDirectories: true)
        try? PaneRuntimeDirectory.atomicWrite(Data("\(version)\n".utf8), to: file)
    }
}

// MARK: - Agent

/// 支持的 agent 及其插件注册约定。
enum HookAgent: String, CaseIterable, Sendable {
    case claudeCode
    case codex

    /// PATH 上的可执行文件名
    var executableName: String {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        }
    }

    /// 配置目录。两家都支持用环境变量改写位置，跟着走才能和 CLI 看到同一份配置。
    var configDirectory: URL {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claudeCode:
            if let override = environment["CLAUDE_CONFIG_DIR"], !override.isEmpty {
                return URL(fileURLWithPath: override, isDirectory: true)
            }
            return home.appendingPathComponent(".claude", isDirectory: true)
        case .codex:
            if let override = environment["CODEX_HOME"], !override.isEmpty {
                return URL(fileURLWithPath: override, isDirectory: true)
            }
            return home.appendingPathComponent(".codex", isDirectory: true)
        }
    }

    /// CLI 会往里写声明的那份文件。我们**只读**它，用来判断装没装。
    var configFile: URL {
        switch self {
        case .claudeCode: return configDirectory.appendingPathComponent("settings.json")
        case .codex: return configDirectory.appendingPathComponent("config.toml")
        }
    }

    /// 事件 key **必须是 PascalCase**（实测：snake_case / camelCase 均不触发）。
    /// 状态机映射见 docs/specs/pane-status.md §4.3。
    var events: [String] {
        let shared = [
            "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd",
        ]
        switch self {
        // Notification 是 Claude Code 侧的「需要用户介入」信号
        case .claudeCode: return shared + ["Notification"]
        // Codex 侧同语义的事件叫 PermissionRequest；用户主动停止单独发 Interrupt，
        // 不会补一发 Stop，漏订阅就会让 pane 永久停在 thinking/tool。
        case .codex: return shared + ["PermissionRequest", "Interrupt"]
        }
    }

    /// Codex 对 hook **按内容**做信任校验，首次需用户批准；插件来源并不豁免
    /// （实测：`trustStatus` 与 `marketplaceName` 同属一个结构体）。
    /// 我们不绕过，也绝不该绕过——但必须**事先**告诉用户，否则下次跑 codex
    /// 冒出来的审核提示看起来就像中招了。
    var requiresTrustPrompt: Bool { self == .codex }

    // MARK: - 配置里的声明（只读）

    /// 用户配置里与我们相关的两个开关。CLI 写它们，我们只看。
    struct Declaration: Equatable {
        var marketplaceDeclared: Bool
        var pluginEnabled: Bool
    }

    func readDeclaration(at file: URL) throws -> Declaration {
        switch self {
        case .claudeCode: return try claudeDeclaration(at: file)
        case .codex: return codexDeclaration(at: file)
        }
    }

    /// Claude Code 写的是 `settings.json`：
    /// ```json
    /// {"extraKnownMarketplaces":{"lightty":{"source":{…}}},
    ///  "enabledPlugins":{"lightty@lightty":true}}
    /// ```
    private func claudeDeclaration(at file: URL) throws -> Declaration {
        guard let data = try? Data(contentsOf: file) else {
            return Declaration(marketplaceDeclared: false, pluginEnabled: false)
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        // 空文件不是合法 JSON，但语义上就是"还没配过"
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Declaration(marketplaceDeclared: false, pluginEnabled: false)
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw HookInstallError.unparseable(path: file.path, reason: error.localizedDescription)
        }
        guard let root = object as? [String: Any] else {
            throw HookInstallError.unexpectedShape(detail: "top level is not a JSON object")
        }
        let marketplaces = root["extraKnownMarketplaces"] as? [String: Any]
        let plugins = root["enabledPlugins"] as? [String: Any]
        return Declaration(
            marketplaceDeclared: marketplaces?[HookMarketplace.marketplaceName] != nil,
            pluginEnabled: plugins?[HookMarketplace.pluginID] as? Bool == true)
    }

    /// Codex 写的是 `config.toml`：
    /// ```toml
    /// [marketplaces.lightty]
    /// source_type = "local"
    /// [plugins."lightty@lightty"]
    /// enabled = true
    /// ```
    /// 这里做的是**定向扫描**而不是完整 TOML 解析：我们只关心两个表头在不在、
    /// `[plugins."…"]` 表里 `enabled` 是不是 true。为一个布尔值引入 TOML 解析器
    /// （以及它对用户文件的一整套语义假设）不划算；扫不出来最坏是报「没装」，
    /// 用户点一次 Install，CLI 自己会把重复声明处理好。
    private func codexDeclaration(at file: URL) -> Declaration {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            return Declaration(marketplaceDeclared: false, pluginEnabled: false)
        }
        var marketplaceDeclared = false
        var pluginEnabled = false
        var insidePluginTable = false

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                // 新表头 = 上一张表结束
                let header = line.drop(while: { $0 == "[" })
                    .prefix(while: { $0 != "]" })
                    .trimmingCharacters(in: .whitespaces)
                insidePluginTable = header == "plugins.\"\(HookMarketplace.pluginID)\""
                if header == "marketplaces.\(HookMarketplace.marketplaceName)" {
                    marketplaceDeclared = true
                }
                continue
            }
            guard insidePluginTable, line.hasPrefix("enabled") else { continue }
            let value = line.drop(while: { $0 != "=" }).dropFirst()
                .trimmingCharacters(in: .whitespaces)
            // 尾部注释：`enabled = true # 手工关掉过`
            if value.split(whereSeparator: { $0 == " " || $0 == "#" }).first == "true" {
                pluginEnabled = true
            }
        }
        return Declaration(
            marketplaceDeclared: marketplaceDeclared, pluginEnabled: pluginEnabled)
    }

    // MARK: - CLI 命令

    /// 安装。两条命令都幂等（实测重复执行只打印"已存在"并以 0 退出）。
    ///
    /// Claude Code 的 `install` 在插件已装时是**空操作**，哪怕 marketplace 里的
    /// 版本变了也不会重新拷贝——所以已装时必须换成 `update`。
    /// Codex 的 `add` 则每次都重新拷贝，一条命令兼任安装与更新。
    func installCommands(marketplaceRoot: URL, isPluginInstalled: Bool) -> [[String]] {
        switch self {
        case .claudeCode:
            return [
                ["plugin", "marketplace", "add", marketplaceRoot.path],
                [
                    "plugin", isPluginInstalled ? "update" : "install",
                    HookMarketplace.pluginID,
                ],
            ]
        case .codex:
            return [
                ["plugin", "marketplace", "add", marketplaceRoot.path],
                // plugin@marketplace 形式是**强制**的，否则报 "requires --marketplace"
                ["plugin", "add", HookMarketplace.pluginID],
            ]
        }
    }

    /// 卸载。marketplace 声明也一并撤掉——只卸插件的话，用户配置里会留下一条
    /// 指向 `~/.lightty/marketplace` 的孤儿条目，那正是我们想避免的痕迹。
    func uninstallCommands(declaration: Declaration) -> [[String]] {
        var commands: [[String]] = []
        if declaration.pluginEnabled {
            switch self {
            case .claudeCode: commands.append(["plugin", "uninstall", HookMarketplace.pluginID])
            case .codex: commands.append(["plugin", "remove", HookMarketplace.pluginID])
            }
        }
        if declaration.marketplaceDeclared {
            commands.append(
                ["plugin", "marketplace", "remove", HookMarketplace.marketplaceName])
        }
        return commands
    }
}

// MARK: - CLI 子进程

/// 跑 agent 自己的 CLI。**带超时**——CLI 卡住（等 stdin、等网络）不能把 app 一起冻住。
enum HookCLI {
    /// `claude plugin install` 实测 2~4 秒（node 启动 + 校验），留足余量但不无限等。
    static let defaultTimeout: TimeInterval = 60

    /// 返回 stdout 与 stderr 合流的输出。两家 CLI 都把成功信息打在 stdout、
    /// 失败原因打在两边都有的地方，分开收只会让错误信息缺一半。
    @discardableResult
    static func run(
        _ executable: String, _ arguments: [String], timeout: TimeInterval = defaultTimeout
    ) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw HookCLIError.notFound(executable: executable)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment()
        // 从 Finder 启动时 cwd 是 `/`，CLI 可能拿它当项目目录去猜作用域
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        // 空 stdin：CLI 若想交互提问，让它立刻拿到 EOF 而不是永远等我们
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        // 等待期间必须持续排空管道：64KB 缓冲写满后子进程会阻塞在 write，
        // 于是它永远不退出、我们永远等不到——最后只能超时收场。
        let sink = OutputSink()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            sink.append(handle.availableData)
        }

        let line = ([executable] + arguments).joined(separator: " ")
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            // 上面刚查过可执行位，走到这里多半是权限/架构问题——原因原样带出去，
            // 别一律说成"找不到"把人往错方向指
            throw HookCLIError.failed(
                command: line, status: -1, output: error.localizedDescription)
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            pipe.fileHandleForReading.readabilityHandler = nil
            process.terminate()
            // 给它两秒体面退出，不走就硬杀——留个孤儿进程占着我们的管道更糟
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            throw HookCLIError.timedOut(command: line, seconds: timeout)
        }

        pipe.fileHandleForReading.readabilityHandler = nil
        // terminationHandler 可能早于读端排干净，补一次读到 EOF
        if let rest = try? pipe.fileHandleForReading.readToEnd() { sink.append(rest) }
        let output = sink.text()

        guard process.terminationStatus == 0 else {
            throw HookCLIError.failed(
                command: line, status: process.terminationStatus, output: output)
        }
        return output
    }

    /// 子进程环境。`claude` 是 node 包装脚本，PATH 里没有 node 它自己就失败了，
    /// 而 Finder 启动的 lightty PATH 恰恰只有 `/usr/bin:/bin:/usr/sbin:/sbin`。
    private static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = HookInstaller.searchPath().joined(separator: ":")
        return environment
    }

    /// `readabilityHandler` 在私有队列上回调，累积缓冲区必须自己上锁。
    private final class OutputSink {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func text() -> String {
            lock.lock()
            defer { lock.unlock() }
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }
}

/// CLI 侧的失败。与 `HookInstallError`（我们自己的文件/资源问题）分开：
/// 这一类的原因全在别人家进程里，能给用户的只有原样的输出。
enum HookCLIError: Error, LocalizedError, Equatable {
    /// PATH 上找不到 CLI（探测阶段本应先报 `.agentMissing`，这里是竞态兜底）
    case notFound(executable: String)
    case timedOut(command: String, seconds: TimeInterval)
    /// 非零退出，`output` 是 stdout+stderr 合流的原文
    case failed(command: String, status: Int32, output: String)

    /// UI 未迁移前会落到 `localizedDescription`，所以这里给的是能直接看的英文。
    var errorDescription: String? {
        switch self {
        case .notFound(let executable):
            return "\(executable) was not found on this Mac."
        case .timedOut(let command, let seconds):
            return "`\(command)` did not finish within \(Int(seconds))s."
        case .failed(let command, let status, let output):
            return output.isEmpty
                ? "`\(command)` failed with exit code \(status)."
                : "`\(command)` failed with exit code \(status):\n\(output)"
        }
    }
}

// MARK: - 错误

enum HookInstallError: Error {
    /// 读 agent 配置判断状态时：文件不是合法 JSON。我们**本来也不写**，
    /// 只是没法判断装没装。
    case unparseable(path: String, reason: String)
    /// JSON 合法但顶层结构不是我们认识的形状——同样只影响判断
    case unexpectedShape(detail: String)
    /// 生成 `~/.lightty/marketplace` 失败
    case writeFailed(path: String, reason: String)
    /// `~/.lightty/bin/lightty-hook` 还没建好（开发期没 build helper target）
    case shimUnavailable(expected: String)

    /// 供 UI 拼文案的原始描述，本身不做本地化
    var reason: String {
        switch self {
        case .unparseable(let path, let reason): return "\(path): \(reason)"
        case .unexpectedShape(let detail): return detail
        case .writeFailed(let path, let reason): return "\(path): \(reason)"
        case .shimUnavailable(let expected): return expected
        }
    }
}
