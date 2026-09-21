import Foundation

/// Installed state and active version come from Codex, never inferred from cache files.
///
/// 问常驻 app-server 的 `plugin/installed`（见 `CodexAppServer`）：只回装上的插件，
/// 含从远端全局目录装的；远端那部分先用进程内缓存，拉不到就只回本地的，不报错
/// （`codex-rs/app-server/src/request_processors/plugins.rs`）。
/// 不用 `plugin/list`：它把远端全局目录几千个可装插件整个带上，本机实测 10MB。
/// 也不跑 `codex plugin list`：远端目录缓存过了 3 小时必须联网重拉，网络卡住时整份清单拿不到。
enum CodexPluginInventory {
    struct Entry: Sendable {
        let pluginId: String
        let version: String?
        var enabled: Bool
        var source: Source? = nil

        struct Source: Sendable {
            /// source 的 `type`：`local` 或 `remote`。
            let source: String?
        }

        /// 远程市场的插件由 Codex 按需下载，没在本机缓存是它自己的选择，不是坏掉的安装。
        var isRemote: Bool { source?.source == "remote" }
    }

    /// 一次问答的结果。`loadErrors` 是 Codex 没加载成功的市场：那里装的插件不会出现在
    /// `entries` 里，得明说，不然它们只是悄悄消失。
    struct Inventory: Sendable {
        var entries: [Entry]
        var loadErrors: [String] = []
    }

    /// 结果按市场分组。只取 `installed` 为真的，防着回应里混进可装的。
    /// 版本先取 `localVersion`（本地市场的缓存目录按它命名，`version` 是空的），
    /// 远端装的没有 `localVersion`，取 `version`。
    static func decode(_ result: [String: Any]) throws -> Inventory {
        guard let marketplaces = result["marketplaces"] as? [[String: Any]] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        func safe<S: StringProtocol>(_ part: S) -> Bool { !part.isEmpty && !part.contains("/") && part != ".." }
        var entries: [Entry] = []
        for marketplace in marketplaces {
            for plugin in marketplace["plugins"] as? [[String: Any]] ?? [] where plugin["installed"] as? Bool == true {
                let version = plugin["localVersion"] as? String ?? plugin["version"] as? String
                guard let id = plugin["id"] as? String,
                      case let parts = id.split(separator: "@", omittingEmptySubsequences: false),
                      parts.count == 2, parts.allSatisfy(safe), version.map(safe) ?? true
                else { throw CocoaError(.fileReadCorruptFile) }
                let source = (plugin["source"] as? [String: Any])?["type"] as? String
                entries.append(Entry(pluginId: id, version: version,
                                     enabled: plugin["enabled"] as? Bool ?? false, source: .init(source: source)))
            }
        }
        let loadErrors = (result["marketplaceLoadErrors"] as? [[String: Any]] ?? []).map { failure in
            "Codex could not load the marketplace at \(failure["marketplacePath"] as? String ?? "?"): "
                + "\(failure["message"] as? String ?? "unknown error")"
        }
        return Inventory(entries: entries, loadErrors: loadErrors)
    }

    static func load(home: URL, environment: [String: String]) throws -> Inventory {
        let paths = (environment["PATH"].map(LoginShellPath.parse) ?? []) + HookInstaller.searchPath()
        guard let executable = paths.map({ URL(fileURLWithPath: $0).appendingPathComponent("codex").path })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Codex executable not found."])
        }
        let command = AgentHelperProcess.agentCLI(.codex, executable: executable, root: home.path,
            arguments: ["app-server", "--listen", "stdio://"], directory: home,
            inherited: environment, searchPath: paths)
        do {
            // 冷启动的第一次要联网拉远端已装清单，Codex 自己 30 秒放弃并退回本地清单；
            // 这里要等得比它久，才拿得到那份退回结果，而不是自己先超时把进程换掉。
            return try decode(CodexAppServer.shared(command, root: home)
                .request("plugin/installed", params: [:], timeout: 45))
        } catch {
            throw NSError(domain: "CodexPluginInventory", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "\(executable) (CODEX_HOME=\(home.path)): \(error.localizedDescription)"])
        }
    }
}
