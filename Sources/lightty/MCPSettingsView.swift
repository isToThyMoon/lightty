import AppKit

/// 独立配置的 MCP server 浏览器。左栏按 Agent 分，中栏列 server，右栏是它的配置原文。
/// 插件自带的 server 不在这里——那些归 Plugins 页，同一台服务器只该有一个去处。
final class MCPSettingsView: ColumnBrowserView {
    private let catalog: MCPCatalog
    private(set) var snapshot: MCPCatalogSnapshot
    private(set) var servers: [MCPServerRecord] = []
    private(set) var loading = false
    private var agent: PluginAgent?
    private var actionError: String?
    private var renderedID: String?

    private let detailTitle = MCPSettingsView.label("", font: SkillsStyle.titleFont)
    private let metaLabel = MCPSettingsView.label("", font: SkillsStyle.summaryFont, secondary: true)
    private let noteLabel = MCPSettingsView.label("", font: SkillsStyle.summaryFont, secondary: true)
    private let stateLabel = MCPSettingsView.label("", font: SkillsStyle.summaryFont, secondary: true)
    private let documentLabel = MCPSettingsView.label("", font: SkillsStyle.sectionFont, secondary: true)
    private let pathScroll = BrowserFileLocationsView()
    private var paths: NSTextView { pathScroll.textView }
    private let bodyScroll = NSTextView.scrollableTextView()
    private var body: NSTextView { bodyScroll.documentView as! NSTextView }
    private lazy var enableToggle = ShellToggle(isOn: false)
    private lazy var openButton = ShellTextButton(localize("Open file"), target: self, action: #selector(openFile))
    private lazy var revealButton = ShellIconButton(symbol: "folder", accessibilityLabel: localize("Reveal in Finder"), target: self, action: #selector(revealFile))
    private lazy var copyButton = ShellIconButton(symbol: "doc.on.doc", accessibilityLabel: localize("Copy file path"), target: self, action: #selector(copyPath))

    init(catalog: MCPCatalog = MCPCatalog(), snapshot: MCPCatalogSnapshot? = nil,
         preferences: PreferenceStorage = FilePreferences.shared,
         localize: @escaping (String) -> String = { L($0) }) {
        self.catalog = catalog
        self.snapshot = snapshot ?? MCPCatalogSnapshot()
        super.init(scope: "settings.mcp", preferences: preferences, localize: localize)
        buildDetail()
        applyChromeText()
        refreshButton.toolTip = localize("Refresh MCP servers")
        resetSelection(to: Self.allKey)
        reloadNavigation()
        reloadList()
        if snapshot == nil { refresh() }
    }

    required init?(coder: NSCoder) { fatalError() }

    var selectedServer: MCPServerRecord? { servers.first { $0.id == selectedListID } }

    private static let allKey = "all"

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
        for view in [detailTitle, metaLabel, noteLabel, stateLabel, enableToggle, openButton,
                     revealButton, copyButton, documentLabel, pathScroll, bodyScroll] {
            detailArea.addSubview(view)
        }
        noteLabel.maximumNumberOfLines = 2
        noteLabel.cell?.wraps = true
        noteLabel.cell?.isScrollable = false
        stateLabel.alignment = .right
        enableToggle.setAccessibilityLabel(localize("Enable MCP server"))
        enableToggle.onChange = { [weak self] value in self?.setEnabled(value) }
        for view in [paths, body] {
            view.isEditable = false
            view.isSelectable = true
            view.drawsBackground = false
            view.font = SkillsStyle.codeFont
            view.textContainerInset = .zero
            view.textContainer?.lineFragmentPadding = 0
        }
        paths.textColor = ShellStyle.secondaryText
        paths.setAccessibilityLabel(localize("File locations"))
        body.identifier = NSUserInterfaceItemIdentifier("mcp-document")
        body.textColor = ShellStyle.primaryText
        body.setAccessibilityLabel(localize("MCP server configuration"))
        for scroll in [bodyScroll] {
            scroll.drawsBackground = false
            scroll.automaticallyAdjustsContentInsets = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
        }
    }

    // MARK: - 骨架要的答案

    override var searchPlaceholder: String { localize("Search MCP servers…") }
    override var navigationAccessibilityLabel: String { localize("MCP server sources") }
    override var listAccessibilityLabel: String { localize("MCP servers") }
    override var detailEmptyText: String { localize("Select a server to see how it is configured.") }
    override var emptyListText: String {
        searchQuery.isEmpty ? localize("No MCP servers configured here.") : localize("No matching servers.")
    }
    override var listHeadingText: String {
        navigation.first { $0.key == selectedKey }?.title ?? localize("MCP servers")
    }

    override func makeNavigation() -> [NavigationItem] {
        var rows: [NavigationItem] = [
            .init(title: localize("All servers"), symbol: "square.grid.2x2",
                  key: Self.allKey, count: snapshot.servers.count),
        ]
        for agent in PluginAgent.allCases {
            rows.append(.init(title: agent.title,
                              key: "agent:\(agent.rawValue)",
                              count: snapshot.servers.filter { $0.agent == agent }.count))
        }
        updateDiagnostics()
        return rows
    }

    override func navigationCell(for item: NavigationItem) -> NSView? {
        guard let key = item.key, key.hasPrefix("agent:"),
              let agent = PluginAgent(rawValue: String(key.dropFirst("agent:".count))) else {
            return super.navigationCell(for: item)
        }
        return ColumnBrowserCell(title: item.title, subtitle: nil, symbol: "",
                                 trailing: String(item.count),
                                 image: AgentSessionIcon.image(for: agent.sessionAgent),
                                 inTree: true)
    }

    override func makeListIDs() -> [String] {
        let query = searchQuery
        servers = snapshot.servers.filter { server in
            (agent == nil || server.agent == agent)
                && (query.isEmpty || [server.name, server.summary, server.transport]
                    .contains { $0.localizedCaseInsensitiveContains(query) })
        }
        return servers.map(\.id)
    }

    override func listCell(for id: String) -> NSView? {
        guard let server = servers.first(where: { $0.id == id }) else { return nil }
        return ColumnBrowserCell(title: server.name, subtitle: server.summary, symbol: "",
                                 trailing: server.enabled ? "" : "○")
    }

    override func didSelectNavigation(key: String) {
        agent = key.hasPrefix("agent:")
            ? PluginAgent(rawValue: String(key.dropFirst("agent:".count))) : nil
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
        documentLabel.frame = NSRect(x: inset, y: documentTop + 5, width: max(0, width - 0), height: 18)
        let bodyTop = documentTop + 36
        bodyScroll.frame = NSRect(x: inset, y: bodyTop, width: width,
                                  height: max(0, rect.height - bodyTop - SkillsStyle.inset))
    }

    // MARK: - server 自己的事

    @objc func refresh() {
        guard !loading else { return }
        loading = true
        refreshButton.isEnabled = false
        refreshButton.isRefreshing = true
        let catalog = self.catalog
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

    func replaceSnapshot(_ value: MCPCatalogSnapshot) {
        snapshot = value
        reloadNavigation()
        reloadList()
    }

    func selectAgent(_ value: PluginAgent?) {
        selectNavigation(key: value.map { "agent:\($0.rawValue)" } ?? Self.allKey)
    }

    private func setEnabled(_ value: Bool) {
        guard let server = selectedServer, server.canToggle, server.enabled != value else { return }
        do {
            try catalog.setEnabled(value, for: server)
            actionError = nil
            // 重扫一遍再画：开关应当反映文件里的状态，而不是刚才点了什么。
            replaceSnapshot(catalog.scan())
        } catch {
            actionError = error.localizedDescription
            enableToggle.isOn = server.enabled
            updateDiagnostics()
            showDiagnostics()
        }
    }

    private func updateDetail() {
        let server = selectedServer
        for view in [detailTitle, metaLabel, noteLabel, stateLabel, enableToggle, openButton,
                     revealButton, copyButton, documentLabel, pathScroll, bodyScroll] {
            view.isHidden = server == nil
        }
        guard let server else { paths.string = ""; body.string = ""; renderedID = nil; return }
        detailTitle.stringValue = server.name
        detailTitle.toolTip = server.name
        metaLabel.stringValue = "\(server.agent.title) · \(server.transport)"
        noteLabel.stringValue = server.toggleNote.map(localize) ?? server.summary
        noteLabel.toolTip = noteLabel.stringValue
        stateLabel.stringValue = server.enabled ? localize("Enabled") : localize("Disabled")
        enableToggle.isOn = server.enabled
        enableToggle.isEnabled = server.canToggle
        enableToggle.toolTip = server.toggleNote.map(localize)
        documentLabel.stringValue = server.sourceURL.lastPathComponent
        if paths.string != server.sourceURL.path {
            paths.string = server.sourceURL.path
            paths.scrollToBeginningOfDocument(nil)
            pathScroll.refreshSummary()
        }
        guard renderedID != server.id else { return }
        renderedID = server.id
        body.string = server.declaration
        body.scrollToBeginningOfDocument(nil)
    }

    func refreshLocalization() {
        pathScroll.title = localize("File locations")
        openButton.label = localize("Open file")
        applyChromeText()
        refreshButton.toolTip = localize("Refresh MCP servers")
        reloadNavigation()
        reloadList()
    }

    @objc private func openFile() {
        guard let url = selectedServer?.sourceURL else { return }
        if !NSWorkspace.shared.open(url) { report(localize("The configuration file could not be opened.")) }
    }

    @objc private func revealFile() {
        guard let url = selectedServer?.sourceURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func copyPath() {
        guard let url = selectedServer?.sourceURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    private var diagnostics: [String] {
        snapshot.warnings + [actionError].compactMap { $0 }
    }

    private func updateDiagnostics() {
        setFooter(String(format: localize("%d notices"), diagnostics.count),
                  tooltip: diagnostics.joined(separator: "\n"),
                  target: self, action: #selector(showDiagnostics), hidden: diagnostics.isEmpty)
    }

    @objc private func showDiagnostics() {
        let alert = NSAlert()
        alert.messageText = localize("MCP notices")
        alert.informativeText = diagnostics.joined(separator: "\n\n")
        if let window { alert.beginSheetModal(for: window) }
    }

    private func report(_ message: String) {
        actionError = message
        updateDiagnostics()
        showDiagnostics()
    }
}
