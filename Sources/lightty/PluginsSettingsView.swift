import AppKit

/// 设置右侧的插件浏览器。三栏骨架在 `ColumnBrowserView`，这里只回答插件自己的问题：
/// 左栏按 Agent 分组列插件、中栏列这个插件提供了什么、右栏是插件身份加选中条目的正文。
final class PluginsSettingsView: ColumnBrowserView {
    private let catalog: PluginCatalog
    private(set) var snapshot: PluginCatalogSnapshot
    private(set) var contents: [PluginContent] = []
    private(set) var loading = false
    private var rawDocument = false
    private var actionError: String?
    private var renderedID: String?
    private var renderedRaw = false

    private let detailTitle = PluginsSettingsView.label("", font: SkillsStyle.titleFont)
    private let metaLabel = PluginsSettingsView.label("", font: SkillsStyle.summaryFont, secondary: true)
    private let noteLabel = PluginsSettingsView.label("", font: SkillsStyle.summaryFont, secondary: true)
    private let documentLabel = PluginsSettingsView.label("", font: SkillsStyle.sectionFont, secondary: true)
    private let stateLabel = PluginsSettingsView.label("", font: SkillsStyle.summaryFont, secondary: true)
    private let pathScroll = BrowserFileLocationsView()
    private var paths: NSTextView { pathScroll.textView }
    private let bodyScroll = NSTextView.scrollableTextView()
    private var body: NSTextView { bodyScroll.documentView as! NSTextView }
    private lazy var enableToggle = ShellToggle(isOn: false)
    private lazy var openButton = ShellTextButton(localize("Open file"), target: self, action: #selector(openFile))
    private lazy var revealButton = ShellIconButton(symbol: "folder", accessibilityLabel: localize("Reveal in Finder"), target: self, action: #selector(revealFile))
    private lazy var copyButton = ShellIconButton(symbol: "doc.on.doc", accessibilityLabel: localize("Copy file path"), target: self, action: #selector(copyPath))
    private lazy var rawButton = ShellTextButton(localize("Source"), target: self, action: #selector(toggleRaw))

    init(catalog: PluginCatalog = PluginCatalog(), snapshot: PluginCatalogSnapshot? = nil,
         preferences: PreferenceStorage = FilePreferences.shared,
         localize: @escaping (String) -> String = { L($0) }) {
        self.catalog = catalog
        self.snapshot = snapshot ?? Self.lastSnapshots[catalog.cacheKey] ?? PluginCatalogSnapshot()
        super.init(scope: "settings.plugins", preferences: preferences, localize: localize)
        buildDetail()
        applyChromeText()
        refreshButton.toolTip = localize("Refresh plugins")
        refreshButton.setAccessibilityLabel(localize("Refresh plugins"))
        selectFirstAvailablePlugin()
        reloadNavigation()
        reloadList()
        if snapshot == nil { refresh() }
    }

    required init?(coder: NSCoder) { fatalError() }

    var contentTable: NSTableView { listTable }
    var selectedContent: PluginContent? { contents.first { $0.id == selectedListID } }
    var selectedPlugin: PluginRecord? {
        guard let key = selectedKey else { return nil }
        return snapshot.plugins.first { $0.id == identifier(forKey: key) }
    }

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
        for view in [detailTitle, metaLabel, noteLabel, stateLabel, enableToggle,
                     openButton, revealButton, copyButton, rawButton, documentLabel,
                     pathScroll, bodyScroll] {
            detailArea.addSubview(view)
        }
        noteLabel.maximumNumberOfLines = 2
        noteLabel.cell?.wraps = true
        noteLabel.cell?.isScrollable = false
        stateLabel.alignment = .right
        enableToggle.setAccessibilityLabel(localize("Enable plugin"))
        enableToggle.onChange = { [weak self] value in self?.setEnabled(value) }
        paths.isEditable = false
        paths.isSelectable = true
        paths.drawsBackground = false
        paths.font = SkillsStyle.codeFont
        paths.textColor = ShellStyle.secondaryText
        paths.textContainerInset = .zero
        paths.textContainer?.lineFragmentPadding = 0
        paths.setAccessibilityLabel(localize("File locations"))
        body.identifier = NSUserInterfaceItemIdentifier("plugin-document")
        body.isEditable = false
        body.isSelectable = true
        body.drawsBackground = false
        body.textContainerInset = NSSize(width: 0, height: 8)
        body.textContainer?.lineFragmentPadding = 0
        body.setAccessibilityLabel(localize("Plugin content"))
        bodyScroll.drawsBackground = false
        bodyScroll.automaticallyAdjustsContentInsets = false
        bodyScroll.hasVerticalScroller = true
        bodyScroll.autohidesScrollers = true
    }

    // MARK: - 骨架要的答案

    override var searchPlaceholder: String { localize("Search plugin contents…") }
    override var navigationAccessibilityLabel: String { localize("Installed plugins") }
    override var listAccessibilityLabel: String { localize("Plugin contents") }
    override var detailEmptyText: String { localize("Select an item to see what the plugin provides.") }
    override var emptyListText: String {
        searchQuery.isEmpty ? localize("This plugin provides no contents.") : localize("No matching contents.")
    }
    override var listHeadingText: String { selectedPlugin?.identifier ?? localize("Plugins") }

    override func makeNavigation() -> [NavigationItem] {
        var rows: [NavigationItem] = []
        for agent in PluginAgent.allCases {
            let plugins = snapshot.plugins.filter { $0.agent == agent }
            let group = "agent:\(agent.rawValue)"
            let collapsed = isCollapsed(group)
            rows.append(.init(title: agent.title, symbol: collapsed ? "chevron.right" : "chevron.down",
                              count: plugins.filter { $0.state != .cachedOnly }.count, disclosure: group))
            guard !collapsed else { continue }
            let markets = Dictionary(grouping: plugins, by: \.marketplace)
            for market in markets.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                let entries = markets[market] ?? []
                // 市场一律显示原名：`-remote` 这类后缀带着含义，美化时容易被当成噪音去掉。
                rows.append(.init(title: market,
                                  count: entries.filter { $0.state != .cachedOnly }.count,
                                  qualifiedName: market))
                for plugin in entries.filter({ $0.state != .cachedOnly }) + entries.filter({ $0.state == .cachedOnly }) {
                    // 第二行是插件自己的介绍：Codex 用清单里的一句话（与 Codex app 列表一致），
                    // Claude Code 没有这个字段，退回长描述，放不下就截断，全文在 tooltip。
                    let blurb = plugin.tagline.isEmpty ? plugin.summary : plugin.tagline
                    rows.append(.init(title: plugin.name,
                                      key: key(for: plugin),
                                      count: plugin.contents.count, depth: 0,
                                      note: blurb.isEmpty ? nil : blurb,
                                      version: plugin.state == .cachedOnly ? localize("Cached only") : plugin.version,
                                      qualifiedName: plugin.identifier))
                }
            }
        }
        // 折叠只是把行藏起来，不该丢掉当前阅读的插件；真的消失了才另找落点。
        if selectedPlugin == nil { selectFirstAvailablePlugin() }
        updateDiagnostics()
        return rows
    }

    override func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if tableView === navigationTable, navigation[row].disclosure != nil {
            return row == 0 ? 36 : 48
        }
        return super.tableView(tableView, heightOfRow: row)
    }

    /// 每一级都挂在上一级的文字下面，层级才读得出来：市场小标题与 Agent 标题同列，
    /// 插件再缩一级。插件行不放图标——整列都是插件，同一个图标逐行重复只占宽度。
    /// lane 是图标槽起点，文字在它后面 24pt（16 槽 + 8 间距）。
    /// Agent 行只有一个窄箭头，槽贴到行首，箭头离底框左缘约 8pt，后面各级跟着前移。
    private static let agentLane: CGFloat = 0
    private static let marketplaceLane = agentLane + 24
    private static let pluginLane = marketplaceLane + 16 - 24

    override func navigationCell(for item: NavigationItem) -> NSView? {
        // 数量只标在插件上：Agent 和市场的合计读不出含义，一列数字只是噪音。
        if item.disclosure != nil {
            return ColumnBrowserCell(title: item.title, subtitle: nil, symbol: item.symbol,
                                     trailing: "", inTree: true,
                                     titleFont: ShellStyle.Font.groupTitle, groupSurface: true,
                                     topSpacing: item.disclosure == "agent:codex" && navigation.first?.disclosure != item.disclosure ? 12 : 0,
                                     lane: Self.agentLane)
        }
        guard item.key != nil else {
            return ColumnBrowserCell(title: item.title, subtitle: nil, symbol: "", trailing: "",
                                     heading: true, tooltip: item.qualifiedName, inTree: true,
                                     lane: Self.marketplaceLane)
        }
        return ColumnBrowserCell(title: item.title, subtitle: item.note, symbol: item.symbol,
                                 trailing: String(item.count), version: item.version,
                                 tooltip: item.qualifiedName, inTree: true, lane: Self.pluginLane)
    }

    /// 中栏按类型分组，顺序照两族排：先是进上下文的文本（技能、命令、子 Agent），
    /// 再是外部能力（MCP server、hook、连接器）。平铺成一列时，一个插件由什么构成
    /// 是数不出来的。
    private static let kindOrder: [PluginContentKind] = [.skill, .command, .agent, .mcpServer, .hook, .appConnector]
    private static let groupPrefix = "group:"

    override func makeListIDs() -> [String] {
        let query = searchQuery
        contents = (selectedPlugin?.contents ?? []).filter {
            query.isEmpty || [$0.name, $0.summary, kindTitle($0.kind)]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
        var rows: [String] = []
        for kind in Self.kindOrder where contents.contains(where: { $0.kind == kind }) {
            rows.append(Self.groupPrefix + kind.rawValue)
            rows.append(contentsOf: contents.filter { $0.kind == kind }.map(\.id))
        }
        return rows
    }

    override func isListRowSelectable(_ id: String) -> Bool { groupKind(id) == nil }

    override func listRowHeight(for id: String) -> CGFloat {
        groupKind(id) == nil ? listRowHeight() : SkillsStyle.navigationRowHeight
    }

    override func listCell(for id: String) -> NSView? {
        if let kind = groupKind(id) {
            return ColumnBrowserCell(title: kindGroupTitle(kind), subtitle: nil, symbol: "",
                                     trailing: String(contents.filter { $0.kind == kind }.count),
                                     heading: true)
        }
        guard let item = contents.first(where: { $0.id == id }) else { return nil }
        // 类型已经由组标题说了，第二行留给描述——重复一遍只会把描述挤没。
        return ColumnBrowserCell(title: item.name, subtitle: item.summary,
                                 symbol: "", trailing: item.issue == nil ? "" : "!")
    }

    private func groupKind(_ id: String) -> PluginContentKind? {
        guard id.hasPrefix(Self.groupPrefix) else { return nil }
        return PluginContentKind(rawValue: String(id.dropFirst(Self.groupPrefix.count)))
    }

    override func didSelectList(id: String?) { updateDetail() }

    override func reloadData() { refresh() }

    override func layoutDetail(in rect: NSRect) {
        let inset = detailInset
        let width = max(0, rect.width - inset * 2)
        let top = SkillsStyle.topInset
        let toggle = ShellToggle.size
        // 状态在标题下方，窄栏再独占一行，不挤压名称。
        let narrow = width < 380
        let extra: CGFloat = narrow ? 26 : 0
        detailTitle.frame = NSRect(x: inset, y: top, width: width, height: 28)
        metaLabel.frame = NSRect(x: inset, y: top + 34, width: narrow ? width : max(0, width - 154), height: 18)
        let stateTop = top + 34 + extra
        enableToggle.frame = NSRect(x: rect.width - inset - toggle.width, y: stateTop,
                                    width: toggle.width, height: toggle.height)
        stateLabel.frame = NSRect(x: rect.width - inset - toggle.width - 116,
                                  y: stateTop + 1, width: 108, height: 18)
        noteLabel.frame = NSRect(x: inset, y: top + 58 + extra, width: width, height: 36)
        openButton.frame = NSRect(x: inset, y: top + 100 + extra, width: 100, height: 28)
        revealButton.frame = NSRect(x: inset + 108, y: top + 100 + extra, width: 28, height: 28)
        copyButton.frame = NSRect(x: inset + 144, y: top + 100 + extra, width: 28, height: 28)
        pathScroll.frame = NSRect(x: inset, y: top + 136 + extra, width: width, height: pathScroll.preferredHeight)
        let documentTop = pathScroll.frame.maxY + 12
        documentLabel.frame = NSRect(x: inset, y: documentTop + 5, width: max(0, width - 80), height: 18)
        rawButton.frame = NSRect(x: rect.width - inset - 68, y: documentTop, width: 68, height: 28)
        let bodyTop = documentTop + 36
        bodyScroll.frame = NSRect(x: inset, y: bodyTop, width: width,
                                  height: max(0, rect.height - bodyTop - SkillsStyle.inset))
    }

    // MARK: - 插件自己的事

    private func key(for plugin: PluginRecord) -> String { "plugin:\(plugin.id)" }


    private func identifier(forKey key: String) -> String? {
        key.hasPrefix("plugin:") ? String(key.dropFirst("plugin:".count)) : nil
    }

    private func selectFirstAvailablePlugin() {
        guard let first = snapshot.plugins.first else {
            resetSelection(to: "")
            return
        }
        resetSelection(to: key(for: first))
    }

    func kindTitle(_ kind: PluginContentKind) -> String {
        switch kind {
        case .skill: return localize("Skill")
        case .command: return localize("Command")
        case .agent: return localize("Subagent")
        case .hook: return localize("Hook")
        case .mcpServer: return localize("MCP server")
        case .appConnector: return localize("App connector")
        }
    }

    /// 组标题用复数：它领起的是一组，不是一条。
    private func kindGroupTitle(_ kind: PluginContentKind) -> String {
        switch kind {
        case .skill: return localize("Skills")
        case .command: return localize("Commands")
        case .agent: return localize("Subagents")
        case .hook: return localize("Hooks")
        case .mcpServer: return localize("MCP servers")
        case .appConnector: return localize("App connectors")
        }
    }

    private func stateTitle(_ state: PluginState) -> String {
        switch state {
        case .enabled: return localize("Enabled")
        case .disabled: return localize("Disabled")
        case .cachedOnly: return localize("Cached only")
        }
    }

    /// 进程内按配置根留一份上次的结果。设置页每次打开都新建本视图，没有这份就每次从空白等起。
    private static var lastSnapshots: [String: PluginCatalogSnapshot] = [:]

    @objc func refresh() {
        guard !loading else { return }
        loading = true
        refreshButton.isEnabled = false
        refreshButton.isRefreshing = true
        let catalog = self.catalog
        let previous = snapshot
        // 目录树可能在慢盘上；扫描绝不占住 AppKit 主线程。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // 本地文件几十毫秒读完，app-server 冷启动第一问要两秒多：先照上次的清单摆出来，
            // 再等 Codex 校正，不让整页陪着空等。
            let quick = catalog.scan(previous: previous, queryCodex: false)
            DispatchQueue.main.async { [weak self] in self?.replaceSnapshot(quick) }
            let result = catalog.scan(previous: quick)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.loading = false
                self.refreshButton.isEnabled = true
                self.refreshButton.isRefreshing = false
                self.replaceSnapshot(result)
            }
        }
    }

