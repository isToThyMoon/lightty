import AppKit
import Testing
@testable import lightty

@Suite(.serialized)
@MainActor
struct SkillsSettingsViewTests {
    @Test func skillsStayInsideSettingsContentAndKeepNavigationVisible() throws {
        let (skills, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsView(page: .skills, skillsView: skills, preferences: FilePreferences(fileURL: root.appendingPathComponent("settings.json")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = settings
        defer { window.contentView = nil; window.close() }
        settings.layoutSubtreeIfNeeded()
        let rect = skills.convert(skills.bounds, to: settings)
        #expect(rect.minX == SettingsView.sidebarWidth)
        #expect(rect.maxX == settings.bounds.maxX)
        let back = try #require(descendants(settings).compactMap { $0 as? SettingsNavRow }
            .first { $0.title == L("Back to app") })
        #expect(!back.isHiddenOrHasHiddenAncestor)
        #expect(!descendants(skills).compactMap { $0 as? NSButton }.contains { $0.title == L("Back to settings") })
        // Both sides must retain an opaque backdrop all the way to the top edge.
        // A transparent scroll-view inset must never reveal the terminal underneath.
        let backgrounds = settings.subviews.compactMap { $0 as? ShellBackdropView }.filter { !$0.isHidden }
        for x in [CGFloat(1), settings.bounds.maxX - 1] {
            let top = NSPoint(x: x, y: settings.bounds.maxY - 1)
            #expect(backgrounds.contains { $0.convert($0.bounds, to: settings).contains(top) })
        }
        let outerScroll = try #require(skills.subviews.compactMap { $0 as? NSScrollView }.first)
        #expect(!outerScroll.automaticallyAdjustsContentInsets)
        #expect(outerScroll.contentInsets.top == 0)
        #expect(outerScroll.frame == skills.bounds)
        settings.showPage(.appearance)
        #expect(skills.superview == nil)
        settings.showPage(.skills)
        settings.layoutSubtreeIfNeeded()
        #expect(skills.convert(skills.bounds, to: settings).minX == SettingsView.sidebarWidth)
        #expect(!back.isHiddenOrHasHiddenAncestor)
    }

    @Test func settingsSidebarCanShrinkAndKeepsPageSelection() throws {
        let (skills, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = FilePreferences(fileURL: root.appendingPathComponent("settings.json"))
        let settings = SettingsView(page: .skills, skillsView: skills, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = settings
        defer { window.contentView = nil; window.close() }
        settings.layoutSubtreeIfNeeded()
        #expect(SettingsView.Page.allCases[2] == .skills)
        let divider = settings.sidebarDivider
        let start = divider.convert(NSPoint(x: 4, y: 100), to: nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: start,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        divider.mouseDown(with: down)
        let drag = try #require(NSEvent.mouseEvent(with: .leftMouseDragged,
            location: NSPoint(x: start.x - 200, y: start.y), modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        divider.mouseDragged(with: drag)
        #expect(skills.convert(skills.bounds, to: settings).minX == 160)
        #expect(settings.currentPage == .skills)
        settings.showPage(.appearance)
        settings.showPage(.skills)
        settings.layoutSubtreeIfNeeded()
        #expect(skills.convert(skills.bounds, to: settings).minX == 160)
        // Reopen from disk, as a fresh settings view after restarting the app would.
        preferences.flush()
        let reopened = SettingsView(page: .skills, skillsView: skills,
                                    preferences: FilePreferences(fileURL: preferences.fileURL))
        window.contentView = reopened
        reopened.layoutSubtreeIfNeeded()
        #expect(skills.convert(skills.bounds, to: reopened).minX == 160)
    }

    @Test func legacyAgentCollapsePreferencesDoNotHideBuiltInSkills() throws {
        let (fixtureView, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = FilePreferences(fileURL: root.appendingPathComponent("groups.json"))
        let view = SkillsSettingsView(snapshot: fixtureView.snapshot, preferences: preferences)
        view.selectFilter(.skill("skill-creator"))
        let initialRows = view.navigationTable.numberOfRows
        let selected = view.selectedID
        view.toggleGroup("builtIn:codex")
        #expect(view.navigationTable.numberOfRows == initialRows)
        // Old persisted collapse preferences no longer hide built-in skills.
        #expect(view.selectedID == selected)
        #expect(view.filter == .skill("skill-creator"))
        preferences.flush()
        let reopened = SkillsSettingsView(snapshot: fixtureView.snapshot,
            preferences: FilePreferences(fileURL: preferences.fileURL))
        #expect(reopened.navigationTable.numberOfRows == initialRows)
        reopened.toggleGroup("builtIn:codex")
        #expect(reopened.navigationTable.numberOfRows == initialRows)
    }

    @Test func builtInNavigationSelectsTheActualSkill() throws {
        let (view, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        view.selectFilter(.skill("skill-creator"))
        #expect(view.navigationTable.selectedRow >= 0)
        #expect(view.filteredSkills.map(\.name) == ["skill-creator"])
        let row = view.navigationTable.selectedRow
        let cell = try #require(view.tableView(view.navigationTable, viewFor: nil, row: row))
        let labels = descendants(cell).compactMap { $0 as? NSTextField }.map(\.stringValue)
        #expect(labels.contains("skill-creator"))
        #expect(!labels.contains(L("Built-in skills")))
    }

    @Test func theFinderButtonOpensTheSkillFolderRatherThanTheFileItself() throws {
        let (view, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = try #require(view.snapshot.skills.first { $0.name == "code-review" })
        view.selectFilter(.all)
        view.selectList(id: skill.id)
        // 目录结构交给 Finder：正文栏只讲 SKILL.md。
        #expect(view.skillFolderURL == skill.fileURL.deletingLastPathComponent())
        #expect(view.skillFolderURL?.lastPathComponent == "code-review")
    }

    @Test func theUnusedFilterHoldsOnlyWhatClaudeCodeHasNeverRun() throws {
        let (view, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let used = try #require(view.snapshot.skills.first { $0.name == "code-review" })
        var withUsage = used
        withUsage.usage = UsageRecord(count: 7, lastUsed: Date(timeIntervalSinceNow: -3_600))
        view.replaceSnapshot(.init(skills: view.snapshot.skills.map { $0.id == used.id ? withUsage : $0 },
                                   warnings: []))
        view.selectFilter(.unused)
        #expect(!view.filteredSkills.contains { $0.name == "code-review" })
        #expect(view.filteredSkills.contains { $0.name == "tdd" })
        // 内置技能不进这一批：Claude 的统计里没有它们，缺记录不等于没用过。
        #expect(!view.filteredSkills.contains { $0.origin == .builtIn })
        view.selectList(id: withUsage.id)
        view.selectFilter(.all)
        view.selectList(id: withUsage.id)
        let source = descendants(view).compactMap { $0 as? NSTextField }
            .first { $0.stringValue.contains(used.sourceTitle) }
        #expect(try #require(source).stringValue.contains("7"))
    }

    @Test func dividerDraggingResizesAdjacentColumnsAndClamps() throws {
        let (view, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        view.layoutSubtreeIfNeeded()
        let selected = view.selectedID
        func drag(_ divider: SkillsColumnDivider, delta: CGFloat) throws {
            let start = divider.convert(NSPoint(x: 4, y: 100), to: nil)
            let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: start,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
            divider.mouseDown(with: down)
            let moved = try #require(NSEvent.mouseEvent(with: .leftMouseDragged,
                location: NSPoint(x: start.x + delta, y: start.y), modifierFlags: [], timestamp: 1,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            divider.mouseDragged(with: moved)
        }
        let secondStart = view.secondDivider.frame.minX
        try drag(view.secondDivider, delta: 100)
        #expect(view.secondDivider.frame.minX == secondStart + 100)
        let firstStart = view.firstDivider.frame.minX
        try drag(view.firstDivider, delta: 50)
        #expect(view.firstDivider.frame.minX == firstStart + 50)
        #expect(view.secondDivider.frame.minX == secondStart + 100)
        try drag(view.firstDivider, delta: -2000)
        #expect(view.firstDivider.frame.minX + 3 == SkillsStyle.compactSidebarWidth)
        try drag(view.secondDivider, delta: 2000)
        #expect(view.secondDivider.frame.minX + 3 == view.bounds.width - SkillsStyle.minimumDetailWidth)
        #expect(view.selectedID == selected)
        #expect(view.firstDivider.frame.width == 7)
    }

    private func fixture(localize: @escaping (String) -> String = { L($0) }) throws -> (SkillsSettingsView, URL) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skills-view-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func skill(_ name: String, source: String = "mattpocock/skills", origin: SkillOrigin = .installed,
                   summary: String = "Review code for clear interfaces and maintainable behavior.",
                   title: String? = nil) throws -> SkillRecord {
            let file = root.appendingPathComponent(name + "/SKILL.md")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let content = """
            ---
            name: \(name)
            description: \(summary)
            ---

            # \(name)

            Read the changes, understand the intent, and review the code against the project's conventions.

            ## Start with the problem

            Describe the behavior that changed. Follow the data from its input to the user-visible result.

            ## Review checklist

            - Keep interfaces small and responsibilities clear.
            - Look for failure paths and missing validation.
            - Prefer a concrete example over an abstract recommendation.

            ## Example

            ```swift
            struct Review {
                let findings: [Finding]
                let summary: String
            }
            ```

            Report actionable findings with a file path and a reason.
            """
            try content.write(to: file, atomically: true, encoding: .utf8)
            return SkillRecord(id: name, name: name, summary: summary, content: content, fileURL: file,
                               sourceID: source, sourceTitle: title ?? source,
                               sourceURL: URL(string: "https://example.com/skills"),
                               origin: origin, locations: [.init(label: "Shared", url: file), .init(label: "Claude", url: file)], issue: nil)
        }
        let records = try [
            skill("code-review"), skill("codebase-design", summary: "Design deep modules with small, useful interfaces."),
            skill("diagnosing-bugs", summary: "Investigate a bug with evidence and a repeatable test."),
            skill("research", summary: "Find primary sources and summarize what they establish."),
            skill("tdd", summary: "Build behavior through red, green, and refactor."),
            skill("lark-doc", source: "Lark CLI", summary: "读取、创建和编辑飞书云文档。"),
            skill("lark-im", source: "Lark CLI", summary: "收发消息和管理群聊。"),
            skill("weekly-summary", source: "Local", origin: .local, summary: "整理本周工作，记录关键进展。"),
            skill("skill-creator", source: "Codex", origin: .builtIn),
        ]
        let store = SkillOrganization(fileURL: root.appendingPathComponent("organization.json"))
        let view = SkillsSettingsView(organization: store, snapshot: .init(skills: records, warnings: []),
                                     preferences: FilePreferences(fileURL: root.appendingPathComponent("layout.json")), localize: localize)
        return (view, root)
    }

    @Test func filtersSearchAndKeyboardSelectionKeepDetailInSync() throws {
        let (view, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(view.filteredSkills.count == 8)
        #expect(view.selectedSkill?.name == "code-review")
        view.search("飞书")
        #expect(view.filteredSkills.map(\.name) == ["lark-doc"])
        #expect(view.selectedSkill?.name == "lark-doc")
        view.search("no such skill")
        #expect(view.selectedID == nil)
        #expect(descendants(view).compactMap { $0 as? NSTextView }.allSatisfy { $0.string.isEmpty })
        view.search("")
        view.selectFilter(.source("mattpocock/skills"))
        view.skillTable.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        #expect(view.selectedSkill?.name == "diagnosing-bugs")
        view.selectFilter(.builtIn)
        #expect(view.selectedSkill?.name == "skill-creator")
    }

    @Test func favoritesAndMineAreIndependentAndDoNotRewriteSkills() throws {
        let (view, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = try #require(view.selectedSkill)
        let before = try Data(contentsOf: skill.fileURL)
        view.toggleFavorite()
        view.toggleMine()
        view.selectFilter(.favorites)
        #expect(view.filteredSkills.map(\.id) == [skill.id])
        view.toggleFavorite()
        #expect(view.filteredSkills.isEmpty)
        view.selectFilter(.mine)
        #expect(view.filteredSkills.map(\.id) == [skill.id])
        #expect(try Data(contentsOf: skill.fileURL) == before)
        let stored = SkillOrganization(fileURL: root.appendingPathComponent("organization.json"))
        #expect(stored.annotation(for: skill.id) == SkillAnnotation(favorite: false, isMine: true))
    }

    @Test func refreshDropsRemovedSelectionAndMissingSource() throws {
        let (view, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        view.selectFilter(.source("mattpocock/skills"))
        let remaining = view.snapshot.skills.filter { $0.sourceID == "Lark CLI" }
        view.replaceSnapshot(.init(skills: remaining, warnings: []))
        #expect(view.filter == .all)
        #expect(view.selectedSkill?.name == "lark-doc")
        view.replaceSnapshot(.init(skills: [], warnings: []))
        #expect(view.selectedSkill == nil)
    }

    @Test func sharedOrganizationKeepsIndependentWindowChanges() throws {
        let (fixtureView, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillOrganization(fileURL: root.appendingPathComponent("shared-organization.json"))
        let first = SkillsSettingsView(organization: store, snapshot: fixtureView.snapshot)
        let second = SkillsSettingsView(organization: store, snapshot: fixtureView.snapshot)
        first.toggleFavorite()
        second.toggleMine()
        first.refreshLocalization()
        first.selectFilter(.mine)
        second.refreshLocalization()
        second.selectFilter(.favorites)
        #expect(first.selectedSkill?.id == "code-review")
        #expect(second.selectedSkill?.id == "code-review")
        let saved = SkillOrganization(fileURL: root.appendingPathComponent("shared-organization.json"))
        #expect(saved.annotation(for: "code-review") == SkillAnnotation(favorite: true, isMine: true))
    }

    @Test(arguments: ["en", "zh-Hans"])
    func threeColumnsRemainUsableAndRenderInBothAppearances(language: String) throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/lightty/Resources")
        let bundle = try #require(Bundle(url: resources.appendingPathComponent("\(language).lproj")))
        let (view, root) = try fixture { bundle.localizedString(forKey: $0, value: $0, table: nil) }
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsView(page: .skills, skillsView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 760),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = settings
        defer { window.contentView = nil; window.close() }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            settings.appearance = NSAppearance(named: appearance)
            for width in [CGFloat(1280), 1080, 900] {
                window.setContentSize(NSSize(width: width, height: 760))
                settings.needsLayout = true
                settings.layoutSubtreeIfNeeded()
                #expect(view.convert(view.bounds, to: settings).minX == SettingsView.sidebarWidth)
                let nav = try #require(view.navigationTable.enclosingScrollView)
                let list = try #require(view.skillTable.enclosingScrollView)
                #expect(nav.frame.width >= SkillsStyle.compactSidebarWidth - 16)
                #expect(list.frame.width >= SkillsStyle.compactListWidth - 16)
                #expect(nav.frame.maxX < list.frame.minX)
                #expect(view.searchField.frame.minX > list.frame.minX)
                let text = try #require(descendants(view).compactMap { $0 as? NSTextView }.first { $0.identifier?.rawValue == "skill-document" })
                let preview = try #require(text.enclosingScrollView)
                #expect(preview.frame.width >= 260)
                // The preview hangs off the detail column, so compare in one coordinate space.
                #expect(preview.convert(preview.bounds, to: view).minX > list.convert(list.bounds, to: view).maxX)
                #expect(text.string.contains("Start with the problem"))
                #expect(!text.isEditable)
                if let path = ProcessInfo.processInfo.environment["LIGHTTY_UI_SNAPSHOT_DIR"] {
                    let directory = URL(fileURLWithPath: path)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try captureSettingsWindow(window, to: directory.appendingPathComponent(
                        "settings-skills-\(language)-\(appearance.rawValue)-\(Int(width)).png"))
                }
            }
        }
    }

    @Test func organizationAndLocalizationPreserveReadingPosition() throws {
        var translated = false
        let (view, root) = try fixture { translated ? "中文 " + $0 : $0 }
        defer { try? FileManager.default.removeItem(at: root) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 460),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        view.layoutSubtreeIfNeeded()
        let text = try #require(descendants(view).compactMap { $0 as? NSTextView }.first { $0.identifier?.rawValue == "skill-document" })
        let scroll = try #require(text.enclosingScrollView)
        text.layoutManager?.ensureLayout(for: try #require(text.textContainer))
        text.setSelectedRange(NSRange(location: 30, length: 10))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 120))
        scroll.reflectScrolledClipView(scroll.contentView)
        let position = scroll.contentView.bounds.origin
        #expect(position.y > 0)
        view.toggleFavorite()
        view.toggleMine()
        view.search("code")
        view.appearance = NSAppearance(named: .darkAqua)
        #expect(text.selectedRange() == NSRange(location: 30, length: 10))
        #expect(scroll.contentView.bounds.origin == position)
        translated = true
        view.refreshLocalization()
        #expect(view.searchField.placeholderString == "中文 Search skills or sources…")
        #expect(text.selectedRange() == NSRange(location: 30, length: 10))
        #expect(scroll.contentView.bounds.origin == position)
    }

    @Test func documentPreviewPreservesCodeAndRawViewPreservesFrontmatter() {
        let text = "---\nname: example\n---\n# Title\n```swift\n# this is code\n```"
        let preview = SkillDocumentPresentation.text(text, raw: false, hidesFrontmatter: true)
        #expect(preview.string.contains("# this is code"))
        #expect(!preview.string.contains("name: example"))
        #expect(SkillDocumentPresentation.text(text, raw: true).string == text)
        let styled = SkillDocumentPresentation.text("\u{feff}---\r\nname: example\r\n...\r\n**中文** and `code`", raw: false, hidesFrontmatter: true)
        #expect(styled.string == "中文 and code\n")
        let bodyOffset = (styled.string as NSString).range(of: "中文").location
        let bold = styled.attribute(.font, at: bodyOffset, effectiveRange: nil) as? NSFont
        #expect(bold.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)
        #expect(styled.attribute(.font, at: bodyOffset + 7, effectiveRange: nil) as? NSFont == SkillsStyle.codeFont)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
