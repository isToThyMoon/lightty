import AppKit
import Testing
@testable import lightty

@MainActor
struct MCPSettingsViewTests {
    @Test func agentCategoriesNarrowTheListAndTheDetailFollows() throws {
        let (view, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(view.servers.map(\.name) == ["notion", "computer-use", "node_repl"])
        #expect(view.selectedServer?.name == "notion")
        view.selectAgent(.codex)
        #expect(view.servers.map(\.name) == ["computer-use", "node_repl"])
        #expect(view.selectedServer?.name == "computer-use")
        let text = try #require(descendants(view).compactMap { $0 as? NSTextView }
            .first { $0.identifier?.rawValue == "mcp-document" })
        // The declaration is shown as written, sub-table and all.
        #expect(text.string.contains("[mcp_servers.computer-use]"))
        view.selectList(id: "codex:node_repl")
        #expect(text.string.contains("NODE_PATH"))
        view.search("notion")
        #expect(view.servers.isEmpty, "搜索只在当前分类里找")
        view.selectAgent(nil)
        #expect(view.servers.map(\.name) == ["notion"])
    }

    @Test func aDisabledServerReadsAsDisabledAndTheToggleWritesTheConfig() throws {
        let (view, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        view.selectAgent(.codex)
        view.selectList(id: "codex:computer-use")
        let disabled = try #require(view.selectedServer)
        #expect(!disabled.enabled)
        let toggle = try #require(descendants(view).compactMap { $0 as? ShellToggle }.first)
        #expect(!toggle.isOn)
        toggle.isOn = true
        toggle.onChange?(true)
        let config = try String(contentsOf: root.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        #expect(config.contains("enabled = true"))
        #expect(config.contains("[projects.\"/tmp/a\"]"), "配置里其余内容原样保留")
        #expect(view.selectedServer?.enabled == true)
    }

    @Test func aClaudeServerSaysWhyItHasNoSwitch() throws {
        let (view, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        view.selectAgent(.claudeCode)
        let server = try #require(view.selectedServer)
        #expect(server.name == "notion")
        #expect(!server.canToggle)
        let labels = descendants(view).compactMap { $0 as? NSTextField }.map(\.stringValue)
        #expect(labels.contains { $0.contains("no enabled switch") })
        #expect(labels.contains("Claude Code · http"))
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func fixture() throws -> (MCPSettingsView, URL) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-view-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write(".codex/config.toml", """
        [mcp_servers.node_repl]
        command = "/opt/node_repl"

        [mcp_servers.node_repl.env]
        NODE_PATH = "/opt/node"

        [mcp_servers.computer-use]
        command = "/opt/client"
        enabled = false

        [projects."/tmp/a"]
        trust_level = "trusted"
        """)
        try write(".claude.json", """
        {"mcpServers": {"notion": {"type": "http", "url": "https://mcp.notion.com/mcp"}}}
        """)
        let catalog = MCPCatalog(home: root, environment: [:])
        let view = MCPSettingsView(
            catalog: catalog, snapshot: catalog.scan(),
            preferences: FilePreferences(fileURL: root.appendingPathComponent("prefs.json")),
            localize: { $0 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        return (view, root)
    }
}
