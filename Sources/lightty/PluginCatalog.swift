import Foundation
import LighttyCore

/// 插件所属的 Agent。两个 Agent 各有自己的安装记录与启用开关，同一个
/// `name@marketplace` 可能同时装在两边，所以 Agent 是插件身份的一部分。
enum PluginAgent: String, Codable, Sendable, CaseIterable {
    case claudeCode = "claude", codex

    /// 会话侧的同一家。rawValue 已经落进快照与导航键，所以两个枚举不合并；
    /// 映射用穷举 switch，多一家 Agent 时是编译错误而不是默默当成 Claude Code。
    var sessionAgent: SessionAgent {
        switch self {
        case .claudeCode: return .claude
        case .codex: return .codex
        }
    }

    var title: String { sessionAgent.spec.launchName }
}

/// 装上不等于开着，缓存里有更不等于装上了。
enum PluginState: String, Sendable {
    /// 配置里明确写着开。
    case enabled
    /// 有安装记录，但配置里没开（Claude 缺键也算这一档：缺键不能宣称已启用）。
    case disabled
    /// 只在 Codex 缓存里找得到，官方安装清单没有这一条。
    case cachedOnly
}

enum PluginContentKind: String, Sendable, CaseIterable {
    case skill, command, agent, hook, mcpServer, appConnector
}

/// 插件里的一条内容：一个技能、一条命令、一个子 Agent、一个 hook 事件、一个 MCP
/// server，或一个 app connector。前三种是进上下文的文本，后三种是外部能力。
struct PluginContent: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let kind: PluginContentKind
    let summary: String
    let content: String
    /// 正文是 Markdown（走阅读排版）还是 JSON 片段（原样等宽显示）。
    let isMarkdown: Bool
    let fileURL: URL
    /// 同一条内容的全部来源路径。Codex 缓存里多个版本的同名内容合并成一条，
    /// 每个版本的路径都留在这里。
    var locations: [URL]
    let issue: String?
}

struct PluginRecord: Identifiable, Equatable, Sendable {
    /// 跨 Agent 唯一：同一个 `name@marketplace` 两个 Agent 可以各装一份。
    var id: String { "\(agent.rawValue):\(identifier)" }
    /// 两个 Agent 通用的插件标识，形如 `name@marketplace`。
    let identifier: String
    let name: String
    let marketplace: String
    let agent: PluginAgent
    /// 生效版本。无记录、或有多个缓存版本无法判定时为 nil。
    let version: String?
    /// 安装目录（Claude）或缓存版本目录（Codex，可能有多个）。
    let roots: [URL]
    var state: PluginState
    let summary: String
    /// Codex 清单 `interface.shortDescription` 的一句话介绍，Codex app 列表里显示的就是它。
    /// Claude Code 的清单没有对等字段，那边恒为空。
    var tagline: String = ""
    let author: String
    /// 版本来源的说明，例如「缓存里有多个版本，无法判定生效的是哪个」。
    let versionNote: String?
    var contents: [PluginContent]
    let issue: String?
    /// Claude Code 的使用计数；Codex 不记这个，那边恒为 nil。
    var usage: UsageRecord? = nil

    var root: URL? { roots.first }
    /// 只有已安装的插件才谈得上开关。
    var canToggle: Bool { state != .cachedOnly }
}

struct PluginCatalogSnapshot: Sendable {
    var plugins: [PluginRecord] = []
    var warnings: [String] = []
    var codexQueryFailed = false
    /// 最近一次成功拿到的 Codex 安装清单。app-server 冷启动第一问要两秒多，本地文件几十毫秒就读完；
    /// 留着它，下次可以先照这份清单把本地内容摆出来，再等 Codex 校正。nil 表示从没成功过。
    var codexInventory: CodexPluginInventory.Inventory? = nil
}

enum PluginWriteError: LocalizedError {
    case cachedOnly(String)
    case unreadable(path: String, reason: String)
    case unsupportedShape(path: String, detail: String)
    case notApplied(path: String)

    var errorDescription: String? {
        switch self {
        case .cachedOnly(let id):
            return "\(id) is only present in the Codex cache. It is not in the Codex installed list, so it cannot be enabled from here."
        case .unreadable(let path, let reason):
            return "Cannot read \(path): \(reason)"
        case .unsupportedShape(let path, let detail):
            return "\(path) has a shape this editor will not rewrite: \(detail). The file was left untouched."
        case .notApplied(let path):
            return "The edit to \(path) did not take effect. The file was left untouched."
        }
    }
}

