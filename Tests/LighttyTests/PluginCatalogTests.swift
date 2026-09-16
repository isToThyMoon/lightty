import Foundation
import Testing
@testable import lightty

struct PluginCatalogTests {
    @Test func onlyUserScopeInstallationsAppearAndEnablementComesFromSettings() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let user = ".claude/plugins/cache/store/tool/2.0"
        let project = ".claude/plugins/cache/store/tool/3.0"
        try fixture.skill("\(user)/skills/review", name: "review")
        try fixture.skill("\(project)/skills/review", name: "project-only")
        try fixture.skill(".claude/plugins/cache/store/quiet/1.0/skills/idle", name: "idle")
        try fixture.skill(".claude/plugins/cache/store/absent/1.0/skills/gone", name: "gone")
        try fixture.json(".claude/plugins/installed_plugins.json", ["version": 2, "plugins": [
            // The array holds one entry per installation scope; only the user one is global.
            "tool@store": [
                ["installPath": fixture.url(user).path, "scope": "user", "version": "2.0"],
                ["installPath": fixture.url(project).path, "scope": "project", "version": "3.0"],
            ],
            // A missing scope is a user installation.
            "quiet@store": [["installPath": fixture.url(".claude/plugins/cache/store/quiet/1.0").path,
                             "version": "1.0"]],
            "absent@store": [["installPath": fixture.url(".claude/plugins/cache/store/absent/1.0").path,
                              "scope": "local", "version": "1.0"]],
        ]])
        try fixture.json(".claude/settings.json", ["model": "opus", "enabledPlugins": [
            "tool@store": true, "other@store": true,
        ]])
        let snapshot = fixture.scan()
        #expect(snapshot.plugins.map(\.identifier) == ["quiet@store", "tool@store"])
        let tool = try #require(snapshot.plugins.first { $0.identifier == "tool@store" })
        #expect(tool.agent == .claudeCode)
        #expect(tool.name == "tool")
        #expect(tool.marketplace == "store")
        #expect(tool.version == "2.0")
        #expect(tool.state == .enabled)
        #expect(tool.roots.map(\.path) == [fixture.url(user).path])
        #expect(tool.contents.map(\.name) == ["review"])
        // Installed and enabled are two different things: no entry is not an entry saying yes.
        #expect(snapshot.plugins.first { $0.identifier == "quiet@store" }?.state == .disabled)
        #expect(snapshot.warnings.isEmpty)
    }

    @Test func codexInventoryOwnsStateAndVersionAndFailuresRetainLastResult() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for version in ["1.0", "2.0"] {
            try fixture.skill(".codex/plugins/cache/store/tool/\(version)/skills/review", name: version)
        }
        try fixture.skill(".codex/plugins/cache/store/stray/1.0/skills/old", name: "old")
        // Remote installs need no config.toml declaration. Old versions must not leak contents.
        let data = Data(#"{"installed":[{"pluginId":"tool@store","version":"2.0","installed":true,"enabled":true},{"pluginId":"missing@store","version":"3.0","installed":true,"enabled":false},{"pluginId":"cloud@store","version":"1.0","installed":true,"enabled":true,"source":{"source":"remote","id":"plugin_x"}}]}"#.utf8)
        let entries = try CodexPluginInventory.decode(data)
        let catalog = PluginCatalog(home: fixture.home, environment: [:], inventory: { _, _ in entries })
        let snapshot = catalog.scan()
        let tool = try #require(snapshot.plugins.first { $0.identifier == "tool@store" })
        #expect(tool.state == .enabled)
        #expect(tool.version == "2.0")
        #expect(tool.contents.map(\.name) == ["2.0"])
        #expect(tool.roots.count == 1)
        let missing = try #require(snapshot.plugins.first { $0.identifier == "missing@store" })
        #expect(missing.state == .disabled)
        #expect(missing.issue != nil)
        // Codex may sync a remote plugin without materializing it (sites@openai-curated-remote
        // shadowed by the bundled one); that is a state to explain, not a notice.
        let cloud = try #require(snapshot.plugins.first { $0.identifier == "cloud@store" })
        #expect(cloud.issue == nil)
        #expect(cloud.versionNote != nil)
        #expect(cloud.contents.isEmpty)
        let stray = try #require(snapshot.plugins.first { $0.identifier == "stray@store" })
        #expect(stray.state == .cachedOnly)
        #expect(throws: PluginWriteError.self) { try catalog.setEnabled(true, for: stray) }
        let failing = PluginCatalog(home: fixture.home, environment: [:], inventory: { _, _ in
            throw CocoaError(.fileReadCorruptFile)
        })
        let retained = failing.scan(previous: snapshot)
        #expect(retained.plugins == snapshot.plugins)
        #expect(retained.codexQueryFailed)
        #expect(!retained.warnings.isEmpty)
        #expect(failing.scan().plugins.isEmpty)
        // The settings page paints from the last inventory before the 2 s CLI answers:
        // a quick pass must not ask Codex, and must not invent a failure it never saw.
        let quick = failing.scan(previous: snapshot, queryCodex: false)
        #expect(quick.plugins == snapshot.plugins)
        #expect(!quick.codexQueryFailed)
        #expect(quick.warnings.isEmpty)
        #expect(failing.scan(queryCodex: false).plugins.isEmpty)
        #expect(throws: (any Error).self) { try CodexPluginInventory.decode(Data("{}".utf8)) }
        #expect(throws: (any Error).self) {
            try CodexPluginInventory.decode(Data(#"{"installed":[{"pluginId":"../bad@store","installed":true,"enabled":true}]}"#.utf8))
        }
        let empty = PluginCatalog(home: fixture.home, environment: [:], inventory: { _, _ in [] }).scan(previous: snapshot)
        #expect(!empty.codexQueryFailed)
        #expect(empty.plugins.allSatisfy { $0.state == .cachedOnly })
    }

    @Test func oneNameInTwoMarketplacesStaysTwoPlugins() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for marketplace in ["openai-bundled", "openai-curated-remote"] {
            try fixture.skill(".codex/plugins/cache/\(marketplace)/sites/0.1/skills/sites", name: "sites")
        }
        let snapshot = fixture.scan()
        #expect(snapshot.plugins.map(\.name) == ["sites", "sites"])
        #expect(Set(snapshot.plugins.map(\.identifier))
            == ["sites@openai-bundled", "sites@openai-curated-remote"])
        #expect(Set(snapshot.plugins.map(\.id)).count == 2)
    }

    @Test func pluginContentsCoverEveryKindTheAgentsShip() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = ".claude/plugins/cache/store/tool/1.0"
        try fixture.skill("\(root)/skills/review", name: "review")
        try fixture.write("\(root)/commands/tasks/build.md", "---\ndescription: Build a task.\n---\nRun it.")
        try fixture.write("\(root)/agents/scout.md", "---\ndescription: Look around.\n---\nScout.")
        try fixture.json("\(root)/hooks/hooks.json", ["hooks": ["Interrupt": [["hooks": [["type": "command"]]]]]])
        try fixture.json("\(root)/.mcp.json", ["mcpServers": ["notion": ["type": "http"]]])
        try fixture.json("\(root)/.claude-plugin/plugin.json",
                         ["name": "tool", "description": "A tool.", "author": ["name": "Example"]])
        try fixture.json(".claude/plugins/installed_plugins.json", ["plugins": [
            "tool@store": [["installPath": fixture.url(root).path, "scope": "user", "version": "1.0"]],
        ]])
        let plugin = try #require(fixture.scan().plugins.first)
        #expect(plugin.summary == "A tool.")
        #expect(plugin.author == "Example")
        let byKind = Dictionary(grouping: plugin.contents, by: \.kind).mapValues { $0.map(\.name) }
        #expect(byKind[.skill] == ["review"])
        #expect(byKind[.command] == ["tasks/build"])
        #expect(byKind[.agent] == ["scout"])
        #expect(byKind[.hook] == ["Interrupt"])
        #expect(byKind[.mcpServer] == ["notion"])
        #expect(plugin.contents.first { $0.kind == .command }?.summary == "Build a task.")
        // JSON fragments are shown as they are; only Markdown goes through the reader.
        #expect(plugin.contents.first { $0.kind == .mcpServer }?.isMarkdown == false)
        #expect(plugin.contents.first { $0.kind == .skill }?.isMarkdown == true)
    }

    @Test func codexConnectorsAreContentsRatherThanAnEmptyPlugin() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let linked = ".codex/plugins/cache/store/gmail/0.1.10"
        try fixture.json("\(linked)/.codex-plugin/plugin.json",
                         ["name": "gmail", "description": "Work with Gmail.", "apps": "./.app.json",
                          "interface": ["shortDescription": "Read and manage Gmail"]])
        try fixture.json("\(linked)/.app.json", ["apps": ["gmail": ["id": "connector_abc", "required": true]]])
        let inlined = ".codex/plugins/cache/store/browser/1.0"
        try fixture.json("\(inlined)/.codex-plugin/plugin.json",
                         ["name": "browser", "apps": ["apps": ["browser": ["id": "connector_xyz"]]]])
        try fixture.write(".codex/config.toml", """
        [plugins."gmail@store"]
        enabled = true

        [plugins."browser@store"]
        enabled = true
        """)
        let plugins = fixture.scan().plugins
        // Without this, a connector-only plugin reads as "provides nothing".
        let gmail = try #require(plugins.first { $0.name == "gmail" })
        #expect(gmail.contents.map(\.kind) == [.appConnector])
        // The one-liner the Codex app lists plugins with lives in the plugin's own manifest.
        #expect(gmail.tagline == "Read and manage Gmail")
        #expect(gmail.summary == "Work with Gmail.")
        #expect(gmail.contents.map(\.name) == ["gmail"])
        #expect(gmail.contents.first?.fileURL.lastPathComponent == ".app.json")
        #expect(gmail.contents.first?.content.contains("connector_abc") == true)
        #expect(gmail.contents.first?.isMarkdown == false)
        let browser = try #require(plugins.first { $0.name == "browser" })
        #expect(browser.contents.map(\.name) == ["browser"])
        #expect(browser.contents.first?.fileURL.lastPathComponent == "plugin.json")
    }

    @Test func brokenInstallationsStayVisible() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.json(".claude/plugins/installed_plugins.json", ["plugins": [
            "gone@store": [["installPath": "/nonexistent/lightty-test/gone", "scope": "user"]],
            "relative@store": [["installPath": "not/absolute", "scope": "user"]],
            "broken@store": ["not-an-array"],
        ]])
        try fixture.directory(".codex/plugins/cache/store/empty")
        let snapshot = fixture.scan()
        #expect(snapshot.plugins.map(\.identifier) == ["gone@store", "empty@store"])
        #expect(snapshot.plugins.allSatisfy { $0.issue != nil })
        // One warning each for the missing directory, the relative path, the malformed
        // entry, and the cache directory that holds no version.
        #expect(snapshot.warnings.count == 4)
    }

    @Test func enablingRewritesOnlyTheOneValueInEachAgentFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(".claude/settings.json", """
        {
          "model": "opus",
          "enabledPlugins": {
            "tool@store": true,
            "other@store": false
          },
          "theme": "dark"
        }
        """)
        try fixture.write(".codex/config.toml", """
        # hand written
        model = "gpt"

        [plugins."tool@store"]
        enabled = true  # turned on by hand

        [features]
        js_repl = false
        """)
        let catalog = fixture.catalog()
        func settings() throws -> String {
            try String(contentsOf: fixture.url(".claude/settings.json"), encoding: .utf8)
        }
        func config() throws -> String {
            try String(contentsOf: fixture.url(".codex/config.toml"), encoding: .utf8)
        }
        try catalog.setEnabled(false, for: fixture.claude("tool@store", state: .enabled))
        try catalog.setEnabled(true, for: fixture.claude("fresh@store", state: .disabled))
        let written = try settings()
        #expect(JSONTextEdit.boolean(at: ["enabledPlugins", "tool@store"], in: written) == false)
        #expect(JSONTextEdit.boolean(at: ["enabledPlugins", "fresh@store"], in: written) == true)
        #expect(JSONTextEdit.boolean(at: ["enabledPlugins", "other@store"], in: written) == false)
        // Unknown keys, their order, and the indentation all survive.
        #expect(written.contains("\"theme\": \"dark\""))
        #expect(try #require(written.range(of: "\"model\"")).lowerBound
            < #require(written.range(of: "\"enabledPlugins\"")).lowerBound)
        #expect(written.contains("\n    \"fresh@store\": true,"))
        // The first write leaves the original behind; later writes keep that first copy.
        #expect(try String(contentsOf: fixture.url(".claude/settings.json.lightty-backup"), encoding: .utf8)
            .contains("\"tool@store\": true"))

        try catalog.setEnabled(false, for: fixture.codex("tool@store", state: .enabled))
        try catalog.setEnabled(true, for: fixture.codex("added@store", state: .disabled))
        let toml = try config()
        #expect(TOMLTextEdit.pluginEnabled(id: "tool@store", in: toml) == false)
        #expect(TOMLTextEdit.pluginEnabled(id: "added@store", in: toml) == true)
        // Comments, ordering, and unrelated tables are never round-tripped away.
        #expect(toml.contains("# hand written"))
        #expect(toml.contains("enabled = false # turned on by hand"))
        #expect(toml.contains("[features]\njs_repl = false"))
        #expect(try #require(toml.range(of: "[features]")).lowerBound
            < #require(toml.range(of: "[plugins.\"added@store\"]")).lowerBound)
    }

    @Test func aRefusedEditLeavesTheFileUntouched() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(".claude/settings.json", "[1, 2, 3]\n")
        #expect(throws: PluginWriteError.self) {
            try fixture.catalog().setEnabled(true, for: fixture.claude("tool@store", state: .disabled))
        }
        #expect(try String(contentsOf: fixture.url(".claude/settings.json"), encoding: .utf8) == "[1, 2, 3]\n")
    }

    @Test func anEmptyHomeDoesNotInventPlugins() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let snapshot = fixture.scan()
        #expect(snapshot.plugins.isEmpty)
        #expect(snapshot.warnings.isEmpty)
    }

    @Test func codexHomeOverrideSelectsItsOwnCacheAndConfig() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.skill(".codex/plugins/cache/store/ignored/1.0/skills/a", name: "a")
        try fixture.skill("custom/plugins/cache/store/chosen/1.0/skills/b", name: "b")
        try fixture.write("custom/config.toml", "[plugins.\"chosen@store\"]\nenabled = true\n")
        let snapshot = fixture.scan(["CODEX_HOME": fixture.url("custom").path])
        #expect(snapshot.plugins.map(\.identifier) == ["chosen@store"])
        #expect(snapshot.plugins.first?.state == .cachedOnly)
    }

    private struct Fixture {
        let home: URL
        init() throws {
            home = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-catalog-\(UUID())")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }
        func url(_ path: String) -> URL { home.appendingPathComponent(path) }
        func directory(_ path: String) throws {
            try FileManager.default.createDirectory(at: url(path), withIntermediateDirectories: true)
        }
        func write(_ path: String, _ text: String) throws {
            try FileManager.default.createDirectory(at: url(path).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: url(path), atomically: true, encoding: .utf8)
        }
        func skill(_ path: String, name: String) throws {
            try write("\(path)/SKILL.md", "---\nname: \(name)\ndescription: Test description.\n---\n# Instructions\n")
        }
        func json(_ path: String, _ value: [String: Any]) throws {
            try write(path, String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))
        }
        func catalog(_ environment: [String: String] = [:]) -> PluginCatalog {
            PluginCatalog(home: home, environment: environment, inventory: { _, _ in [] })
        }
        func scan(_ environment: [String: String] = [:]) -> PluginCatalogSnapshot {
            catalog(environment).scan()
        }
        func claude(_ identifier: String, state: PluginState) -> PluginRecord {
            record(identifier, agent: .claudeCode, state: state)
        }
        func codex(_ identifier: String, state: PluginState) -> PluginRecord {
            record(identifier, agent: .codex, state: state)
        }
        private func record(_ identifier: String, agent: PluginAgent, state: PluginState) -> PluginRecord {
            PluginRecord(identifier: identifier, name: String(identifier.split(separator: "@")[0]),
                         marketplace: String(identifier.split(separator: "@")[1]), agent: agent,
                         version: nil, roots: [], state: state, summary: "", author: "",
                         versionNote: nil, contents: [], issue: nil)
        }
        func remove() { try? FileManager.default.removeItem(at: home) }
    }
}
