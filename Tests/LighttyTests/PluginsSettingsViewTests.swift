import AppKit
import Testing
@testable import lightty

@Suite(.serialized)
@MainActor
struct PluginsSettingsViewTests {
    /// `codex plugin list` takes over two seconds; the page used to stay blank for all of it,
    /// every time settings opened, because each opening builds a fresh view.
    @Test func openingPaintsLocalResultsWithoutWaitingForCodexAndReopeningStartsFromTheLastOne() async throws {
        let (fixtureView, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = try #require(fixtureView.snapshot.codexInventory)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal(); gate.signal() }
        let slow = PluginCatalog(home: root, environment: [:], inventory: { _, _ in gate.wait(); return entries })
        let preferences = FilePreferences(fileURL: root.appendingPathComponent("slow.json"))

        let first = PluginsSettingsView(catalog: slow, preferences: preferences)
        try await awaitUntil("local plugins paint while Codex is still answering") {
            first.snapshot.plugins.contains { $0.agent == .claudeCode }
        }
        #expect(first.loading)
        #expect(!first.snapshot.plugins.contains { $0.agent == .codex })
        gate.signal()
        try await awaitUntil("Codex answer lands") { !first.loading }
        #expect(first.snapshot.plugins.contains { $0.agent == .codex })

        let reopened = PluginsSettingsView(catalog: slow, preferences: preferences)
        #expect(reopened.snapshot.plugins == first.snapshot.plugins)
        #expect(reopened.loading)
        gate.signal()
        try await awaitUntil("reopened page finishes its own refresh") { !reopened.loading }
    }

    @Test func togglingEnabledWritesTheAgentFileAndTheRowFollows() throws {
        let (view, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent(".claude/settings.json")
        view.selectPlugin("claude:figma@claude-plugins-official")
        #expect(view.selectedPlugin?.state == .enabled)
        view.setEnabled(false)
        #expect(view.selectedPlugin?.state == .disabled)
        #expect(JSONTextEdit.boolean(at: ["enabledPlugins", "figma@claude-plugins-official"],
                                     in: try String(contentsOf: settings, encoding: .utf8)) == false)
        #expect(try String(contentsOf: settings, encoding: .utf8).contains("\"model\" : \"opus\""))
        view.setEnabled(true)
        #expect(view.selectedPlugin?.state == .enabled)
        // A rescan of the same files must agree with what the toggle just reported.
        view.replaceSnapshot(PluginCatalog(home: root, environment: [:], inventory: { _, _ in .init(entries: [
            .init(pluginId: "visualize@openai-bundled", version: "1.0.37", enabled: true),
            .init(pluginId: "sites@openai-bundled", version: "0.1.70", enabled: true),
            .init(pluginId: "sites@openai-curated-remote", version: "0.1.70", enabled: false)
        ]) }).scan())
        #expect(view.selectedPlugin?.state == .enabled)
    }

