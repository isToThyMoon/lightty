import Foundation

/// Installed state and active version come from Codex, never inferred from cache files.
enum CodexPluginInventory {
    struct Entry: Decodable, Sendable {
        let pluginId: String
        let version: String?
        let installed: Bool
        var enabled: Bool
        var source: Source? = nil

        struct Source: Decodable, Sendable {
            let source: String?
        }

        /// 远程市场的插件由 Codex 按需下载，没在本机缓存是它自己的选择，不是坏掉的安装。
        var isRemote: Bool { source?.source == "remote" }
    }

    private struct Response: Decodable {
        let installed: [Entry]
    }

    static func decode(_ data: Data) throws -> [Entry] {
        let entries = try JSONDecoder().decode(Response.self, from: data).installed
        guard entries.allSatisfy({ entry in
            let parts = entry.pluginId.split(separator: "@", omittingEmptySubsequences: false)
            return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && !$0.contains("/") && $0 != ".." }
                && (entry.version.map { !$0.isEmpty && !$0.contains("/") && $0 != ".." } ?? true)
        }) else { throw CocoaError(.fileReadCorruptFile) }
        return entries
    }

    static func load(home: URL, environment: [String: String]) throws -> [Entry] {
        let paths = (environment["PATH"].map(LoginShellPath.parse) ?? []) + HookInstaller.searchPath()
        guard let executable = paths.map({ URL(fileURLWithPath: $0).appendingPathComponent("codex").path })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Codex executable not found."])
        }
        let command = AgentHelperProcess.agentCLI(.codex, executable: executable, root: home.path,
            arguments: ["plugin", "list", "--json"], directory: home.deletingLastPathComponent(),
            inherited: environment, searchPath: paths)
        do { return try decode(command.output()) }
        catch {
            throw NSError(domain: "CodexPluginInventory", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "\(executable) (CODEX_HOME=\(home.path)): \(error.localizedDescription)"])
        }
    }
}
