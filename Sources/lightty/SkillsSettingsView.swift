import AppKit

/// 设置右侧的技能浏览器。三栏骨架在 `ColumnBrowserView`，这里只回答技能自己的问题：
/// 来源树怎么分、当前筛选下有哪些技能、详情栏摆什么。
final class SkillsSettingsView: ColumnBrowserView {
    enum Filter: Equatable {
        case all, favorites, mine, unclassified, unused, source(String), skill(String), builtIn
    }

    private let catalog: SkillCatalog
    private let organization: SkillOrganization
    private(set) var snapshot: SkillCatalogSnapshot
    private(set) var filter: Filter = .all
    private(set) var filteredSkills: [SkillRecord] = []
    private(set) var loading = false
    private var rawDocument = false
    private var actionError: String?
    private var renderedID: String?
    private var renderedContent: String?
    private var renderedRaw = false

    private let detailTitle = SkillsSettingsView.label("", font: SkillsStyle.titleFont)
    private let detailSource = SkillsSettingsView.label("", font: SkillsStyle.summaryFont, secondary: true)
    private let detailSummary = SkillsSettingsView.label("", font: SkillsStyle.summaryFont, secondary: true)
    private let documentLabel = SkillsSettingsView.label("SKILL.md", font: SkillsStyle.sectionFont, secondary: true)
    private let pathScroll = BrowserFileLocationsView()
    private var paths: NSTextView { pathScroll.textView }
    private let bodyScroll = NSTextView.scrollableTextView()
    private var body: NSTextView { bodyScroll.documentView as! NSTextView }
    private lazy var favoriteButton = ShellIconButton(symbol: "star", accessibilityLabel: localize("Favorite"), target: self, action: #selector(toggleFavorite))
    private lazy var moreButton = ShellIconButton(symbol: "ellipsis", accessibilityLabel: localize("Skill actions"), target: self, action: #selector(showActions))
    private lazy var openButton = ShellTextButton(localize("Open file"), target: self, action: #selector(openFile))
    private lazy var revealButton = ShellIconButton(symbol: "folder", accessibilityLabel: localize("Open the skill folder"), target: self, action: #selector(revealFile))
    private lazy var sourceButton = ShellIconButton(symbol: "arrow.up.right", accessibilityLabel: localize("Open source"), target: self, action: #selector(openSource))
    private lazy var rawButton = ShellTextButton(localize("Source"), target: self, action: #selector(toggleRaw))

    init(catalog: SkillCatalog = SkillCatalog(), organization: SkillOrganization = .shared,
         snapshot: SkillCatalogSnapshot? = nil, preferences: PreferenceStorage = FilePreferences.shared,
         localize: @escaping (String) -> String = { L($0) }) {
        self.catalog = catalog
        self.organization = organization
        self.snapshot = snapshot ?? .init(skills: [], warnings: [])
        super.init(scope: "settings.skills", preferences: preferences, localize: localize)
        buildDetail()
        applyChromeText()
        resetSelection(to: key(for: .all))
        reloadNavigation()
        reloadList()
        if snapshot == nil { refresh() }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 测试与旧调用点仍按技能的说法称呼这张表。
    var skillTable: NSTableView { listTable }
    var selectedID: String? { selectedListID }
    var selectedSkill: SkillRecord? { filteredSkills.first { $0.id == selectedListID } }

    private static func label(_ text: String, font: NSFont, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = secondary ? ShellStyle.secondaryText : ShellStyle.primaryText
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func buildDetail() {
        pathScroll.onResize = { [weak self] in self?.needsLayout = true }
        pathScroll.title = localize("File locations")
        for view in [detailTitle, detailSource, detailSummary, favoriteButton, moreButton,
                     openButton, revealButton, sourceButton, rawButton, documentLabel,
                     pathScroll, bodyScroll] {
            detailArea.addSubview(view)
        }
        detailSummary.maximumNumberOfLines = 2
        detailSummary.cell?.wraps = true
        detailSummary.cell?.isScrollable = false
        paths.isEditable = false
        paths.isSelectable = true
        paths.drawsBackground = false
        paths.font = SkillsStyle.codeFont
        paths.textColor = ShellStyle.secondaryText
        paths.textContainerInset = .zero
        paths.textContainer?.lineFragmentPadding = 0
        paths.setAccessibilityLabel(localize("File locations"))
        body.identifier = NSUserInterfaceItemIdentifier("skill-document")
        body.isEditable = false
        body.isSelectable = true
        body.drawsBackground = false
        body.textContainerInset = NSSize(width: 0, height: 8)
        body.textContainer?.lineFragmentPadding = 0
        body.setAccessibilityLabel(localize("Skill content"))
        bodyScroll.drawsBackground = false
        bodyScroll.automaticallyAdjustsContentInsets = false
        bodyScroll.hasVerticalScroller = true
        bodyScroll.autohidesScrollers = true
    }

    // MARK: - 骨架要的答案

    override var searchPlaceholder: String { localize("Search skills or sources…") }
    override var navigationAccessibilityLabel: String { localize("Skill sources") }
    override var listAccessibilityLabel: String { localize("Skills") }
    override var detailEmptyText: String { localize("Select a skill to read its instructions.") }
    override var emptyListText: String {
        searchQuery.isEmpty ? localize("No skills in this category.") : localize("No matching skills.")
    }
    override var listHeadingText: String {
        let active = navigation.first { $0.key == selectedKey }
        return active?.qualifiedName ?? active?.title ?? filteredSkills.first?.sourceTitle ?? localize("All skills")
    }

    override func navigationCell(for item: NavigationItem) -> NSView? {
        if isBuiltInClaudeNote(item) { return BuiltInNoteCell(text: item.title) }
        if item.key == nil && (item.title == "Claude Code" || item.title == "Codex") {
            return ColumnBrowserCell(title: item.title, subtitle: nil, symbol: "",
                                     trailing: item.showsCount ? String(item.count) : "", heading: false,
                                     inTree: true, titleFont: ShellStyle.Font.groupTitle, groupSurface: true,
                                     topSpacing: item.title == "Codex" ? Self.groupGap : 0)
        }
        return super.navigationCell(for: item)
    }

    /// 两个内置分组之间的留白，与 Plugins 页的 Agent 分组一致。
    private static let groupGap: CGFloat = 12

    override func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard tableView === navigationTable else { return super.tableView(tableView, heightOfRow: row) }
        let item = navigation[row]
        if isBuiltInClaudeNote(item) {
            return BuiltInNoteCell.height(for: item.title, rowWidth: navigationTable.bounds.width)
        }
        if item.key == nil && item.title == "Claude Code" { return 36 }
        if item.key == nil && item.title == "Codex" { return 36 + Self.groupGap }
        return super.tableView(tableView, heightOfRow: row)
    }

    private func isBuiltInClaudeNote(_ item: NavigationItem) -> Bool {
        item.key == nil && item.title == localize("Bundled with Claude Code; reading is not supported yet.")
    }

    /// 说明会换行：导航栏变宽变窄时，它那一行的高度跟着重算。
    private var measuredNavigationWidth: CGFloat = 0
    override func layout() {
        super.layout()
        let width = navigationTable.bounds.width
        guard width != measuredNavigationWidth else { return }
        measuredNavigationWidth = width
        guard let row = navigation.firstIndex(where: isBuiltInClaudeNote) else { return }
        // 表默认把行高变化做成动画，拖栏宽时说明会慢半拍跟上。
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            navigationTable.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
        }
    }

    override func makeNavigation() -> [NavigationItem] {
        func item(_ title: String, _ symbol: String, _ filter: Filter) -> NavigationItem {
            .init(title: title, symbol: symbol, key: key(for: filter),
                  count: snapshot.skills.filter { matches($0, filter: filter) }.count)
        }
        var rows: [NavigationItem] = [
            item(localize("All skills"), "square.grid.2x2", .all),
            item(localize("Favorites"), "star", .favorites),
            item(localize("Mine"), "person.crop.circle", .mine),
            item(localize("Unclassified"), "tray", .unclassified),
            item(localize("Unused"), "moon.zzz", .unused),
            .init(title: localize("Common installations")),
        ]
        let sources = Dictionary(grouping: snapshot.skills.filter { $0.origin == .installed }, by: \.sourceID)
        for (id, skills) in sources.sorted(by: { ($0.value.first?.sourceTitle ?? "") < ($1.value.first?.sourceTitle ?? "") }) {
            let title = skills.first?.sourceTitle ?? id
            let shortTitle = title.hasSuffix("/skills") ? String(title.dropLast(7)) : title
            rows.append(item(shortTitle, "", .source(id)))
        }
        // 插件带来的技能归它的插件，在 Plugins 页里——同一个技能列两遍，看着像装了两份。
        // 内置技能自成一段，与「通用安装」平级：这一段下面只有它一家，再套一层
        // 「Agent 安装」就是一级只领一个孩子的空壳。
        rows.append(.init(title: localize("Built-in skills")))
        for agent in ["claude", "codex"] {
            if agent == "claude" {
                // 说明是标题下的次级文字，不进分组底框：底框只标出分区本身。
                rows.append(.init(title: "Claude Code", showsCount: false))
                rows.append(.init(title: localize("Bundled with Claude Code; reading is not supported yet.")))
                continue
            }
            let records = snapshot.skills.filter { $0.origin == .builtIn && agentID($0) == agent }
            rows.append(.init(title: "Codex", count: records.count))
            for skill in records.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                rows.append(.init(title: skill.name, key: key(for: .skill(skill.id)), depth: 0, showsCount: false))
            }
        }
        // Refresh preserves the current document unless its source or skill disappeared.
        if case .source(let id) = filter, !snapshot.skills.contains(where: { $0.sourceID == id }) { reset() }
        if case .skill(let id) = filter, !snapshot.skills.contains(where: { $0.id == id }) { reset() }
        updateDiagnostics()
        return rows
    }

    override func makeListIDs() -> [String] {
        let query = searchQuery
        filteredSkills = snapshot.skills.filter {
            matches($0, filter: filter) && (query.isEmpty || [$0.name, $0.summary, $0.sourceTitle]
                .contains { $0.localizedCaseInsensitiveContains(query) })
        }.sorted { lhs, rhs in
            if lhs.name == rhs.name { return lhs.id < rhs.id }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return filteredSkills.map(\.id)
    }

    override func listCell(for id: String) -> NSView? {
        guard let skill = filteredSkills.first(where: { $0.id == id }) else { return nil }
        let annotation = organization.annotation(for: skill.id)
        return ColumnBrowserCell(title: skill.name,
                                 subtitle: skill.summary.isEmpty ? skill.sourceTitle : skill.summary,
                                 symbol: "", trailing: annotation.favorite ? "☆" : (skill.issue == nil ? "" : "!"))
    }

    override func didSelectNavigation(key: String) {
        if let value = filter(forKey: key) { filter = value }
    }

    override func didSelectList(id: String?) { updateDetail() }

    override func reloadData() { refresh() }

    override func layoutDetail(in rect: NSRect) {
        let inset = detailInset
        let width = max(0, rect.width - inset * 2)
        let top = SkillsStyle.topInset
        detailTitle.frame = NSRect(x: inset, y: top, width: max(0, width - 72), height: 28)
        favoriteButton.frame = NSRect(x: rect.width - inset - 64, y: top, width: 28, height: 28)
        moreButton.frame = NSRect(x: rect.width - inset - 28, y: top, width: 28, height: 28)
        detailSource.frame = NSRect(x: inset, y: top + 34, width: width, height: 18)
        detailSummary.frame = NSRect(x: inset, y: top + 58, width: width, height: 36)
        openButton.frame = NSRect(x: inset, y: top + 100, width: 100, height: 28)
        revealButton.frame = NSRect(x: inset + 108, y: top + 100, width: 28, height: 28)
        sourceButton.frame = NSRect(x: inset + 144, y: top + 100, width: 28, height: 28)
        pathScroll.frame = NSRect(x: inset, y: top + 136, width: width, height: pathScroll.preferredHeight)
        let documentTop = pathScroll.frame.maxY + 12
        documentLabel.frame = NSRect(x: inset, y: documentTop + 5, width: max(0, width - 80), height: 18)
        rawButton.frame = NSRect(x: rect.width - inset - 68, y: documentTop, width: 68, height: 28)
        let bodyTop = documentTop + 36
        bodyScroll.frame = NSRect(x: inset, y: bodyTop, width: width,
                                  height: max(0, rect.height - bodyTop - SkillsStyle.inset))
    }

    // MARK: - 技能自己的事

    private func key(for filter: Filter) -> String {
        switch filter {
        case .all: return "all"
        case .favorites: return "favorites"
        case .mine: return "mine"
        case .unclassified: return "unclassified"
        case .unused: return "unused"
        case .builtIn: return "builtIn"
        case .source(let id): return "source:\(id)"
        case .skill(let id): return "skill:\(id)"
        }
    }

    private func filter(forKey key: String) -> Filter? {
        switch key {
        case "all": return .all
        case "favorites": return .favorites
        case "mine": return .mine
        case "unclassified": return .unclassified
        case "unused": return .unused
        case "builtIn": return .builtIn
        default:
            if key.hasPrefix("source:") { return .source(String(key.dropFirst("source:".count))) }
            if key.hasPrefix("skill:") { return .skill(String(key.dropFirst("skill:".count))) }
            return nil
        }
    }

    private func reset() {
        filter = .all
        resetSelection(to: key(for: .all))
    }

    private func matches(_ skill: SkillRecord, filter: Filter) -> Bool {
        let annotation = organization.annotation(for: skill.id)
        switch filter {
        case .all: return skill.origin == .installed || skill.origin == .local
        case .favorites: return annotation.favorite
        case .mine: return annotation.isMine
        case .unclassified: return skill.origin == .local && !annotation.isMine
        // 只对「全部技能」这一批成立：Codex 内置技能在 Claude 的统计里本来就没有记录，
        // 把它们算成「没用过」是拿没有的数据下结论。
        case .unused: return (skill.origin == .installed || skill.origin == .local)
            && (skill.usage?.count ?? 0) == 0
        case .source(let id): return skill.sourceID == id
        case .skill(let id): return skill.id == id
        case .builtIn: return skill.origin == .builtIn
        }
    }

    private func agentID(_ skill: SkillRecord) -> String {
        skill.sourceID.hasPrefix("builtin:claude") || skill.sourceTitle.hasPrefix("Claude") ? "claude" : "codex"
    }

    @objc func refresh() {
        guard !loading else { return }
        loading = true
        refreshButton.isEnabled = false
        refreshButton.isRefreshing = true
        let catalog = self.catalog
        // Directory trees may live on slow volumes; never block AppKit while scanning them.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = catalog.scan()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.loading = false
                self.refreshButton.isEnabled = true
                self.refreshButton.isRefreshing = false
                self.replaceSnapshot(result)
            }
        }
    }

    func replaceSnapshot(_ value: SkillCatalogSnapshot) {
        snapshot = value
        reloadNavigation()
        reloadList()
    }

    func selectFilter(_ value: Filter) {
        filter = value
        resetSelection(to: key(for: value))
        reloadNavigation()
        reloadList()
    }

    private func updateDetail() {
        let skill = selectedSkill
        for view in [detailTitle, detailSource, detailSummary, favoriteButton, moreButton, openButton,
                     revealButton, sourceButton, documentLabel, rawButton, pathScroll, bodyScroll] {
            view.isHidden = skill == nil
        }
        guard let skill else { paths.string = ""; body.string = ""; renderedID = nil; renderedContent = nil; return }
        detailTitle.stringValue = skill.name
        detailTitle.toolTip = skill.name
        let actual = skill.fileURL.path
        var links: [String] = []
        var seen: Set<String> = [actual]
        for location in skill.locations where seen.insert(location.url.path).inserted {
            links.append(location.url.path + "\n→\n" + actual)
        }
        let pathText = links.isEmpty ? actual : links.joined(separator: "\n")
        if paths.string != pathText {
            paths.string = pathText
            paths.scrollToBeginningOfDocument(nil)
            pathScroll.refreshSummary()
        }
        // 用量只有 Claude Code 记，措辞里点明出处，免得读成全局统计。
        let usage = skill.usage?.summary(localize: localize)
        detailSource.stringValue = [skill.sourceTitle, usage].compactMap { $0 }.joined(separator: " · ")
        detailSource.toolTip = ([skill.sourceTitle, usage].compactMap { $0 }
            + skill.locations.map { "\($0.label): \($0.url.path)" }).joined(separator: "\n")
        detailSummary.stringValue = skill.issue ?? skill.summary
        detailSummary.toolTip = skill.issue ?? skill.summary
        let favorite = organization.annotation(for: skill.id).favorite
        favoriteButton.image = NSImage(systemSymbolName: favorite ? "star.fill" : "star", accessibilityDescription: localize("Favorite"))
        favoriteButton.isActive = favorite
        favoriteButton.setAccessibilityValue(favorite ? localize("Favorite") : localize("Not favorited"))
        sourceButton.isEnabled = skill.sourceURL != nil
        openButton.isEnabled = FileManager.default.fileExists(atPath: skill.fileURL.path)
        updateDocument()
    }

    private func updateDocument(force: Bool = false) {
        guard let skill = selectedSkill else { return }
        let changed = renderedID != skill.id || renderedContent != skill.content || renderedRaw != rawDocument
        guard force || changed else { return }
        let selection = body.selectedRange()
        let scrollOrigin = bodyScroll.contentView.bounds.origin
        body.textStorage?.setAttributedString(SkillDocumentPresentation.text(skill.content, raw: rawDocument, hidesFrontmatter: true))
        if changed {
            body.setSelectedRange(NSRange(location: 0, length: 0))
            body.scrollToBeginningOfDocument(nil)
        } else {
            body.setSelectedRange(selection)
            bodyScroll.contentView.scroll(to: scrollOrigin)
            bodyScroll.reflectScrolledClipView(bodyScroll.contentView)
        }
        renderedID = skill.id
        renderedContent = skill.content
        renderedRaw = rawDocument
        rawButton.label = rawDocument ? localize("Preview") : localize("Source")
    }

    /// 技能几乎从不是一个文件：references、scripts、agents 就在它旁边。
    /// 这里不把它们摊进界面——目录结构交给 Finder，它本来就是干这个的。
    var skillFolderURL: URL? { selectedSkill?.fileURL.deletingLastPathComponent() }

    func refreshLocalization() {
        pathScroll.title = localize("File locations")
        openButton.label = localize("Open file")
        rawButton.label = rawDocument ? localize("Preview") : localize("Source")
        applyChromeText()
        for (button, key) in [(refreshButton, "Refresh skills"), (favoriteButton, "Favorite"),
                              (moreButton, "Skill actions"), (revealButton, "Open the skill folder"), (sourceButton, "Open source")] {
            button.toolTip = localize(key)
            button.setAccessibilityLabel(localize(key))
        }
        reloadNavigation()
        reloadList()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateDocument(force: true)
    }

    @objc func toggleFavorite() {
        guard let skill = selectedSkill else { return }
        do {
            try organization.setFavorite(!organization.annotation(for: skill.id).favorite, for: skill.id)
            actionError = nil
            reloadNavigation()
            reloadList()
        } catch { report(error) }
    }

    @objc func toggleMine() {
        guard let skill = selectedSkill else { return }
        do {
            try organization.setMine(!organization.annotation(for: skill.id).isMine, for: skill.id)
            actionError = nil
            reloadNavigation()
            reloadList()
        } catch { report(error) }
    }

    @objc private func toggleRaw() { rawDocument.toggle(); updateDocument() }

    @objc private func openFile() {
        guard let url = selectedSkill?.fileURL else { return }
        if !NSWorkspace.shared.open(url) { reportMessage(localize("The skill file could not be opened.")) }
    }

    /// 打开技能所在的文件夹，而不是选中 SKILL.md：要看的是这个技能带了些什么。
    @objc private func revealFile() {
        guard let url = skillFolderURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openSource() {
        guard let url = selectedSkill?.sourceURL, ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func showActions() {
        guard let skill = selectedSkill else { return }
        let menu = NSMenu()
        let mine = NSMenuItem(title: localize("Mark as mine"), action: #selector(toggleMine), keyEquivalent: "")
        mine.state = organization.annotation(for: skill.id).isMine ? .on : .off
        mine.target = self
        menu.addItem(mine)
        let copy = NSMenuItem(title: localize("Copy file path"), action: #selector(copyPath), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        menu.addItem(.separator())
        let locations = NSMenuItem(title: localize("Found in"), action: nil, keyEquivalent: "")
        menu.addItem(locations)
        for location in skill.locations {
            let item = NSMenuItem(title: location.label, action: #selector(revealLocation(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = location.url
            item.toolTip = location.url.path
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.maxY), in: moreButton)
    }

    @objc private func revealLocation(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func copyPath() {
        guard let url = selectedSkill?.fileURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    private var diagnostics: [String] {
        snapshot.warnings + [organization.loadError, actionError].compactMap { $0 }
            + snapshot.skills.compactMap { skill in skill.issue.map { "\(skill.name): \($0)" } }
    }

    private func updateDiagnostics() {
        setFooter(String(format: localize("%d notices"), diagnostics.count),
                  tooltip: diagnostics.joined(separator: "\n"),
                  target: self, action: #selector(showDiagnostics), hidden: diagnostics.isEmpty)
    }

    @objc private func showDiagnostics() {
        let alert = NSAlert()
        alert.messageText = localize("Skills notices")
        alert.informativeText = diagnostics.joined(separator: "\n\n")
        if let window { alert.beginSheetModal(for: window) }
    }

    private func report(_ error: Error) { reportMessage(error.localizedDescription) }

    private func reportMessage(_ message: String) {
        actionError = message
        updateDiagnostics()
        showDiagnostics()
    }
}

/// 内置 Claude Code 分组下的说明：在底框之外、与标题同列，窄栏里换行而不截断。
private final class BuiltInNoteCell: NSTableCellView {
    private static let font = ShellStyle.Font.hint
    private static let verticalInset: CGFloat = 2
    private let label = NSTextField(wrappingLabelWithString: "")

    init(text: String) {
        super.init(frame: .zero)
        label.stringValue = text
        label.font = Self.font
        label.textColor = ShellStyle.secondaryText
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityLabel(text)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private static func textWidth(rowWidth: CGFloat) -> CGFloat {
        max(0, rowWidth - ColumnBrowserCell.treeTextLeft() - 8)
    }

    static func height(for text: String, rowWidth: CGFloat) -> CGFloat {
        let measure = NSTextField(wrappingLabelWithString: text)
        measure.font = font
        let size = measure.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth(rowWidth: rowWidth),
                                                              height: .greatestFiniteMagnitude)) ?? .zero
        return ceil(size.height) + verticalInset * 2
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: ColumnBrowserCell.treeTextLeft(), y: Self.verticalInset,
                             width: Self.textWidth(rowWidth: bounds.width),
                             height: max(0, bounds.height - Self.verticalInset * 2))
    }
}