    func replaceSnapshot(_ value: PluginCatalogSnapshot) {
        Self.lastSnapshots[catalog.cacheKey] = value
        // 两段扫描多数时候结果一样，没变就不重载，免得表格闪一下。
        guard value.plugins != snapshot.plugins || value.warnings != snapshot.warnings
                || value.codexQueryFailed != snapshot.codexQueryFailed else {
            snapshot = value
            return
        }
        snapshot = value
        if selectedPlugin == nil { selectFirstAvailablePlugin() }
        reloadNavigation()
        reloadList()
    }

    func selectPlugin(_ id: String) {
        guard let plugin = snapshot.plugins.first(where: { $0.id == id }) else { return }
        selectNavigation(key: key(for: plugin))
    }

    private func updateDetail() {
        let plugin = selectedPlugin
        let item = selectedContent
        for view in [detailTitle, metaLabel, stateLabel, openButton,
                     revealButton, copyButton, pathScroll] {
            view.isHidden = plugin == nil
        }
        enableToggle.isHidden = plugin == nil || plugin?.canToggle != true || (plugin?.agent == .codex && snapshot.codexQueryFailed)
        noteLabel.isHidden = plugin == nil
        for view in [documentLabel, rawButton, bodyScroll] {
            view.isHidden = item == nil
        }
        guard let plugin else {
            paths.string = ""
            body.string = ""
            renderedID = nil
            return
        }
        detailTitle.stringValue = plugin.name
        detailTitle.toolTip = plugin.identifier
        // 用量只有 Claude Code 记；Codex 侧没有这份数据，就什么都不说，
        // 而不是让它显示成「从没用过」。
        let usage = plugin.agent == .claudeCode
            ? plugin.usage?.summary(localize: localize)
            : nil
        let meta = ([plugin.version, plugin.marketplace, plugin.agent.title, usage].compactMap { $0 })
            .filter { !$0.isEmpty }.joined(separator: " · ")
        metaLabel.stringValue = meta
        metaLabel.toolTip = meta
        stateLabel.stringValue = stateTitle(plugin.state)
        if enableToggle.isOn != (plugin.state == .enabled) { enableToggle.isOn = plugin.state == .enabled }
        let note = actionError ?? plugin.issue
            ?? (plugin.state == .cachedOnly
                ? localize("Cached in Codex but not in its installed list, so it cannot be enabled here.")
                : nil)
            ?? plugin.versionNote.map(localize)
        // 有一句话介绍就用它（与 Codex app 一致），长描述留给 tooltip。
        noteLabel.stringValue = note ?? (plugin.tagline.isEmpty ? plugin.summary : plugin.tagline)
        noteLabel.toolTip = note ?? (plugin.summary.isEmpty ? plugin.tagline : plugin.summary)
        var seen: Set<String> = []
        let locations = ((item?.locations.map(\.path) ?? []) + plugin.roots.map(\.path))
            .filter { seen.insert($0).inserted }
        let pathText = locations.joined(separator: "\n")
        if paths.string != pathText {
            paths.string = pathText
            paths.scrollToBeginningOfDocument(nil)
            pathScroll.refreshSummary()
        }
        let target = item?.fileURL ?? plugin.root
        openButton.isEnabled = target.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        revealButton.isEnabled = openButton.isEnabled
        copyButton.isEnabled = target != nil
        guard let item else {
            // 没有选中条目时正文必须空掉：留着上一条的内容就是在展示过期文档。
            body.string = ""
            renderedID = nil
            return
        }
        documentLabel.stringValue = "\(kindTitle(item.kind)) · \(item.name)"
        documentLabel.toolTip = item.fileURL.path
        rawButton.isHidden = !item.isMarkdown
        updateDocument()
    }