/// 读取两个 Agent 的插件安装记录与内容。`scan()` 只读，不写任何文件；
/// 写入集中在 `setEnabled(_:for:)`，那是本类型唯一改用户文件的入口。
struct PluginCatalog {
    private let home: URL
    private let environment: [String: String]
    private let inventory: (URL, [String: String]) throws -> CodexPluginInventory.Inventory

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         inventory: @escaping (URL, [String: String]) throws -> CodexPluginInventory.Inventory = CodexPluginInventory.load) {
        self.home = home
        self.environment = environment
        self.inventory = inventory
    }

    var claudeManifestURL: URL { home.appendingPathComponent(".claude/plugins/installed_plugins.json") }
    var claudeSettingsURL: URL { home.appendingPathComponent(".claude/settings.json") }
    /// CODEX_HOME 覆盖 `~/.codex`，与 SkillCatalog 的环境变量口径一致。
    var codexHome: URL {
        guard let path = environment["CODEX_HOME"], !path.isEmpty else {
            return home.appendingPathComponent(".codex")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    var codexConfigURL: URL { codexHome.appendingPathComponent("config.toml") }
    var codexCacheURL: URL { codexHome.appendingPathComponent("plugins/cache") }

    /// 同一份配置根只该有一份缓存：设置页每次打开都是新视图，测试各用各的临时目录。
    var cacheKey: String { "\(home.path)|\(codexHome.path)" }

    /// `queryCodex` 为 false 时不问 Codex，沿用 `previous` 里的清单重读本地文件。
    func scan(previous: PluginCatalogSnapshot? = nil, queryCodex: Bool = true) -> PluginCatalogSnapshot {
        var reader = Reader()
        var plugins = reader.scanClaude(manifest: claudeManifestURL, settings: claudeSettingsURL)
        let usage = ClaudeUsage.read(home: home).plugins
        for index in plugins.indices { plugins[index].usage = usage[plugins[index].identifier] }
        var codexQueryFailed = queryCodex ? false : previous?.codexQueryFailed ?? false
        var installed = previous?.codexInventory
        if queryCodex {
            do {
                installed = try inventory(codexHome, environment)
            } catch {
                codexQueryFailed = true
                reader.warnings.append("Codex plugin refresh failed; showing the last successful result if available. \(error.localizedDescription)")
            }
        }
        // 从没拿到过清单就不列 Codex：缓存目录冒充不了安装清单。
        if let installed {
            reader.warnings += installed.loadErrors
            plugins += reader.scanCodex(cache: codexCacheURL, installed: installed.entries)
        }
        let order = PluginAgent.allCases.enumerated().reduce(into: [PluginAgent: Int]()) { $0[$1.element] = $1.offset }
        return PluginCatalogSnapshot(plugins: plugins.sorted { lhs, rhs in
            if lhs.agent != rhs.agent { return order[lhs.agent]! < order[rhs.agent]! }
            let byName = lhs.name.localizedStandardCompare(rhs.name)
            return byName == .orderedSame ? lhs.identifier < rhs.identifier : byName == .orderedAscending
        }, warnings: reader.warnings, codexQueryFailed: codexQueryFailed, codexInventory: installed)
    }

    // MARK: - 启停

    /// 写入启用状态。先备份、再原子替换，除这一个布尔值外的内容原样保留。
    func setEnabled(_ value: Bool, for plugin: PluginRecord) throws {
        switch plugin.agent {
        case .claudeCode:
            try ConfigFile.rewrite(claudeSettingsURL, empty: "{}\n") { text in
                try JSONTextEdit.setBoolean(value, at: ["enabledPlugins", plugin.identifier], in: text)
            } verify: { text in
                JSONTextEdit.boolean(at: ["enabledPlugins", plugin.identifier], in: text) == value
            }
        case .codex:
            guard plugin.canToggle else { throw PluginWriteError.cachedOnly(plugin.identifier) }
            try ConfigFile.rewrite(codexConfigURL, empty: "") { text in
                try TOMLTextEdit.setPluginEnabled(value, id: plugin.identifier, in: text)
            } verify: { text in
                TOMLTextEdit.pluginEnabled(id: plugin.identifier, in: text) == value
            }
        }
    }

    // MARK: - 扫描

    private struct Reader {
        var warnings: [String] = []
        private let files = FileManager.default

        // MARK: Claude Code

        mutating func scanClaude(manifest: URL, settings: URL) -> [PluginRecord] {
            guard let json = jsonObject(at: manifest) else { return [] }
            guard let plugins = json["plugins"] as? [String: Any] else {
                warnings.append("Invalid plugin installation record: \(manifest.path)")
                return []
            }
            let enabled = (jsonObject(at: settings)?["enabledPlugins"] as? [String: Any]) ?? [:]
            var records: [PluginRecord] = []
            for key in plugins.keys.sorted() {
                guard let installs = plugins[key] as? [[String: Any]] else {
                    warnings.append("Invalid plugin entry: \(key)")
                    continue
                }
                // 只收 user 作用域：project 与 local 属于某个检出，设置页没有项目上下文。
                // 没写 scope 的记录按 user 处理。
                let user = installs.filter { $0["scope"] as? String ?? "user" == "user" }
                guard !user.isEmpty else { continue }
                guard let path = user[0]["installPath"] as? String, path.hasPrefix("/") else {
                    warnings.append("Missing plugin installPath: \(key)")
                    continue
                }
                let root = URL(fileURLWithPath: path, isDirectory: true)
                var issue: String?
                if !files.fileExists(atPath: root.path) {
                    issue = "The installation directory is missing: \(root.path)"
                    warnings.append("Plugin installation is missing: \(root.path)")
                }
                let manifestInfo = pluginManifest(at: root, agent: .claudeCode)
                records.append(PluginRecord(
                    identifier: key, name: shortName(key), marketplace: marketplace(key),
                    agent: .claudeCode, version: user[0]["version"] as? String ?? manifestInfo.version,
                    roots: [root],
                    // 缺键不是「已启用」：清单里有安装记录，settings 里没开就是没开。
                    state: enabled[key] as? Bool == true ? .enabled : .disabled,
                    summary: manifestInfo.summary, tagline: manifestInfo.tagline, author: manifestInfo.author, versionNote: nil,
                    contents: issue == nil ? contents(of: [root], agent: .claudeCode) : [],
                    issue: issue))
            }
            return records
        }

        // MARK: Codex

        mutating func scanCodex(cache: URL, installed: [CodexPluginInventory.Entry]) -> [PluginRecord] {
            var records: [PluginRecord] = []
            var seen = Set<String>()
            for entry in installed where seen.insert(entry.pluginId).inserted {
                let key = entry.pluginId
                let base = cache.appendingPathComponent(marketplace(key)).appendingPathComponent(shortName(key))
                let cached = entry.version.map { base.appendingPathComponent($0) }
                let root = cached.flatMap { files.fileExists(atPath: $0.path) ? $0 : nil }
                let roots = root.map { [$0] } ?? []
                let info = root.map { pluginManifest(at: $0, agent: .codex) } ?? ManifestInfo()
                records.append(PluginRecord(identifier: key, name: shortName(key), marketplace: marketplace(key),
                    agent: .codex, version: entry.version, roots: roots,
                    state: entry.enabled ? .enabled : .disabled, summary: info.summary, tagline: info.tagline, author: info.author,
                    versionNote: root == nil && entry.isRemote
                        ? "Remote plugin that Codex has not downloaded to this Mac; its contents cannot be browsed." : nil,
                    contents: contents(of: roots, agent: .codex),
                    // Codex 同步远程插件时可以不落盘（日志里 materialized 为空、failed 也为空），
                    // 那是正常状态；本地来源的安装缺缓存才是真坏了。
                    issue: root == nil && !entry.isRemote ? "Installed plugin contents are not cached locally." : nil))
            }
            for market in directories(at: cache) {
                for plugin in directories(at: market) {
                    let key = "\(plugin.lastPathComponent)@\(market.lastPathComponent)"
                    guard !seen.contains(key) else { continue }
                    let versions = directories(at: plugin)
                    if versions.isEmpty { warnings.append("Plugin cache holds no version directory: \(plugin.path)") }
                    records.append(cachedRecord(key: key, roots: versions, version: nil,
                        note: "Cached files only; not in the Codex installed list.", declaration: nil,
                        issue: versions.isEmpty ? "No cached version directory." : nil))
                }
            }
            return records
        }

        private mutating func cachedRecord(key: String, roots: [URL], version: String?, note: String?,
                                           declaration: Bool?, issue: String?) -> PluginRecord {
            let info = roots.first.map { pluginManifest(at: $0, agent: .codex) } ?? ManifestInfo()
            return PluginRecord(
                identifier: key, name: shortName(key), marketplace: marketplace(key), agent: .codex,
                version: version, roots: roots,
                state: declaration == nil ? .cachedOnly : (declaration == true ? .enabled : .disabled),
                summary: info.summary, tagline: info.tagline, author: info.author, versionNote: note,
                contents: contents(of: roots, agent: .codex), issue: issue)
        }

        // MARK: 插件清单

        private struct ManifestInfo {
            var summary = ""
            var tagline = ""
            var author = ""
            var version: String?
        }

        private mutating func pluginManifest(at root: URL, agent: PluginAgent) -> ManifestInfo {
            let name = agent == .claudeCode ? ".claude-plugin" : ".codex-plugin"
            // 两个 Agent 的清单字段一致，装在不同目录；对方的清单也认，
            // 同一个插件常常两边都能装。
            for directory in [name, agent == .claudeCode ? ".codex-plugin" : ".claude-plugin"] {
                let url = root.appendingPathComponent("\(directory)/plugin.json")
                guard let json = jsonObject(at: url) else { continue }
                var info = ManifestInfo()
                info.summary = json["description"] as? String ?? ""
                info.tagline = (json["interface"] as? [String: Any])?["shortDescription"] as? String ?? ""
                info.version = json["version"] as? String
                if let author = json["author"] as? [String: Any] {
                    info.author = author["name"] as? String ?? ""
                } else if let author = json["author"] as? String {
                    info.author = author
                }
                return info
            }
            return ManifestInfo()
        }

        /// `name@marketplace` 是两个 Agent 通用的标识；树里显示的是前半段。
        private func shortName(_ key: String) -> String {
            guard let separator = key.firstIndex(of: "@"), separator != key.startIndex else { return key }
            return String(key[..<separator])
        }

        private func marketplace(_ key: String) -> String {
            guard let separator = key.lastIndex(of: "@"), separator != key.startIndex else { return "" }
            return String(key[key.index(after: separator)...])
        }

        // MARK: 内容

        /// 扫一个插件的全部内容。多个缓存版本按相对路径合并成一条，各版本路径都留着。
        private mutating func contents(of roots: [URL], agent: PluginAgent) -> [PluginContent] {
            var order: [String] = []
            var items: [String: PluginContent] = [:]
            func add(_ item: PluginContent) {
                if var existing = items[item.id] {
                    if !existing.locations.contains(item.fileURL) { existing.locations.append(item.fileURL) }
                    items[item.id] = existing
                    return
                }
                order.append(item.id)
                items[item.id] = item
            }
            for root in roots {
                for item in skills(in: root) { add(item) }
                for (directory, kind) in [("commands", PluginContentKind.command), ("agents", .agent)] {
                    for item in markdown(in: root.appendingPathComponent(directory), root: root, kind: kind) { add(item) }
                }
                for item in hooks(in: root, agent: agent) { add(item) }
                for item in mcpServers(in: root, agent: agent) { add(item) }
                for item in appConnectors(in: root, agent: agent) { add(item) }
            }
            return order.compactMap { items[$0] }
        }

        private mutating func skills(in root: URL) -> [PluginContent] {
            var result: [PluginContent] = []
            var visited: Set<String> = []
            walkSkills(at: root.appendingPathComponent("skills"), relative: "",
                       remainingDepth: 5, visited: &visited, into: &result)
            return result
        }

        private mutating func walkSkills(at directory: URL, relative: String, remainingDepth: Int,
                                         visited: inout Set<String>, into result: inout [PluginContent]) {
            guard remainingDepth > 0,
                  visited.insert(directory.resolvingSymlinksInPath().path).inserted else { return }
            if files.fileExists(atPath: directory.appendingPathComponent("SKILL.md").path) {
                result.append(skill(at: directory, relative: relative))
                return
            }
            let children = directories(at: directory)
            guard !children.isEmpty else { return }
            for child in children {
                let path = relative.isEmpty ? child.lastPathComponent : "\(relative)/\(child.lastPathComponent)"
                if directories(at: child).isEmpty {
                    // 叶子目录没有 SKILL.md 也要出现：坏掉的安装不能静悄悄消失。
                    result.append(skill(at: child, relative: path))
                } else {
                    walkSkills(at: child, relative: path, remainingDepth: remainingDepth - 1,
                               visited: &visited, into: &result)
                }
            }
        }

        private func skill(at directory: URL, relative: String) -> PluginContent {
            let file = directory.appendingPathComponent("SKILL.md")
            var issues: [String] = []
            var text = ""
            do {
                text = try String(contentsOf: file.resolvingSymlinksInPath(), encoding: .utf8)
            } catch {
                issues.append(files.fileExists(atPath: file.path)
                    ? "Cannot read SKILL.md: \(error.localizedDescription)"
                    : "SKILL.md is missing or its symbolic link is broken.")
            }
            let metadata = SkillMetadata.parse(text)
            if let problem = metadata.issue, !text.isEmpty { issues.append(problem) }
            return PluginContent(id: "skill:\(relative)", name: metadata.name ?? directory.lastPathComponent,
                                 kind: .skill, summary: metadata.summary ?? "", content: text,
                                 isMarkdown: true, fileURL: file, locations: [file],
                                 issue: issues.isEmpty ? nil : issues.joined(separator: "\n"))
        }

        private mutating func markdown(in directory: URL, root: URL, kind: PluginContentKind) -> [PluginContent] {
            var result: [PluginContent] = []
            var visited: Set<String> = []
            walkMarkdown(at: directory, relative: "", kind: kind, remainingDepth: 5,
                         visited: &visited, into: &result)
            return result
        }

        private mutating func walkMarkdown(at directory: URL, relative: String, kind: PluginContentKind,
                                           remainingDepth: Int, visited: inout Set<String>,
                                           into result: inout [PluginContent]) {
            guard remainingDepth > 0, files.fileExists(atPath: directory.path),
                  visited.insert(directory.resolvingSymlinksInPath().path).inserted else { return }
            let children: [URL]
            do {
                children = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsHiddenFiles])
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            } catch {
                warnings.append("Cannot scan \(directory.path): \(error.localizedDescription)")
                return
            }
            for child in children {
                let path = relative.isEmpty ? child.lastPathComponent : "\(relative)/\(child.lastPathComponent)"
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    walkMarkdown(at: child, relative: path, kind: kind, remainingDepth: remainingDepth - 1,
                                 visited: &visited, into: &result)
                    continue
                }
                guard child.pathExtension.lowercased() == "md" else { continue }
                var text = ""
                var issue: String?
                do { text = try String(contentsOf: child, encoding: .utf8) }
                catch { issue = "Cannot read the file: \(error.localizedDescription)" }
                let metadata = SkillMetadata.parse(text)
                let name = String(path.dropLast(3))
                result.append(PluginContent(id: "\(kind.rawValue):\(path)", name: name, kind: kind,
                                            summary: metadata.summary ?? "", content: text, isMarkdown: true,
                                            fileURL: child, locations: [child], issue: issue))
            }
        }

        private mutating func hooks(in root: URL, agent: PluginAgent) -> [PluginContent] {
            // 两家的规则相同：清单里写了 `hooks` 就只认它（一个或一组路径，或内联），
            // 没写才读 `hooks/hooks.json`。同一个目录可能同时装着两家的清单
            // （lightty 自己的插件就是），不看清单就会读到另一家的那份。
            let manifest = root.appendingPathComponent(agent.sessionAgent.spec.pluginManifestPath)
            let declared = jsonObject(at: manifest)?["hooks"]
            var sources: [(hooks: [String: Any], url: URL)] = []
            func add(_ document: [String: Any], at url: URL) {
                sources.append((document["hooks"] as? [String: Any] ?? document, url))
            }
            func load(_ relative: String) {
                let url = URL(fileURLWithPath: relative, relativeTo: root).standardizedFileURL
                if let json = jsonObject(at: url) { add(json, at: url) }
            }
            switch declared {
            case let path as String: load(path)
            case let paths as [String]: paths.forEach(load)
            case let inline as [String: Any]: add(inline, at: manifest)
            case let inlines as [[String: Any]]: inlines.forEach { add($0, at: manifest) }
            default: load("hooks/hooks.json")
            }
            // 多份来源里同名的事件只列第一份，内容 id 按事件名取。
            var seen: Set<String> = []
            return sources.flatMap { source in
                events(in: source.hooks.filter { seen.insert($0.key).inserted }, at: source.url)
            }
        }

        private func events(in hooks: [String: Any], at url: URL) -> [PluginContent] {
            hooks.keys.sorted().map { event in
                PluginContent(id: "hook:\(event)", name: event, kind: .hook,
                              summary: url.lastPathComponent, content: pretty(hooks[event]),
                              isMarkdown: false, fileURL: url, locations: [url], issue: nil)
            }
        }

        /// Codex 的连接器：能力不在仓库里，而是一个要授权的外部应用。清单用
        /// `apps` 指向 `.app.json`，也允许直接内联；`gmail`、`browser` 这类插件的
        /// 全部能力都在这里，不读它们就会显示成「没有内容」。
        private mutating func appConnectors(in root: URL, agent: PluginAgent) -> [PluginContent] {
            let manifest = root.appendingPathComponent(
                agent == .codex ? ".codex-plugin/plugin.json" : ".claude-plugin/plugin.json")
            guard let json = jsonObject(at: manifest) else { return [] }
            var file = manifest
            var apps: [String: Any]?
            if let relative = json["apps"] as? String {
                file = URL(fileURLWithPath: relative, relativeTo: root).standardizedFileURL
                apps = jsonObject(at: file)?["apps"] as? [String: Any]
            } else if let inline = json["apps"] as? [String: Any] {
                apps = inline["apps"] as? [String: Any] ?? inline
            }
            guard let apps, !apps.isEmpty else { return [] }
            return apps.keys.sorted().map { name in
                PluginContent(id: "appConnector:\(name)", name: name, kind: .appConnector,
                              summary: file.lastPathComponent, content: pretty(apps[name]),
                              isMarkdown: false, fileURL: file, locations: [file], issue: nil)
            }
        }

        private mutating func mcpServers(in root: URL, agent: PluginAgent) -> [PluginContent] {
            var url = root.appendingPathComponent(".mcp.json")
            var servers = jsonObject(at: url)?["mcpServers"] as? [String: Any]
            if servers == nil {
                let manifest = root.appendingPathComponent(
                    agent == .codex ? ".codex-plugin/plugin.json" : ".claude-plugin/plugin.json")
                guard let json = jsonObject(at: manifest) else { return [] }
                if let inline = json["mcpServers"] as? [String: Any] {
                    url = manifest
                    servers = inline
                } else if let path = json["mcpServers"] as? String {
                    // 清单可以只写一个相对路径，指向真正的 .mcp.json。
                    url = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL
                    servers = jsonObject(at: url)?["mcpServers"] as? [String: Any]
                }
            }
            guard let servers else { return [] }
            let file = url
            return servers.keys.sorted().map { name in
                PluginContent(id: "mcpServer:\(name)", name: name, kind: .mcpServer,
                              summary: file.lastPathComponent, content: pretty(servers[name]),
                              isMarkdown: false, fileURL: file, locations: [file], issue: nil)
            }
        }

        private func pretty(_ value: Any?) -> String {
            guard let value, JSONSerialization.isValidJSONObject([value]),
                  let data = try? JSONSerialization.data(withJSONObject: value,
                                                         options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
            else { return String(describing: value ?? "") }
            return String(decoding: data, as: UTF8.self)
        }

        // MARK: 文件

        private mutating func directories(at root: URL) -> [URL] {
            guard files.fileExists(atPath: root.path) else { return [] }
            do {
                return try files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                     options: [.skipsHiddenFiles]).filter { url in
                    // 先问链接本身再问目标：断链和自环解析目录会失败，但仍要出现在界面上。
                    if (try? files.destinationOfSymbolicLink(atPath: url.path)) != nil { return true }
                    return (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            } catch {
                warnings.append("Cannot scan \(root.path): \(error.localizedDescription)")
                return []
            }
        }

        private mutating func jsonObject(at url: URL) -> [String: Any]? {
            guard files.fileExists(atPath: url.path) else { return nil }
            do {
                guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                    warnings.append("Invalid metadata: \(url.path)")
                    return nil
                }
                return object
            } catch {
                warnings.append("Cannot read metadata \(url.path): \(error.localizedDescription)")
                return nil
            }
        }
    }
}
