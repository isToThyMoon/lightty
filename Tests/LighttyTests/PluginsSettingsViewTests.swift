import AppKit
import Testing
@testable import lightty

@Suite(.serialized)
@MainActor
struct PluginsSettingsViewTests {
    @Test func agentGroupsCollapseIndependentlyAndRestoreFromDisk() throws {
        let (fixtureView, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = FilePreferences(fileURL: root.appendingPathComponent("groups.json"))
        let view = PluginsSettingsView(snapshot: fixtureView.snapshot, preferences: preferences)
        view.selectPlugin("claude:figma@claude-plugins-official")
        let claudeRows = view.navigation.prefix { $0.disclosure != "agent:codex" }.count
                let selected = view.selectedPlugin?.id
        view.toggleGroup("agent:codex")
        #expect(view.navigationTable.numberOfRows
            == claudeRows + 1)
        // Collapsing the other agent must not disturb what is being read.
        #expect(view.selectedPlugin?.id == selected)
        view.toggleGroup("agent:claude")
        #expect(view.navigationTable.numberOfRows == 2)
        preferences.flush()
        let reopened = PluginsSettingsView(snapshot: fixtureView.snapshot,
                                           preferences: FilePreferences(fileURL: preferences.fileURL))
        #expect(reopened.navigationTable.numberOfRows == 2)
        reopened.toggleGroup("agent:claude")
        #expect(reopened.navigationTable.numberOfRows == claudeRows + 1)
    }

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

