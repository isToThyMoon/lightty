import CryptoKit
import Foundation
import LighttyCore

/// lightty 自带的插件 marketplace —— 我们的 hook 定义与 handoff 技能住在
/// **我们自己的文件里**。
///
/// 两家 agent 都支持「插件自带 hooks」与「插件自带 skills」，且元数据位置不冲突
/// （实测见 docs/specs/pane-status.md §2.1.1），所以一棵目录树同时服务两家：
///
/// ```
/// ~/.lightty/marketplace/
///   .claude-plugin/marketplace.json        ← Claude Code 读这份 marketplace 清单
///   .agents/plugins/marketplace.json       ← Codex 读这份
///   plugins/lightty/
///     .claude-plugin/plugin.json           ← Claude Code 读这份插件清单
///     .codex-plugin/plugin.json            ← Codex 读这份（清单里声明 "hooks": "./hooks.json"）
///     hooks/hooks.json                     ← Claude Code 从这里读 hook 定义
///     hooks.json                           ← Codex 从这里读（由它的清单指定）
///     skills/handoff/SKILL.md              ← **两家共用一份**，各自清单里都声明 "skills": "./skills/"
/// ```
///
/// 技能只有一份而 hooks 有两份，是因为两家对 hooks 的读法不同（目录约定 vs
/// 清单指路，且事件表也不一样），而 SKILL.md 的格式与目录布局两家完全一致。
/// 调用写法两家不同（`/插件名:技能名` vs `$插件名:技能名`），但那是**敲进终端**
/// 时的事，与这棵树无关，见 `HandoffProtocol.skillInvocation`。
///
/// **整棵树在运行时生成，不作为 bundle 资源随包发布**：`hooks.json` 里写的是
/// `~/.lightty/bin/lightty-hook` 的绝对路径，每次启动重新生成，"app 被挪过"
/// 这类陈旧路径就不可能出现。生成是幂等的，内容没变的文件一个字节都不重写
/// ——两家 CLI 都按版本号判断要不要重新拷贝，无谓地改动 mtime 只会制造噪音。
enum HookMarketplace {
    /// marketplace 名 / 插件名。两家 CLI 都用 `plugin@marketplace` 寻址，
    /// Codex 更是**强制**要求这个形式。
    static let marketplaceName = "lightty"
    static let pluginName = "lightty"
    static var pluginID: String { "\(pluginName)@\(marketplaceName)" }

    /// 语义版本的前三段固定不动；真正区分"装的是不是当前内容"的是后面的 `+<hash>`。
    ///
    /// 两家 CLI 都在安装时把插件**拷贝**进自己的 cache（Claude Code
    /// `plugins/cache/<mp>/<plugin>/<version>`，Codex 同构），所以改这棵树不会
    /// 自动改变 agent 实际执行的东西——只有版本串变了，`claude plugin update`
    /// 才会重新拷贝。把内容哈希挂进版本串，等于让"内容变了"和"需要重装"同义。
    static let baseVersion = "0.1.0"

