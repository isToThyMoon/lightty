import Foundation

/// 一台独立配置的 MCP server——用户自己写进 Agent 配置的那些。
/// 插件自带的 server 不在这里，它们归 Plugins 页：同一台服务器在两处各列一遍，
/// 正是把插件技能移出 Skills 页时要避免的那件事。
struct MCPServerRecord: Identifiable, Equatable, Sendable {
    /// 两个 Agent 可以各配一台同名的 server。
    var id: String { "\(agent.rawValue):\(name)" }
    let name: String
    let agent: PluginAgent
    let enabled: Bool
    /// 本地起进程（stdio），还是连一个地址（http / sse）。
    let transport: String
    /// 列表第二行：stdio 显示命令，远端显示地址。
    let summary: String
    /// 配置原文片段，原样展示——展示与真正生效的是同一段字。
    let declaration: String
    let sourceURL: URL
    /// 只有 Codex 有 `enabled` 这个开关；Claude 侧配置了就是开着的。
    let canToggle: Bool
    let toggleNote: String?
}

struct MCPCatalogSnapshot: Sendable {
    var servers: [MCPServerRecord] = []
    var warnings: [String] = []
}

/// 只读配置文件，启停只改那一个布尔值。
struct MCPCatalog {
    private let home: URL
    private let environment: [String: String]

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.home = home
        self.environment = environment
    }

    private var codexHome: URL {
        if let path = environment["CODEX_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return home.appendingPathComponent(".codex")
    }

    var codexConfigURL: URL { codexHome.appendingPathComponent("config.toml") }
    /// Claude Code 的用户级 MCP 写在这里；项目级的写在各自检出的 `.mcp.json` 里，
    /// 设置页没有项目上下文，不去猜当前是哪个项目。
    var claudeConfigURL: URL { home.appendingPathComponent(".claude.json") }

    func scan() -> MCPCatalogSnapshot {
        var snapshot = MCPCatalogSnapshot()
        snapshot.servers += scanClaude(&snapshot.warnings)
        snapshot.servers += scanCodex(&snapshot.warnings)
        snapshot.servers.sort { lhs, rhs in
            if lhs.agent != rhs.agent { return lhs.agent == .claudeCode }
            let byName = lhs.name.localizedStandardCompare(rhs.name)
            return byName == .orderedSame ? lhs.id < rhs.id : byName == .orderedAscending
        }
        return snapshot
    }

    private func scanClaude(_ warnings: inout [String]) -> [MCPServerRecord] {
        guard FileManager.default.fileExists(atPath: claudeConfigURL.path) else { return [] }
        let object: [String: Any]?
        do {
            object = try JSONSerialization.jsonObject(with: Data(contentsOf: claudeConfigURL)) as? [String: Any]
        } catch {
            warnings.append("Cannot read \(claudeConfigURL.path): \(error.localizedDescription)")
            return []
        }
        guard let servers = object?["mcpServers"] as? [String: Any] else { return [] }
        return servers.keys.sorted().map { name in
            let entry = servers[name] as? [String: Any] ?? [:]
            return MCPServerRecord(
                name: name, agent: .claudeCode, enabled: true,
                transport: transport(of: entry),
                summary: summary(of: entry),
                declaration: pretty([name: servers[name] ?? [:]]),
                sourceURL: claudeConfigURL, canToggle: false,
                toggleNote: "Claude Code has no enabled switch for a user-level server: it is on while it is configured.")
        }
    }

    private func scanCodex(_ warnings: inout [String]) -> [MCPServerRecord] {
        guard FileManager.default.fileExists(atPath: codexConfigURL.path) else { return [] }
        let text: String
        do {
            text = try String(contentsOf: codexConfigURL, encoding: .utf8)
        } catch {
            warnings.append("Cannot read \(codexConfigURL.path): \(error.localizedDescription)")
            return []
        }
        return TOMLTextEdit.mcpServers(in: text).map { server in
            let declaration = server.lines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fields = values(in: server.lines)
            return MCPServerRecord(
                name: server.name, agent: .codex,
                enabled: TOMLTextEdit.mcpEnabled(name: server.name, in: text),
                transport: fields["url"] != nil ? "http" : "stdio",
                summary: fields["url"] ?? fields["command"] ?? "",
                declaration: declaration, sourceURL: codexConfigURL,
                canToggle: true, toggleNote: nil)
        }
    }

    /// 启停只改 `enabled` 这一个值：先备份、再原子替换，其余内容原样保留。
    func setEnabled(_ value: Bool, for server: MCPServerRecord) throws {
        guard server.canToggle else {
            throw PluginWriteError.unsupportedShape(path: server.sourceURL.lastPathComponent,
                                                    detail: "\(server.name) has no enabled switch")
        }
        try ConfigFile.rewrite(codexConfigURL, empty: "") { text in
            try TOMLTextEdit.setMCPEnabled(value, name: server.name, in: text)
        } verify: { text in
            TOMLTextEdit.mcpEnabled(name: server.name, in: text) == value
        }
    }

    /// 主表里的标量键，够列表第二行用；不做通用 TOML 解析。
    private func values(in lines: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var first = true
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                if !first { break }
                first = false
                continue
            }
            guard let equals = trimmed.firstIndex(of: "="), !trimmed.hasPrefix("#") else { continue }
            let key = String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            for quote in ["\"", "'"] where value.hasPrefix(quote) && value.hasSuffix(quote) && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result
    }

    private func transport(of entry: [String: Any]) -> String {
        if let type = entry["type"] as? String, !type.isEmpty { return type }
        return entry["url"] is String ? "http" : "stdio"
    }

    private func summary(of entry: [String: Any]) -> String {
        if let url = entry["url"] as? String { return url }
        guard let command = entry["command"] as? String else { return "" }
        let arguments = (entry["args"] as? [Any])?.compactMap { $0 as? String } ?? []
        return ([command] + arguments).joined(separator: " ")
    }

    private func pretty(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value,
                                                     options: [.prettyPrinted, .sortedKeys]) else {
            return String(describing: value)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