    private func updateDocument(force: Bool = false) {
        guard let item = selectedContent else { return }
        // JSON 片段没有「预览」可言，一律按原文等宽显示。
        let raw = item.isMarkdown ? rawDocument : true
        let changed = renderedID != item.id || renderedRaw != raw
        guard force || changed else { return }
        let selection = body.selectedRange()
        let scrollOrigin = bodyScroll.contentView.bounds.origin
        body.textStorage?.setAttributedString(SkillDocumentPresentation.text(item.content, raw: raw, hidesFrontmatter: true))
        if changed {
            body.setSelectedRange(NSRange(location: 0, length: 0))
            body.scrollToBeginningOfDocument(nil)
        } else {
            body.setSelectedRange(selection)
            bodyScroll.contentView.scroll(to: scrollOrigin)
            bodyScroll.reflectScrolledClipView(bodyScroll.contentView)
        }
        renderedID = item.id
        renderedRaw = raw
        rawButton.label = rawDocument ? localize("Preview") : localize("Source")
    }

    func refreshLocalization() {
        pathScroll.title = localize("File locations")
        openButton.label = localize("Open file")
        rawButton.label = rawDocument ? localize("Preview") : localize("Source")
        applyChromeText()
        for (button, key) in [(refreshButton, "Refresh plugins"), (revealButton, "Reveal in Finder"),
                              (copyButton, "Copy file path")] {
            button.toolTip = localize(key)
            button.setAccessibilityLabel(localize(key))
        }
        enableToggle.setAccessibilityLabel(localize("Enable plugin"))
        reloadNavigation()
        reloadList()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateDocument(force: true)
    }

