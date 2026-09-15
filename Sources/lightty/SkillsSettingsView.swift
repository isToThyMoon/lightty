import AppKit

/// 设置右侧的技能浏览器。来源、列表与正文都限制在设置内容区内。
final class SkillsSettingsView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    enum Filter: Equatable {
        case all, favorites, mine, unclassified, source(String), skill(String), builtIn
    }

    private struct NavigationItem {
        let title: String
        let symbol: String
        let filter: Filter?
        let count: Int
        var depth: Int = 0
        var disclosure: String? = nil
        var note: String? = nil
    }

    private let localize: (String) -> String
    private let catalog: SkillCatalog
    private let organization: SkillOrganization
    private let preferences: PreferenceStorage
    private(set) var snapshot: SkillCatalogSnapshot
    private(set) var filter: Filter = .all
    private(set) var filteredSkills: [SkillRecord] = []
    private(set) var selectedID: String?
    private(set) var loading = false
    private var navigation: [NavigationItem] = []
    private var collapsedGroups: Set<String> = []
    private var updatingSelection = false
    private var rawDocument = false
    private var actionError: String?
    private var renderedID: String?
    private var renderedContent: String?
    private var renderedRaw = false

    private let horizontalScroll = NSScrollView()
    private let canvas = SkillsFlippedView()
    private let sidebar = ShellBackdropView(fill: ShellStyle.raisedSurface)
    private let listBackground = ShellBackdropView(fill: ShellStyle.raisedSurface)
    private let detailBackground = ShellBackdropView(fill: ShellStyle.raisedSurface)
    let firstDivider = SkillsColumnDivider()
    let secondDivider = SkillsColumnDivider()
    private var preferredSidebarWidth: CGFloat?
    private var preferredListWidth: CGFloat?
    private let documentDivider = ShellBackdropView(fill: ShellStyle.divider)
    private let navigationScroll = SidebarListScrollView()
    private let listScroll = SidebarListScrollView()
    let navigationTable = NSTableView()
    let skillTable = NSTableView()
    let searchField = NSSearchField()
    private let listHeading = SkillsSettingsView.label("", font: SkillsStyle.nameFont)
    private let countLabel = SkillsSettingsView.label("", font: SkillsStyle.summaryFont, secondary: true)
    private let emptyLabel = SkillsSettingsView.label("", font: SkillsStyle.bodyFont, secondary: true)
    private let detailEmpty = SkillsSettingsView.label("", font: SkillsStyle.bodyFont, secondary: true)
    private let detailTitle = SkillsSettingsView.label("", font: SkillsStyle.titleFont)
    private let detailSource = SkillsSettingsView.label("", font: SkillsStyle.summaryFont, secondary: true)
    private let detailSummary = SkillsSettingsView.label("", font: SkillsStyle.summaryFont, secondary: true)
    private let documentLabel = SkillsSettingsView.label("SKILL.md", font: SkillsStyle.sectionFont, secondary: true)
    private let pathScroll = NSTextView.scrollableTextView()
    private var paths: NSTextView { pathScroll.documentView as! NSTextView }
    private let bodyScroll = NSTextView.scrollableTextView()
    private var body: NSTextView { bodyScroll.documentView as! NSTextView }
    private lazy var refreshButton: RefreshButton = {
        let button = RefreshButton()
        button.allowsCancel = false
        button.target = self
        button.action = #selector(refresh)
        return button
    }()
    private lazy var favoriteButton = ShellIconButton(symbol: "star", accessibilityLabel: localize("Favorite"), target: self, action: #selector(toggleFavorite))
    private lazy var moreButton = ShellIconButton(symbol: "ellipsis", accessibilityLabel: localize("Skill actions"), target: self, action: #selector(showActions))
    private lazy var openButton = ShellTextButton(localize("Open file"), target: self, action: #selector(openFile))
    private lazy var revealButton = ShellIconButton(symbol: "folder", accessibilityLabel: localize("Reveal in Finder"), target: self, action: #selector(revealFile))
    private lazy var sourceButton = ShellIconButton(symbol: "arrow.up.right", accessibilityLabel: localize("Open source"), target: self, action: #selector(openSource))
    private lazy var rawButton = ShellTextButton(localize("Source"), target: self, action: #selector(toggleRaw))
    private lazy var diagnosticButton = ShellTextButton("", target: self, action: #selector(showDiagnostics))

    init(catalog: SkillCatalog = SkillCatalog(), organization: SkillOrganization = .shared,
         snapshot: SkillCatalogSnapshot? = nil, preferences: PreferenceStorage = FilePreferences.shared, localize: @escaping (String) -> String = { L($0) }) {
        collapsedGroups = Set(preferences.stringArray(forKey: "settings.skills.collapsedGroups") ?? [])
        self.preferences = preferences
        let sidebarWidth = preferences.double(forKey: "settings.skills.sidebarWidth")
        let listWidth = preferences.double(forKey: "settings.skills.listWidth")
        preferredSidebarWidth = sidebarWidth.isFinite && sidebarWidth > 0 ? sidebarWidth : nil
        preferredListWidth = listWidth.isFinite && listWidth > 0 ? listWidth : nil
        self.localize = localize
        self.catalog = catalog
        self.organization = organization
        self.snapshot = snapshot ?? .init(skills: [], warnings: [])
        super.init(frame: .zero)
        build()
        rebuildNavigation()
        applyFilter()
        if snapshot == nil { refresh() }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var selectedSkill: SkillRecord? { filteredSkills.first { $0.id == selectedID } }

    private static func label(_ text: String, font: NSFont, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = secondary ? ShellStyle.secondaryText : ShellStyle.primaryText
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func build() {
        horizontalScroll.drawsBackground = false
        // This scroll view is already inside the settings page, not the window content.
        // A second titlebar/safe-area inset would expose a transparent band above it.
        horizontalScroll.automaticallyAdjustsContentInsets = false
        horizontalScroll.contentInsets = NSEdgeInsetsZero
        horizontalScroll.hasHorizontalScroller = true
        horizontalScroll.autohidesScrollers = true
        horizontalScroll.documentView = canvas
        addSubview(horizontalScroll)
        for view in [sidebar, listBackground, detailBackground, firstDivider, secondDivider,
                     navigationScroll, listScroll, listHeading, countLabel, searchField,
                     refreshButton, emptyLabel, detailEmpty, detailTitle, detailSource, detailSummary,
                     favoriteButton, moreButton, openButton, revealButton, sourceButton, rawButton,
                     documentLabel, documentDivider, pathScroll, bodyScroll, diagnosticButton] {
            canvas.addSubview(view)
        }
        firstDivider.onDrag = { [weak self] position in self?.resizeColumn(first: true, to: position) }
        secondDivider.onDrag = { [weak self] position in self?.resizeColumn(first: false, to: position) }
        configure(navigationTable, in: navigationScroll, label: localize("Skill sources"))
        navigationTable.target = self
        navigationTable.action = #selector(navigationClicked)
        configure(skillTable, in: listScroll, label: localize("Skills"))
        searchField.placeholderString = localize("Search skills or sources…")
        searchField.font = SkillsStyle.bodyFont
        searchField.controlSize = .small
        searchField.delegate = self
        (searchField.cell as? NSSearchFieldCell)?.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel(localize("Search skills or sources…"))
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
        pathScroll.drawsBackground = false
        pathScroll.automaticallyAdjustsContentInsets = false
        pathScroll.hasVerticalScroller = true
        pathScroll.autohidesScrollers = true
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
        emptyLabel.alignment = .center
        detailEmpty.alignment = .center
        detailEmpty.stringValue = localize("Select a skill to read its instructions.")
    }

    private func configure(_ table: NSTableView, in scroll: NSScrollView, label: String) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("content"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.focusRingType = .none
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(label)
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = table
    }

    override func layout() {
        super.layout()
        horizontalScroll.frame = bounds
        let width = max(SkillsStyle.minimumWidth, horizontalScroll.contentSize.width)
        let height = horizontalScroll.contentSize.height
        canvas.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let compact = width < SkillsStyle.compactBreakpoint
        let navWidth = min(max(SkillsStyle.compactSidebarWidth,
            preferredSidebarWidth ?? (compact ? SkillsStyle.compactSidebarWidth : SkillsStyle.sidebarWidth)),
            width - SkillsStyle.compactListWidth - SkillsStyle.minimumDetailWidth)
        let listWidth = min(max(SkillsStyle.compactListWidth,
            preferredListWidth ?? (compact ? SkillsStyle.compactListWidth : SkillsStyle.listWidth)),
            width - navWidth - SkillsStyle.minimumDetailWidth)
        let detailX = navWidth + listWidth
        let inset = SkillsStyle.inset
        let detailInset = compact ? SkillsStyle.inset : SkillsStyle.detailInset
        let detailWidth = width - detailX - detailInset * 2
        let top = SkillsStyle.topInset
        sidebar.frame = NSRect(x: 0, y: 0, width: navWidth, height: height)
        listBackground.frame = NSRect(x: navWidth, y: 0, width: listWidth, height: height)
        detailBackground.frame = NSRect(x: detailX, y: 0, width: width - detailX, height: height)
        firstDivider.frame = NSRect(x: navWidth - 3, y: 0, width: 7, height: height)
        secondDivider.frame = NSRect(x: detailX - 3, y: 0, width: 7, height: height)
        navigationScroll.frame = NSRect(x: 8, y: top, width: navWidth - 16, height: max(0, height - top - 44))
        diagnosticButton.frame = NSRect(x: inset, y: max(top + 44, height - 40), width: navWidth - inset * 2, height: 28)
        listHeading.frame = NSRect(x: navWidth + inset, y: top + 6, width: listWidth - 104, height: 20)
        countLabel.frame = NSRect(x: detailX - 76, y: top + 6, width: 32, height: 18)
        countLabel.alignment = .right
        refreshButton.frame = NSRect(x: detailX - inset - 28, y: top, width: 28, height: 28)
        searchField.frame = NSRect(x: navWidth + inset, y: top + 40, width: listWidth - inset * 2, height: 28)
        listScroll.frame = NSRect(x: navWidth + 8, y: top + 80, width: listWidth - 16, height: max(0, height - top - 80))
        emptyLabel.frame = NSRect(x: navWidth + inset, y: top + 112, width: listWidth - inset * 2, height: 44)
        detailEmpty.frame = NSRect(x: detailX + detailInset, y: height / 2, width: detailWidth, height: 24)
        detailTitle.frame = NSRect(x: detailX + detailInset, y: top, width: detailWidth - 72, height: 28)
        favoriteButton.frame = NSRect(x: width - detailInset - 64, y: top, width: 28, height: 28)
        moreButton.frame = NSRect(x: width - detailInset - 28, y: top, width: 28, height: 28)
        detailSource.frame = NSRect(x: detailX + detailInset, y: top + 36, width: detailWidth, height: 18)
        detailSummary.frame = NSRect(x: detailX + detailInset, y: top + 64, width: detailWidth, height: 36)
        openButton.frame = NSRect(x: detailX + detailInset, y: top + 112, width: 100, height: 28)
        revealButton.frame = NSRect(x: detailX + detailInset + 108, y: top + 112, width: 28, height: 28)
        sourceButton.frame = NSRect(x: detailX + detailInset + 144, y: top + 112, width: 28, height: 28)
        pathScroll.frame = NSRect(x: detailX + detailInset, y: top + 152, width: detailWidth, height: 72)
        documentLabel.frame = NSRect(x: detailX + detailInset, y: top + 248, width: detailWidth - 80, height: 18)
        rawButton.frame = NSRect(x: width - detailInset - 68, y: top + 240, width: 68, height: 28)
        documentDivider.frame = NSRect(x: detailX + detailInset, y: top + 276, width: detailWidth, height: 1)
        bodyScroll.frame = NSRect(x: detailX + detailInset, y: top + 284, width: detailWidth,
                                 height: max(0, height - top - 284 - inset))
        for table in [navigationTable, skillTable] {
            if let clip = table.enclosingScrollView?.contentView {
                table.setFrameSize(NSSize(width: clip.bounds.width, height: max(table.frame.height, clip.bounds.height)))
                table.sizeLastColumnToFit()
            }
        }
    }


    private func resizeColumn(first: Bool, to position: CGFloat) {
        if first {
            let rightEdge = listBackground.frame.maxX
            preferredSidebarWidth = min(max(SkillsStyle.compactSidebarWidth, position),
                                        rightEdge - SkillsStyle.compactListWidth)
            preferredListWidth = rightEdge - preferredSidebarWidth!
        } else {
            preferredSidebarWidth = sidebar.frame.width
            preferredListWidth = min(max(SkillsStyle.compactListWidth, position - sidebar.frame.width),
                                     canvas.bounds.width - sidebar.frame.width - SkillsStyle.minimumDetailWidth)
        }
        preferences.set(preferredSidebarWidth, forKey: "settings.skills.sidebarWidth")
        preferences.set(preferredListWidth, forKey: "settings.skills.listWidth")
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    @objc func refresh() {
        guard !loading else { return }
        loading = true
        refreshButton.isEnabled = false
        refreshButton.isRefreshing = true
        emptyLabel.stringValue = localize("Reading skills…")
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
        rebuildNavigation()
        applyFilter()
    }

    func selectFilter(_ value: Filter) {
        filter = value
        rebuildNavigation()
        applyFilter()
    }

    func search(_ query: String) {
        searchField.stringValue = query
        applyFilter()
    }

    func controlTextDidChange(_ notification: Notification) { applyFilter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.moveDown(_:)), !filteredSkills.isEmpty else { return false }
        window?.makeFirstResponder(skillTable)
        skillTable.selectRowIndexes(IndexSet(integer: max(0, skillTable.selectedRow)), byExtendingSelection: false)
        return true
    }

    private func matches(_ skill: SkillRecord, filter: Filter) -> Bool {
        let annotation = organization.annotation(for: skill.id)
        switch filter {
        case .all: return skill.origin == .installed || skill.origin == .local
        case .favorites: return annotation.favorite
        case .mine: return annotation.isMine
        case .unclassified: return skill.origin == .local && !annotation.isMine
        case .source(let id): return skill.sourceID == id
        case .skill(let id): return skill.id == id
        case .builtIn: return skill.origin == .builtIn
        }
    }

    private func rebuildNavigation() {
        func item(_ title: String, _ symbol: String, _ filter: Filter) -> NavigationItem {
            .init(title: title, symbol: symbol, filter: filter, count: snapshot.skills.filter { matches($0, filter: filter) }.count)
        }
        navigation = [
            item(localize("All skills"), "square.grid.2x2", .all),
            item(localize("Favorites"), "star", .favorites),
            item(localize("Mine"), "person.crop.circle", .mine),
            item(localize("Unclassified"), "tray", .unclassified),
            .init(title: localize("Common installations"), symbol: "", filter: nil, count: 0),
        ]
        let sources = Dictionary(grouping: snapshot.skills.filter { $0.origin == .installed }, by: \.sourceID)
        for (id, skills) in sources.sorted(by: { ($0.value.first?.sourceTitle ?? "") < ($1.value.first?.sourceTitle ?? "") }) {
            let title = skills.first?.sourceTitle ?? id
            let shortTitle = title.hasSuffix("/skills") ? String(title.dropLast(7)) : title
            navigation.append(item(shortTitle, "", .source(id)))
        }
        navigation.append(.init(title: localize("Agent installations"), symbol: "", filter: nil, count: 0))
        for origin in [SkillOrigin.plugin, .builtIn] {
            let category = origin == .plugin ? "Plugin skills" : "Built-in skills"
            navigation.append(.init(title: localize(category), symbol: origin == .plugin ? "puzzlepiece.extension" : "cpu",
                                    filter: nil, count: 0, depth: 1))
            for agent in ["claude", "codex"] {
                if origin == .builtIn && agent == "claude" {
                    navigation.append(.init(title: "Claude Code", symbol: "", filter: nil, count: 0,
                        depth: 2, note: localize("Bundled with Claude Code; reading is not supported yet.")))
                    continue
                }
                let key = "\(origin.rawValue):\(agent)"
                let records = snapshot.skills.filter { $0.origin == origin && agentID($0) == agent }
                let collapsed = collapsedGroups.contains(key)
                navigation.append(.init(title: agent == "claude" ? "Claude Code" : "Codex",
                    symbol: collapsed ? "chevron.right" : "chevron.down", filter: nil,
                    count: records.count, depth: 2, disclosure: key))
                guard !collapsed else { continue }
                if origin == .builtIn {
                    for skill in records.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                        navigation.append(.init(title: skill.name, symbol: "", filter: .skill(skill.id), count: 0, depth: 3))
                    }
                    continue
                }
                let sources = Dictionary(grouping: records, by: \.sourceID)
                for (id, skills) in sources.sorted(by: { ($0.value.first?.sourceTitle ?? "")
                    .localizedStandardCompare($1.value.first?.sourceTitle ?? "") == .orderedAscending }) {
                    let title = skills.first?.sourceTitle ?? id
                    let name = title
                        .replacingOccurrences(of: "Claude · ", with: "")
                        .replacingOccurrences(of: "Codex · ", with: "")
                        .replacingOccurrences(of: " (cache)", with: "")
                    navigation.append(.init(title: name, symbol: "", filter: .source(id), count: skills.count, depth: 3))
                }
            }
        }
        // Collapsing a group hides its rows, but does not discard the current document.
        if case .source(let id) = filter, !snapshot.skills.contains(where: { $0.sourceID == id }) { filter = .all }
        if case .skill(let id) = filter, !snapshot.skills.contains(where: { $0.id == id }) { filter = .all }
        updatingSelection = true
        navigationTable.reloadData()
        if let index = navigation.firstIndex(where: { $0.filter == filter }) {
            navigationTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else { navigationTable.deselectAll(nil) }
        updatingSelection = false
        updateDiagnostics()
    }

    private func agentID(_ skill: SkillRecord) -> String {
        if skill.sourceID.hasPrefix("plugin:claude:") || skill.sourceID.hasPrefix("builtin:claude")
            || skill.sourceTitle.hasPrefix("Claude") { return "claude" }
        return "codex"
    }

    @objc private func navigationClicked() {
        let row = navigationTable.clickedRow
        guard navigation.indices.contains(row), let key = navigation[row].disclosure else { return }
        toggleGroup(key)
    }

    func toggleGroup(_ key: String) {
        if !collapsedGroups.insert(key).inserted { collapsedGroups.remove(key) }
        preferences.set(collapsedGroups.sorted(), forKey: "settings.skills.collapsedGroups")
        rebuildNavigation()
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredSkills = snapshot.skills.filter {
            matches($0, filter: filter) && (query.isEmpty || [$0.name, $0.summary, $0.sourceTitle]
                .contains { $0.localizedCaseInsensitiveContains(query) })
        }.sorted { lhs, rhs in
            if lhs.name == rhs.name { return lhs.id < rhs.id }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        if !filteredSkills.contains(where: { $0.id == selectedID }) { selectedID = filteredSkills.first?.id }
        updatingSelection = true
        skillTable.reloadData()
        if let index = filteredSkills.firstIndex(where: { $0.id == selectedID }) {
            skillTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            skillTable.scrollRowToVisible(index)
        } else { skillTable.deselectAll(nil) }
        updatingSelection = false
        listHeading.stringValue = navigation.first(where: { $0.filter == filter })?.title
            ?? filteredSkills.first?.sourceTitle ?? localize("All skills")
        listHeading.toolTip = listHeading.stringValue
        countLabel.stringValue = String(filteredSkills.count)
        emptyLabel.isHidden = !filteredSkills.isEmpty
        emptyLabel.stringValue = query.isEmpty ? localize("No skills in this category.") : localize("No matching skills.")
        updateDetail()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === navigationTable ? navigation.count : filteredSkills.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard tableView === navigationTable else { return SkillsStyle.skillRowHeight }
        let item = navigation[row]
        if item.note != nil { return SkillsStyle.skillRowHeight }
        return item.filter == nil && item.disclosure == nil ? (item.depth == 0 ? 40 : 34) : SkillsStyle.navigationRowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        tableView !== navigationTable || navigation[row].filter != nil
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ShellTableRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === navigationTable {
            let item = navigation[row]
            let trailing: String
            if case .skill = item.filter { trailing = "" }
            else { trailing = item.filter == nil && item.disclosure == nil ? "" : String(item.count) }
            return SkillsCell(title: item.title, subtitle: item.note, symbol: item.symbol,
                              trailing: trailing,
                              heading: item.filter == nil && item.disclosure == nil && item.note == nil, depth: item.depth)
        }
        let skill = filteredSkills[row]
        let annotation = organization.annotation(for: skill.id)
        return SkillsCell(title: skill.name, subtitle: skill.summary.isEmpty ? skill.sourceTitle : skill.summary,
                          symbol: "", trailing: annotation.favorite ? "☆" : (skill.issue == nil ? "" : "!"))
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSelection, let table = notification.object as? NSTableView else { return }
        if table === navigationTable {
            guard navigation.indices.contains(table.selectedRow), let value = navigation[table.selectedRow].filter else { return }
            selectFilter(value)
        } else {
            selectedID = filteredSkills.indices.contains(table.selectedRow) ? filteredSkills[table.selectedRow].id : nil
            updateDetail()
        }
    }

    private func updateDetail() {
        let skill = selectedSkill
        for view in [detailTitle, detailSource, detailSummary, favoriteButton, moreButton, openButton,
                     revealButton, sourceButton, documentLabel, rawButton, documentDivider, pathScroll, bodyScroll] {
            view.isHidden = skill == nil
        }
        detailEmpty.isHidden = skill != nil
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
        }
        detailSource.stringValue = skill.sourceTitle
        detailSource.toolTip = skill.locations.map { "\($0.label): \($0.url.path)" }.joined(separator: "\n")
        detailSummary.stringValue = skill.issue ?? skill.provenanceNote ?? skill.summary
        detailSummary.toolTip = skill.issue ?? skill.provenanceNote ?? skill.summary
        let favorite = organization.annotation(for: skill.id).favorite
        favoriteButton.image = NSImage(systemSymbolName: favorite ? "star.fill" : "star", accessibilityDescription: localize("Favorite"))
        favoriteButton.isActive = favorite
        favoriteButton.setAccessibilityValue(favorite ? localize("Favorite") : localize("Not favorited"))
        openButton.isEnabled = FileManager.default.fileExists(atPath: skill.fileURL.path)
        sourceButton.isEnabled = skill.sourceURL != nil
        updateDocument()
    }

    private func updateDocument(force: Bool = false) {
        guard let skill = selectedSkill else { return }
        let changed = renderedID != skill.id || renderedContent != skill.content || renderedRaw != rawDocument
        guard force || changed else { return }
        let selection = body.selectedRange()
        let scrollOrigin = bodyScroll.contentView.bounds.origin
        body.textStorage?.setAttributedString(SkillDocumentPresentation.text(skill.content, raw: rawDocument))
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

    func refreshLocalization() {
        openButton.label = localize("Open file")
        rawButton.label = rawDocument ? localize("Preview") : localize("Source")
        searchField.placeholderString = localize("Search skills or sources…")
        searchField.setAccessibilityLabel(localize("Search skills or sources…"))
        detailEmpty.stringValue = localize("Select a skill to read its instructions.")
        for (button, key) in [(refreshButton, "Refresh skills"), (favoriteButton, "Favorite"),
                              (moreButton, "Skill actions"), (revealButton, "Reveal in Finder"), (sourceButton, "Open source")] {
            button.toolTip = localize(key)
            button.setAccessibilityLabel(localize(key))
        }
        rebuildNavigation()
        applyFilter()
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
            rebuildNavigation()
            applyFilter()
        } catch { report(error) }
    }

    @objc func toggleMine() {
        guard let skill = selectedSkill else { return }
        do {
            try organization.setMine(!organization.annotation(for: skill.id).isMine, for: skill.id)
            actionError = nil
            rebuildNavigation()
            applyFilter()
        } catch { report(error) }
    }

    @objc private func toggleRaw() { rawDocument.toggle(); updateDocument() }
    @objc private func openFile() {
        guard let skill = selectedSkill else { return }
        if !NSWorkspace.shared.open(skill.fileURL) { reportMessage(localize("The skill file could not be opened.")) }
    }
    @objc private func revealFile() {
        guard let skill = selectedSkill else { return }
        NSWorkspace.shared.activateFileViewerSelecting([skill.fileURL])
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
        guard let skill = selectedSkill else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(skill.fileURL.path, forType: .string)
    }

    private var diagnostics: [String] {
        snapshot.warnings + [organization.loadError, actionError].compactMap { $0 }
            + snapshot.skills.compactMap { skill in skill.issue.map { "\(skill.name): \($0)" } }
    }

    private func updateDiagnostics() {
        diagnosticButton.isHidden = diagnostics.isEmpty
        diagnosticButton.label = String(format: localize("%d notices"), diagnostics.count)
        diagnosticButton.toolTip = diagnostics.joined(separator: "\n")
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

private final class SkillsFlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class SkillsCell: NSTableCellView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let trailingLabel = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let disclosureIcon = SidebarDisclosureButton.ChevronView()
    private let isHeading: Bool
    private let hasSubtitle: Bool
    private let hasIcon: Bool
    private let isDisclosure: Bool
    private let depth: Int

    init(title: String, subtitle: String?, symbol: String, trailing: String, heading: Bool = false, depth: Int = 0) {
        self.depth = depth
        isHeading = heading
        hasSubtitle = subtitle != nil
        hasIcon = !symbol.isEmpty
        isDisclosure = symbol.hasPrefix("chevron.")
        super.init(frame: .zero)
        nameLabel.stringValue = title
        nameLabel.font = heading ? (depth == 0 ? SkillsStyle.sectionFont : SkillsStyle.nameFont) : (hasSubtitle ? SkillsStyle.nameFont : SkillsStyle.bodyFont)
        nameLabel.textColor = heading && depth == 0 ? ShellStyle.tertiaryText : ShellStyle.primaryText
        summaryLabel.stringValue = subtitle ?? ""
        summaryLabel.font = SkillsStyle.summaryFont
        summaryLabel.textColor = ShellStyle.secondaryText
        trailingLabel.stringValue = trailing
        trailingLabel.font = SkillsStyle.summaryFont
        trailingLabel.textColor = ShellStyle.tertiaryText
        trailingLabel.alignment = .right
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        icon.contentTintColor = ShellStyle.secondaryText
        for label in [nameLabel, summaryLabel, trailingLabel] {
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        addSubview(icon)
        addSubview(disclosureIcon)
        disclosureIcon.isHidden = !isDisclosure
        icon.isHidden = isDisclosure
        disclosureIcon.glyph.setAffineTransform(CGAffineTransform(rotationAngle: symbol == "chevron.down" ? .pi / 2 : 0))
        toolTip = [title, subtitle].compactMap { $0 }.joined(separator: "\n")
        setAccessibilityElement(true)
        setAccessibilityLabel(toolTip)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var backgroundStyle: NSView.BackgroundStyle { get { .normal } set {} }

    override func layout() {
        super.layout()
        let inset: CGFloat = 8
        // One icon lane and 16pt indentation steps; text rows retain the same lane.
        let indent = CGFloat(max(0, depth - 1)) * 16
        let iconWidth: CGFloat = isDisclosure ? 12 : 16
        let x: CGFloat = (hasSubtitle && depth == 0) || (isHeading && depth == 0) ? inset
            : inset + indent + iconWidth + 8
        let trailingWidth: CGFloat = trailingLabel.stringValue.isEmpty ? 0 : max(16, trailingLabel.intrinsicContentSize.width + 4)
        let width = max(0, bounds.width - x - inset - trailingWidth)
        let y: CGFloat = hasSubtitle ? 12 : (bounds.height - 18) / 2
        nameLabel.frame = NSRect(x: x, y: y, width: width, height: 18)
        summaryLabel.frame = NSRect(x: depth == 0 ? inset : x, y: 34,
            width: max(0, bounds.width - (depth == 0 ? inset : x) - inset), height: 18)
        summaryLabel.isHidden = !hasSubtitle
        trailingLabel.frame = NSRect(x: bounds.width - inset - trailingWidth, y: y, width: trailingWidth, height: 18)
        disclosureIcon.frame = NSRect(x: inset + indent, y: (bounds.height - 12) / 2, width: 12, height: 12)
        icon.frame = NSRect(x: inset + indent, y: (bounds.height - 16) / 2, width: iconWidth, height: 16)
    }
}
