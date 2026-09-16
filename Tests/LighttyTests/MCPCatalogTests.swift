import Foundation
import Testing
@testable import lightty

struct MCPCatalogTests {
    @Test func aConfiguredServerIsOnUnlessTheConfigSaysOtherwise() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(".codex/config.toml", """
        model = "gpt-5"

        [mcp_servers.node_repl]
        command = "/opt/node_repl"
        args = []

        [mcp_servers.node_repl.env]
        NODE_PATH = "/opt/node"

        [mcp_servers.computer-use]
        command = "./Computer Use.app/Contents/MacOS/client"
        args = ["mcp"]
        enabled = false
        """)
        let servers = fixture.scan().servers
        #expect(servers.map(\.name) == ["computer-use", "node_repl"])
        let node = try #require(servers.first { $0.name == "node_repl" })
        // Nothing says enabled, and Codex runs it anyway — the default is on, unlike plugins.
        #expect(node.enabled)
        #expect(node.transport == "stdio")
        #expect(node.summary == "/opt/node_repl")
        #expect(node.canToggle)
        // The env sub-table belongs to the same server and travels with it.
        #expect(node.declaration.contains("[mcp_servers.node_repl.env]"))
        #expect(node.declaration.contains("NODE_PATH"))
        #expect(!node.declaration.contains("computer-use"))
        #expect(try #require(servers.first { $0.name == "computer-use" }).enabled == false)
    }

    @Test func claudeUserLevelServersAreListedAndCannotBeToggledHere() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.json(".claude.json", ["mcpServers": [
            "notion": ["type": "http", "url": "https://mcp.notion.com/mcp"],
            "local": ["command": "/usr/bin/thing", "args": ["serve"]],
        ]])
        let servers = fixture.scan().servers
        #expect(servers.map(\.name) == ["local", "notion"])
        let notion = try #require(servers.first { $0.name == "notion" })
        #expect(notion.transport == "http")
        #expect(notion.summary == "https://mcp.notion.com/mcp")
        #expect(notion.enabled)
        #expect(!notion.canToggle)
        #expect(notion.toggleNote != nil)
        #expect(try #require(servers.first { $0.name == "local" }).summary == "/usr/bin/thing serve")
    }

    @Test func togglingRewritesOnlyTheOneValueAndKeepsEverythingElse() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = """
        # 我自己写的注释
        model = "gpt-5"

        [mcp_servers.node_repl]
        command = "/opt/node_repl"  # 路径别动
        startup_timeout_sec = 120

        [projects."/tmp/a"]
        trust_level = "trusted"
        """
        try fixture.write(".codex/config.toml", original)
        let catalog = fixture.catalog()
        let server = try #require(catalog.scan().servers.first)
        try catalog.setEnabled(false, for: server)
        let text = try String(contentsOf: fixture.url(".codex/config.toml"), encoding: .utf8)
        #expect(text.contains("enabled = false"))
        #expect(text.contains("# 我自己写的注释"))
        #expect(text.contains("command = \"/opt/node_repl\"  # 路径别动"))
        #expect(text.contains("[projects.\"/tmp/a\"]"))
        #expect(catalog.scan().servers.first?.enabled == false)
        // The first write leaves the original behind, and a second one does not overwrite it.
        let backup = fixture.url(".codex/config.toml.lightty-backup")
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)
        try catalog.setEnabled(true, for: try #require(catalog.scan().servers.first))
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)
        #expect(catalog.scan().servers.first?.enabled == true)
    }

    @Test func aServerWithNoTableOfItsOwnIsRefusedRatherThanInvented() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(".codex/config.toml", "[mcp_servers.node_repl]\ncommand = \"/opt/node\"\n")
        let catalog = fixture.catalog()
        let real = try #require(catalog.scan().servers.first)
        let ghost = MCPServerRecord(name: "absent", agent: .codex, enabled: true, transport: "stdio",
                                    summary: "", declaration: "", sourceURL: real.sourceURL,
                                    canToggle: true, toggleNote: nil)
        #expect(throws: PluginWriteError.self) { try catalog.setEnabled(false, for: ghost) }
        let text = try String(contentsOf: fixture.url(".codex/config.toml"), encoding: .utf8)
        #expect(!text.contains("absent"))
    }

    @Test func anEmptyHomeHasNoServersAndNoWarnings() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let snapshot = fixture.scan()
        #expect(snapshot.servers.isEmpty)
        #expect(snapshot.warnings.isEmpty)
    }

    private struct Fixture {
        let home: URL
        init() throws {
            home = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-catalog-\(UUID())")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }
        func url(_ path: String) -> URL { home.appendingPathComponent(path) }
        func write(_ path: String, _ text: String) throws {
            try FileManager.default.createDirectory(at: url(path).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: url(path), atomically: true, encoding: .utf8)
        }
        func json(_ path: String, _ value: [String: Any]) throws {
            try write(path, String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))
        }
        func catalog() -> MCPCatalog { MCPCatalog(home: home, environment: [:]) }
        func scan() -> MCPCatalogSnapshot { catalog().scan() }
        func remove() { try? FileManager.default.removeItem(at: home) }
    }
}