    /// `~/.lightty/marketplace`——固定位置。两家 CLI 都把这个绝对路径记进用户配置，
    /// 路径一变就等于换了个 marketplace，用户配置里会留下孤儿条目。
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lightty/marketplace", isDirectory: true)
    }

    /// 插件目录（marketplace 清单里那条 `./plugins/lightty` 指向的地方）
    static func pluginDirectory(in root: URL = Self.root) -> URL {
        root.appendingPathComponent("plugins/\(pluginName)", isDirectory: true)
    }

    // MARK: - 生成结果

    struct Generation: Equatable {
        let root: URL
        /// 生成这棵树用的 shim 路径。版本由它推导，存着就不必再传一遍。
        let command: String
        /// 相对 root 的被重写文件列表（内容真的变了才在这里），顺序稳定
        let rewritten: [String]
        /// 有任何文件被重写——调用方据此决定要不要让 CLI 重新装一遍
        var changed: Bool { !rewritten.isEmpty }

        /// 本轮该 agent 应当被安装的版本，形如 `0.1.0+3f2a1c9d`
        func version(for agent: HookAgent) -> String {
            HookMarketplace.version(for: agent, command: command)
        }
    }

    // MARK: - 生成

    /// 生成（或刷新）整棵树。每次启动都可以调，很便宜。
    ///
    /// - Parameter command: 写进 hooks 的可执行文件绝对路径（`~/.lightty/bin/lightty-hook`）
    @discardableResult
    static func generate(command: String, root: URL = Self.root) throws -> Generation {
        var rewritten: [String] = []
        for file in files(command: command) {
            let url = root.appendingPathComponent(file.path)
            // 内容一致就跳过：mtime 不动，两家 CLI 的 marketplace 快照也就不会
            // 无端刷新。这是"每次启动都生成"能被接受的前提。
            if (try? Data(contentsOf: url)) == file.data { continue }
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                // 与 PaneRuntimeDirectory 同一套原子写约定：同目录 tmp + rename(2)，
                // 半截文件会让 CLI 读到语法错的清单
                try PaneRuntimeDirectory.atomicWrite(file.data, to: url)
            } catch {
                throw HookInstallError.writeFailed(path: url.path, reason: describe(error))
            }
            rewritten.append(file.path)
        }
        return Generation(root: root, command: command, rewritten: rewritten)
    }

    /// 插件里那份 `SKILL.md` 的字节。两家共用一份，正文见 `HandoffProtocol`。
    /// 与 `hooksDocument` 同一套命名：这一层说的是"写进树里的那份文档"。
    static let skillDocument = Data(HandoffProtocol.skillDocument.utf8)

    /// 纯函数：不碰磁盘就能算出该 agent 当前内容对应的版本串。
    /// `report(for:)` 靠它判断"已装的是不是当前版本"，不必为了看一眼而生成整棵树。
    ///
    /// **按 agent 各算各的**：两家读的是两份不同的 hooks 文件，混着哈希会让
    /// 「改了 Claude Code 的事件表」把 Codex 的版本也顶掉，用户那一行凭空冒出
    /// 一句"有更新"，点下去装的还是同样的东西。
    static func version(for agent: HookAgent, command: String) -> String {
        version(hooks: hooksDocument(for: agent, command: command),
                manifests: manifestBytes(for: agent))
    }

    /// 这一家的两份清单里**除版本串以外**的全部内容，喂哈希用。
    ///
    /// 为什么要喂：清单不是不变的。`skills`、`hooks` 指向哪儿、description、Codex 那份
    /// 的 `interface` 与 `policy`——改任何一个都改变了"装进去的是什么"，而两家 CLI
    /// 只按版本串决定要不要重新拷贝。清单不进哈希的话，只改清单就是版本纹丝不动、
    /// 用户 cache 里还是旧的，**症状同样是静默的**——和技能不进哈希是同一类 bug。
    ///
    /// 为什么去掉 `version`：版本串本身是这个哈希的结果，喂进去就自我循环了。
    ///
    /// 为什么 marketplace 清单也算数：安装那两条命令每次都先跑
    /// `plugin marketplace add <root>`（见 `HookAgent.installCommands`），所以版本一跳、
    /// 用户点了更新，marketplace 快照跟着刷新。它不是白喂的。
    ///
    /// 按家各喂各的，跨家独立性照旧：改 Codex 清单不会顶掉 Claude Code 的版本。
    static func manifestBytes(for agent: HookAgent) -> Data {
        var bytes = marketplaceManifest(for: agent)
        bytes.append(serialize(pluginManifestBody(for: agent)))
        return bytes
    }

    /// 版本由**该家的 hooks 文档 + 那份 SKILL.md + 该家两份清单**共同决定。
    /// 这三样就是"装进 CLI 缓存里的全部东西"，少喂一样，改它就不会触发重装。
    ///
    /// 为什么必须都进：两家 CLI 在安装时把插件**拷贝**进自己的 cache，只有版本串
    /// 变了才会重新拷贝。任何一样没进哈希，改它都是"版本纹丝不动、用户 cache 里
    /// 还是旧的"，而且**没有任何症状**——用户以为改生效了。
    ///
    /// 三条性质由这个签名撑着，缺一不可：
    ///
    /// - **改一家的事件表不动另一家**：hooks 按家分开喂
    /// - **改一家的清单不动另一家**：清单同样按家分开喂
    /// - **改技能两家一起动**：技能是共用的一份，两个版本同时变——这是对的，
    ///   两家都得重新拷贝才能拿到新技能
    ///
    /// **这次改动会让所有既有用户的版本串跳一次**，两家各提示一次 Update。这是
    /// 必需的代价：技能是后加的，不重装就进不了 CLI 的 cache，用户点"更新交接
    /// 文档"只会静默失败。看到"升级后两家都弹更新"**不是回归**，不要靠把技能或
    /// 清单从哈希里拿掉来"修"它——那正好退回上面那个没有症状的 bug。
    ///
    /// 三段之间插分隔符：三份字节直接首尾相接的话，"某个字节从 hooks 挪到清单"
    /// 理论上能撞出同一个哈希。实际撞不上（一边是 JSON 一边是 Markdown），
    /// 但分隔符不要钱。
    ///
    /// - Parameters:
    ///   - skill: 只为测试留的开口——生产路径永远用默认值那一份。
    ///   - manifests: **不给默认值**。给了的话，别处就能算出一个"看起来像生产版本、
    ///     其实少喂了清单"的串，而这正是这次要堵的洞。
    static func version(hooks document: Data, skill: Data = skillDocument,
                        manifests: Data) -> String {
        var hasher = SHA256()
        for segment in [document, skill, manifests] {
            hasher.update(data: segment)
            hasher.update(data: Data([0x00]))
        }
        let digest = hasher.finalize().prefix(4).map { String(format: "%02x", $0) }.joined()
        // `+build` 是 semver 的 build metadata 段，`claude plugin validate` 零警告通过，
        // 且实测 `claude plugin update` 会把它当成"版本变了"而重新拷贝。
        return "\(baseVersion)+\(digest)"
    }

    // MARK: - 文件内容

    /// 整棵树的全部文件（相对 root 的路径 + 字节）。顺序稳定，测试直接对着断言。
    static func files(command: String) -> [(path: String, data: Data)] {
        [
            (".claude-plugin/marketplace.json", claudeMarketplaceManifest()),
            (".agents/plugins/marketplace.json", codexMarketplaceManifest()),
            // 两份清单同处一个插件目录，但各自带各自的版本号——它们本来就是
            // 两家分开读的文件，谁也看不见对方那份
            ("plugins/\(pluginName)/.claude-plugin/plugin.json",
             pluginManifest(for: .claudeCode, version: version(for: .claudeCode, command: command))),
            ("plugins/\(pluginName)/.codex-plugin/plugin.json",
             pluginManifest(for: .codex, version: version(for: .codex, command: command))),
            // 两家读的是**不同的文件**，所以各给各的事件表：把 Codex 的
            // `PermissionRequest` 塞给 Claude Code（反之亦然）只是噪音。
            ("plugins/\(pluginName)/hooks/hooks.json",
             hooksDocument(for: .claudeCode, command: command)),
            ("plugins/\(pluginName)/hooks.json",
             hooksDocument(for: .codex, command: command)),
            // 技能反过来只有一份：SKILL.md 的格式与 skills/<名>/SKILL.md 的布局
            // 两家一致，两份清单指的是同一个目录。
            ("plugins/\(pluginName)/skills/\(HandoffProtocol.skillName)/SKILL.md",
             skillDocument),
        ]
    }

    /// hook 定义。事件 key **必须 PascalCase**（实测 snake_case / camelCase 不触发），
    /// 不带 `matcher`——缺省即匹配全部，我们对所有工具/来源都要状态。
    /// 两家都不支持通配 key，每个事件必须独立成键。
    static func hooksDocument(for agent: HookAgent, command: String) -> Data {
        hooksDocument(events: agent.events, command: command)
    }

    /// 事件表参数化的版本：测试用它构造"事件表变了"的假设情形，
    /// 不必真去改 `HookAgent.events`。
    static func hooksDocument(events: [String], command: String) -> Data {
        var document: [String: Any] = [:]
        for event in events {
            document[event] = [["hooks": [["type": "command", "command": command]]]]
        }
        return serialize(["hooks": document])
    }

    /// 这一家读哪份 marketplace 清单。两家读的是两个不同路径上的两份文件，
    /// 内容也不同（Codex 那份多 `policy` 与 `category`）。
    static func marketplaceManifest(for agent: HookAgent) -> Data {
        switch agent {
        case .claudeCode: return claudeMarketplaceManifest()
        case .codex: return codexMarketplaceManifest()
        }
    }

    /// 这一家的插件清单**去掉 `version` 之后**的内容。写文件时补上版本，算哈希时不补。
    static func pluginManifestBody(for agent: HookAgent) -> [String: Any] {
        switch agent {
        case .claudeCode:
            return [
                "name": pluginName,
                "description": pluginDescription,
                "author": ["name": "lightty"],
                // Claude Code 不写这个键也默认去 skills/ 找；显式写出来是为了跟
                // Codex 那份对齐，也免得默认约定哪天变了我们才发现
                "skills": "./skills/",
            ]
        case .codex:
            return [
                "name": pluginName,
                "description": pluginDescription,
                // Codex 不看 hooks/ 目录约定，要在清单里明说去哪儿读
                "hooks": "./hooks.json",
                "skills": "./skills/",
                "interface": ["displayName": "lightty", "shortDescription": "Pane status"],
            ]
        }
    }

    /// 写进树里的那份插件清单：内容 + 版本。键序由 `serialize` 的 `sortedKeys` 决定，
    /// 所以"先建字典再塞版本"和原来直接写出来是同样的字节。
    private static func pluginManifest(for agent: HookAgent, version: String) -> Data {
        var body = pluginManifestBody(for: agent)
        body["version"] = version
        return serialize(body)
    }

    private static func claudeMarketplaceManifest() -> Data {
        serialize([
            "name": marketplaceName,
            "owner": ["name": "lightty"],
            "description": "lightty agent status hooks and the handoff skill",
            "plugins": [["name": pluginName, "source": "./plugins/\(pluginName)"]],
        ])
    }

    private static func codexMarketplaceManifest() -> Data {
        serialize([
            "name": marketplaceName,
            "interface": ["displayName": "lightty"],
            "plugins": [[
                "name": pluginName,
                "source": ["source": "local", "path": "./plugins/\(pluginName)"],
                // AVAILABLE：允许用户安装，但不自动装——装不装由用户点那颗按钮决定
                "policy": ["installation": "AVAILABLE"],
                "category": "Developer Tools",
            ]],
        ])
    }

    /// 两份清单共用：插件现在装的是两样东西，只说 hooks 会让用户在
    /// `claude plugin list` 里看不出技能是哪儿来的。
    private static let pluginDescription =
        "Reports agent lifecycle to lightty, and provides the handoff skill."

    /// `sortedKeys` 不是审美：字节要能逐次复现，否则每次启动都"内容变了"。
    /// `withoutEscapingSlashes` 让用户打开文件看到的是真实路径而不是 `\/Users\/…`。
    private static func serialize(_ object: [String: Any]) -> Data {
        let options: JSONSerialization.WritingOptions = [
            .prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
        ]
        // 输入全是字面量，序列化不可能失败；真失败了也让它落成空对象而不是崩溃
        return (try? JSONSerialization.data(withJSONObject: object, options: options))
            ?? Data("{}".utf8)
    }

    /// `PaneRuntimeError` 是裸 enum，`localizedDescription` 只会给一句
    /// "The operation couldn't be completed"，errno 才是用户能拿去查的东西。
    private static func describe(_ error: Error) -> String {
        if case PaneRuntimeError.atomicRenameFailed(_, let code) = error {
            return String(cString: strerror(code))
        }
        return error.localizedDescription
    }
}