    // MARK: - 启停

    func setEnabled(_ value: Bool) {
        guard let plugin = selectedPlugin else { return }
        guard plugin.agent != .codex || !snapshot.codexQueryFailed else { return }
        do {
            try catalog.setEnabled(value, for: plugin)
            actionError = nil
            // 写成功了才改本地状态，失败时界面不会显示一个没落盘的开关。
            if let index = snapshot.plugins.firstIndex(where: { $0.id == plugin.id }) {
                let updated = plugin.withState(value ? .enabled : .disabled)
                snapshot.plugins[index] = updated
            }
            // 缓存的清单也跟着改，下次先摆出来的开关才不是写入前的旧状态。
            if let index = snapshot.codexInventory?.entries.firstIndex(where: { $0.pluginId == plugin.identifier }) {
                snapshot.codexInventory?.entries[index].enabled = value
            }
            Self.lastSnapshots[catalog.cacheKey] = snapshot
            reloadNavigation()
            updateDetail()
        } catch {
            if enableToggle.isOn != (plugin.state == .enabled) { enableToggle.isOn = plugin.state == .enabled }
            report(error.localizedDescription)
        }
    }

    @objc private func toggleRaw() {
        rawDocument.toggle()
        updateDocument()
    }

    private var actionTarget: URL? { selectedContent?.fileURL ?? selectedPlugin?.root }