    @Test func pluginRowsCarryTheirOneLinerAsASecondLine() throws {
        let (view, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = Dictionary(view.navigation.compactMap { row in row.qualifiedName.map { ($0, row) } },
                              uniquingKeysWith: { first, _ in first })
        #expect(rows["visualize@openai-bundled"]?.note == "Create interactive visuals")
        #expect(rows["notion@claude-plugins-official"]?.note == "Notion Skills + Notion MCP server packaged for Claude Code.")
        // No manifest, no invented line: the row stays one line tall.
        #expect(rows["gmail@openai-curated-remote"]?.note == nil)
    }

    @Test func marketplaceGroupsKeepSameNamedPluginsDistinctWithoutAddingDisclosure() throws {
        let (view, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for market in ["openai-bundled", "openai-curated-remote"] {
            let headerIndex = try #require(view.navigation.firstIndex { $0.qualifiedName == market })
            let header = view.navigation[headerIndex]
            #expect(header.key == nil && header.disclosure == nil)
            #expect(!view.tableView(view.navigationTable, shouldSelectRow: headerIndex))
            let installed = view.snapshot.plugins.filter { $0.agent == .codex && $0.marketplace == market && $0.state != .cachedOnly }
            #expect(header.count == installed.count)
            view.selectPlugin("codex:sites@\(market)")
            #expect(view.selectedPlugin?.marketplace == market)
            #expect(view.navigation[view.navigationTable.selectedRow].title == "sites")
            #expect(view.navigationTable.selectedRow > headerIndex)
        }
    }

    @Test func aPluginRowCarriesItsVersionUntilTheRowIsTooNarrowForBoth() throws {
        let (view, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        view.selectPlugin("claude:figma@claude-plugins-official")
        let cell = try #require(view.tableView(view.navigationTable, viewFor: nil,
                                               row: view.navigationTable.selectedRow))
        #expect(cell.toolTip?.contains("figma@claude-plugins-official") == true)
        func title(at width: CGFloat) -> String {
            cell.frame = NSRect(x: 0, y: 0, width: width, height: SkillsStyle.navigationRowHeight)
            cell.needsLayout = true
            cell.layoutSubtreeIfNeeded()
            return descendants(cell).compactMap { $0 as? NSTextField }
                .first { $0.stringValue.hasPrefix("figma") }?.stringValue ?? ""
        }
        #expect(title(at: 280) == "figma  2.2.111")
        // Too narrow for both: the whole name stays and the version steps aside.
        #expect(title(at: 120) == "figma")
        // Widening must not undo that: no measurement may depend on the previous pass.
        #expect(title(at: 280) == "figma  2.2.111")
    }

    @Test func contentsListEveryKindAndSearchKeepsTheDocumentInSync() throws {
        let (view, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        view.selectPlugin("claude:notion@claude-plugins-official")
        #expect(view.contents.map(\.name) == ["search", "notion", "SessionStart", "notion-search"])
        #expect(view.contents.map(\.kind) == [.skill, .command, .hook, .mcpServer])
        #expect(view.selectedContent?.name == "search")
        let text = try #require(descendants(view).compactMap { $0 as? NSTextView }
            .first { $0.identifier?.rawValue == "plugin-document" })
        #expect(text.string.contains("Search the workspace"))
        view.search("mcp")
        #expect(view.contents.map(\.name) == ["notion-search"])
        #expect(view.selectedContent?.kind == .mcpServer)
        // JSON contents have no preview mode, so they are shown exactly as written.
        #expect(text.string.contains("\"type\" : \"http\""))
        view.search("nothing matches this")
        #expect(view.selectedContent == nil)
        #expect(text.string.isEmpty)
        view.search("")
        view.selectPlugin("codex:visualize@openai-bundled")
        #expect(view.contents.map(\.name) == ["visualize"])
    }

    @Test func theMiddleColumnGroupsContentsByKindInsteadOfOneFlatList() throws {
        let (view, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        view.selectPlugin("claude:notion@claude-plugins-official")
        // Text that enters the context first, outside capabilities after.
        #expect(view.listIDs.filter { $0.hasPrefix("group:") }
                == ["group:skill", "group:command", "group:mcpServer", "group:hook"])
        #expect(view.listIDs.count == view.contents.count + 4)
        #expect(view.listIDs.allSatisfy { view.isListRowSelectable($0) != $0.hasPrefix("group:") })
        // A header is not an entry: selection lands on the first real row.
        #expect(view.selectedContent?.name == "search")
        let header = try #require(view.tableView(view.listTable, viewFor: nil, row: 0))
        let headerLabels = descendants(header).compactMap { $0 as? NSTextField }.map(\.stringValue)
        #expect(headerLabels.contains(L("Skills")))
        #expect(headerLabels.contains("1"))
        let entry = try #require(view.tableView(view.listTable, viewFor: nil, row: 1))
        let entryLabels = descendants(entry).compactMap { $0 as? NSTextField }.map(\.stringValue)
        #expect(entryLabels.contains("search"))
        // The kind is on the header now; repeating it would crowd out the description.
        #expect(entryLabels.contains("Search the workspace."))
        #expect(!entryLabels.contains { $0.hasPrefix(L("Skill") + " · ") })
        // Searching narrows the groups to whatever still matches.
        view.search("mcp")
        #expect(view.listIDs == ["group:mcpServer"] + view.contents.map(\.id))
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
        view.replaceSnapshot(PluginCatalog(home: root, environment: [:], inventory: { _, _ in [
            .init(pluginId: "visualize@openai-bundled", version: "1.0.37", installed: true, enabled: true),
            .init(pluginId: "sites@openai-bundled", version: "0.1.70", installed: true, enabled: true),
            .init(pluginId: "sites@openai-curated-remote", version: "0.1.70", installed: true, enabled: false)
        ] }).scan())
        #expect(view.selectedPlugin?.state == .enabled)
    }

    @Test func cachedOnlyPluginsOfferNoToggleAndSayWhy() throws {
        let (view, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        view.selectPlugin("codex:gmail@openai-curated-remote")
        #expect(view.selectedPlugin?.state == .cachedOnly)
        let toggle = try #require(descendants(view).compactMap { $0 as? ShellToggle }.first)
        #expect(toggle.isHiddenOrHasHiddenAncestor)
        let labels = descendants(view).compactMap { $0 as? NSTextField }.map(\.stringValue)
        #expect(labels.contains(L("Cached only")))
        #expect(labels.contains(L("Cached in Codex but not in its installed list, so it cannot be enabled here.")))
        view.selectPlugin("codex:visualize@openai-bundled")
        #expect(!toggle.isHiddenOrHasHiddenAncestor)
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
                let nav = try #require(view.navigationTable.enclosingScrollView)
                let list = try #require(view.contentTable.enclosingScrollView)
                #expect(nav.frame.maxX < list.frame.minX)
                #expect(view.searchField.frame.minX > list.frame.minX)
                let text = try #require(descendants(view).compactMap { $0 as? NSTextView }
                    .first { $0.identifier?.rawValue == "plugin-document" })
                let preview = try #require(text.enclosingScrollView)
                #expect(preview.convert(preview.bounds, to: view).minX > list.convert(list.bounds, to: view).maxX)
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
        let catalog = PluginCatalog(home: root, environment: [:], inventory: { _, _ in [
            .init(pluginId: "visualize@openai-bundled", version: "1.0.37", installed: true, enabled: true),
            .init(pluginId: "sites@openai-bundled", version: "0.1.70", installed: true, enabled: true),
            .init(pluginId: "sites@openai-curated-remote", version: "0.1.70", installed: true, enabled: false)
        ] })
        let preferences = FilePreferences(fileURL: root.appendingPathComponent("layout.json"))
        let view = PluginsSettingsView(catalog: catalog, snapshot: catalog.scan(),
                                       preferences: preferences, localize: localize)
        return (view, root)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
