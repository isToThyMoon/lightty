import CryptoKit
import Foundation
import LighttyCore

/// lightty 自带的插件 marketplace —— 我们的 hook 定义住在**我们自己的文件里**。
///
/// 两家 agent 都支持「插件自带 hooks」，且元数据位置不冲突（实测见
/// docs/specs/pane-status.md §2.1.1），所以一棵目录树同时服务两家：
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
/// ```
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

    /// 纯函数：不碰磁盘就能算出该 agent 当前内容对应的版本串。
    /// `report(for:)` 靠它判断"已装的是不是当前版本"，不必为了看一眼而生成整棵树。
    ///
    /// **按 agent 各算各的**：两家读的是两份不同的 hooks 文件，混着哈希会让
    /// 「改了 Claude Code 的事件表」把 Codex 的版本也顶掉，用户那一行凭空冒出
    /// 一句"有更新"，点下去装的还是同样的东西。
    static func version(for agent: HookAgent, command: String) -> String {
        // 只喂这一家自己的 hooks 内容：清单里除了版本串本身没有别的会变的东西，
        // 把版本喂给算版本的哈希会自我循环。
        version(hooks: hooksDocument(for: agent, command: command))
    }

    /// 版本完全由**一份** hooks 文档决定，别的什么都不看——
    /// 「改一家的事件表不会动另一家的版本」这条性质就落在这个签名上。
    static func version(hooks document: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: document)
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
             claudePluginManifest(version: version(for: .claudeCode, command: command))),
            ("plugins/\(pluginName)/.codex-plugin/plugin.json",
             codexPluginManifest(version: version(for: .codex, command: command))),
            // 两家读的是**不同的文件**，所以各给各的事件表：把 Codex 的
            // `PermissionRequest` 塞给 Claude Code（反之亦然）只是噪音。
            ("plugins/\(pluginName)/hooks/hooks.json",
             hooksDocument(for: .claudeCode, command: command)),
            ("plugins/\(pluginName)/hooks.json",
             hooksDocument(for: .codex, command: command)),
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

    private static func claudeMarketplaceManifest() -> Data {
        serialize([
            "name": marketplaceName,
            "owner": ["name": "lightty"],
            "description": "lightty agent status hooks",
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

    private static func claudePluginManifest(version: String) -> Data {
        serialize([
            "name": pluginName,
            "version": version,
            "description": "Reports agent lifecycle to lightty.",
            "author": ["name": "lightty"],
        ])
    }

    private static func codexPluginManifest(version: String) -> Data {
        serialize([
            "name": pluginName,
            "version": version,
            "description": "Reports agent lifecycle to lightty.",
            // Codex 不看 hooks/ 目录约定，要在清单里明说去哪儿读
            "hooks": "./hooks.json",
            "interface": ["displayName": "lightty", "shortDescription": "Pane status"],
        ])
    }

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