    @objc private func openFile() {
        guard let url = actionTarget else { return }
        if !NSWorkspace.shared.open(url) { report(localize("The plugin file could not be opened.")) }
    }

    @objc private func revealFile() {
        guard let url = actionTarget else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func copyPath() {
        guard let url = actionTarget else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    // MARK: - 提示

    var diagnostics: [String] {
        snapshot.warnings + [actionError].compactMap { $0 }
            + snapshot.plugins.compactMap { plugin in plugin.issue.map { "\(plugin.identifier): \($0)" } }
            + snapshot.plugins.flatMap { plugin in
                plugin.contents.compactMap { item in item.issue.map { "\(plugin.identifier) / \(item.name): \($0)" } }
            }
    }

    private func updateDiagnostics() {
        setFooter(String(format: localize("%d notices"), diagnostics.count),
                  tooltip: diagnostics.joined(separator: "\n"),
                  target: self, action: #selector(showDiagnostics), hidden: diagnostics.isEmpty)
    }

    private func report(_ message: String) {
        actionError = message
        updateDiagnostics()
        updateDetail()
        showDiagnostics()
    }

    @objc private func showDiagnostics() {
        let alert = NSAlert()
        alert.messageText = localize("Plugin notices")
        alert.informativeText = diagnostics.joined(separator: "\n\n")
        if let window { alert.beginSheetModal(for: window) }
    }
}

private extension PluginRecord {
    /// 复制后只改状态；逐个字段重建会漏掉带默认值的字段（使用次数、一句话介绍）。
    func withState(_ state: PluginState) -> PluginRecord {
        var copy = self
        copy.state = state
        return copy
    }
}