    @Test func aFailedWriteIsReportedAndLeavesTheToggleWhereItWas() throws {
        let (view, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent(".claude/settings.json")
        try "[\"not an object\"]".write(to: settings, atomically: true, encoding: .utf8)
        view.selectPlugin("claude:figma@claude-plugins-official")
        view.setEnabled(false)
        #expect(view.selectedPlugin?.state == .enabled)
        #expect(try String(contentsOf: settings, encoding: .utf8) == "[\"not an object\"]")
        #expect(view.diagnostics.contains { $0.contains("shape") })
        #expect(!view.footerButton.isHidden)
    }

    @Test(arguments: ["en", "zh-Hans"])
    func threeColumnsRemainUsableAndRenderInBothAppearances(language: String) throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/lightty/Resources")
        let bundle = try #require(Bundle(url: resources.appendingPathComponent("\(language).lproj")))
        let (view, root) = try fixture { bundle.localizedString(forKey: $0, value: $0, table: nil) }
        defer { try? FileManager.default.removeItem(at: root) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 760),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        view.selectPlugin("claude:notion@claude-plugins-official")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            view.appearance = NSAppearance(named: appearance)
            for width in [CGFloat(1280), 1080, 900] {
                window.setContentSize(NSSize(width: width, height: 760))
                view.needsLayout = true
                view.layoutSubtreeIfNeeded()
                let text = try #require(descendants(view).compactMap { $0 as? NSTextView }
                    .first { $0.identifier?.rawValue == "plugin-document" })
                #expect(text.string.contains("Search the workspace"))
                #expect(!text.isEditable)
                if let path = ProcessInfo.processInfo.environment["LIGHTTY_UI_SNAPSHOT_DIR"] {
                    let directory = URL(fileURLWithPath: path)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try captureSettingsWindow(window, to: directory.appendingPathComponent(
                        "settings-plugins-\(language)-\(appearance.rawValue)-\(Int(width)).png"))
                }
            }
        }
    }

    /// 一份贴着本机真实布局的临时家目录：Claude 用安装清单，Codex 用缓存加 config.toml。
    /// 视图直接扫这份目录，写入测试也能对着同样的文件断言。
    private func fixture(localize: @escaping (String) -> String = { L($0) }) throws -> (PluginsSettingsView, URL) {
        _ = NSApplication.shared
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("plugins-view-\(UUID())")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        func skill(_ path: String, name: String, body: String) throws {
            try write("\(path)/SKILL.md", """
            ---
            name: \(name)
            description: \(body)
            ---

            # \(name)

            \(body)
            """)
        }
        let claude = ".claude/plugins/cache/claude-plugins-official"
        try skill("\(claude)/figma/2.2.111/skills/figma-use", name: "figma-use",
                  body: "Drive a Figma file from the editor.")
        try skill("\(claude)/notion/0.1.0/skills/search", name: "search", body: "Search the workspace.")
        try write("\(claude)/notion/0.1.0/commands/notion.md", "---\ndescription: Ask Notion.\n---\nAsk.")
        try write("\(claude)/notion/0.1.0/hooks/hooks.json",
                  "{\"hooks\":{\"SessionStart\":[{\"hooks\":[{\"type\":\"command\"}]}]}}")
        try write("\(claude)/notion/0.1.0/.mcp.json",
                  "{\"mcpServers\":{\"notion-search\":{\"type\":\"http\"}}}")
        try write(".claude/plugins/installed_plugins.json", """
        {"version": 2, "plugins": {
          "figma@claude-plugins-official": [{"scope": "user", "version": "2.2.111",
            "installPath": "\(root.appendingPathComponent("\(claude)/figma/2.2.111").path)"}],
          "notion@claude-plugins-official": [{"scope": "user", "version": "0.1.0",
            "installPath": "\(root.appendingPathComponent("\(claude)/notion/0.1.0").path)"}]
        }}
        """)
        try write(".claude/settings.json", """
        {
          "model" : "opus",
          "enabledPlugins" : {
            "figma@claude-plugins-official" : true,
            "notion@claude-plugins-official" : false
          }
        }
        """)
        try skill(".codex/plugins/cache/openai-bundled/visualize/1.0.37/skills/visualize",
                  name: "visualize", body: "Draw a chart.")
        // One manifest with a Codex one-liner, one Claude manifest with only a long description:
        // the tree's second line takes the one-liner when there is one.
        try write(".codex/plugins/cache/openai-bundled/visualize/1.0.37/.codex-plugin/plugin.json",
                  #"{"name":"visualize","description":"Create interactive charts, maps, diagrams and simulations.","interface":{"shortDescription":"Create interactive visuals"}}"#)
        try write("\(claude)/notion/0.1.0/.claude-plugin/plugin.json",
                  #"{"name":"notion","description":"Notion Skills + Notion MCP server packaged for Claude Code."}"#)
        for marketplace in ["openai-bundled", "openai-curated-remote"] {
            try skill(".codex/plugins/cache/\(marketplace)/sites/0.1.70/skills/sites",
                      name: "sites", body: "Publish a site.")
        }
        try skill(".codex/plugins/cache/openai-curated-remote/gmail/0.1.10/skills/gmail",
                  name: "gmail", body: "Read mail.")
        try write(".codex/config.toml", """
        [plugins."visualize@openai-bundled"]
        enabled = true

        [plugins."sites@openai-bundled"]
        enabled = true

        [plugins."sites@openai-curated-remote"]
        enabled = false
        """)
        let catalog = PluginCatalog(home: root, environment: [:], inventory: { _, _ in .init(entries: [
            .init(pluginId: "visualize@openai-bundled", version: "1.0.37", enabled: true),
            .init(pluginId: "sites@openai-bundled", version: "0.1.70", enabled: true),
            .init(pluginId: "sites@openai-curated-remote", version: "0.1.70", enabled: false)
        ]) })
        let preferences = FilePreferences(fileURL: root.appendingPathComponent("layout.json"))
        let view = PluginsSettingsView(catalog: catalog, snapshot: catalog.scan(),
                                       preferences: preferences, localize: localize)
        return (view, root)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
