import AppKit
import LighttyCore

/// 应用设置页：整窗覆盖的一页（ChatGPT / Codex 桌面版式），不是独立窗口。
/// 左栏：返回 / 搜索 / 分组导航；右侧：当前页内容。红绿灯仍在左上（页面垫在
/// 标题栏容器之下）。Esc 或「返回应用」关闭。
final class SettingsView: NSView, NSTextFieldDelegate {
    enum Page: String, CaseIterable {
        // archive 是数据清理性质的页面，留在最后；handoff 与 appearance 同属功能域。
        case general, appearance, handoff, archive

        var title: String {
            switch self {
            case .general: return L("General")
            case .appearance: return L("Appearance")
            case .handoff: return L("Handoff")
            case .archive: return L("Archive")
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .appearance: return "sun.max"
            case .handoff: return "doc.text"
            case .archive: return "archivebox"
            }
        }
    }

    static let sidebarWidth: CGFloat = 240

    var onDismiss: (() -> Void)?
    var onShowHookSetup: (() -> Void)?
    private(set) var currentPage: Page

    private let sidebar = ShellBackdropView(fill: ShellStyle.sidebarBackground)
    private let contentArea = ShellBackdropView(fill: ShellStyle.raisedSurface)
    private let backRow = SettingsNavRow(symbol: "arrow.left", title: L("Back to app"))
    private let searchField = NSSearchField()
    private let navStack = NSStackView()
    private let pageHost = NSView()
    private var navRows: [Page: SettingsNavRow] = [:]
    private let emptyLabel = NSTextField(labelWithString: L("No matching settings"))
    private var agentCommandFields: [LaunchAgent: NSTextField] = [:]
    private var agentCommandPreview: NSTextField?

    init(page: Page = .appearance) {
        currentPage = page
        super.init(frame: .zero)
        wantsLayer = true
        build()
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesDidChange),
            name: .lighttyPreferencesDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var acceptsFirstResponder: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }

    // 页面盖住终端：点击空白处不能漏到下层
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    // MARK: - 骨架

    private func build() {
        for v in [sidebar, contentArea, backRow, searchField, navStack, emptyLabel, pageHost] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(sidebar)
        addSubview(contentArea)
        sidebar.addSubview(backRow)
        sidebar.addSubview(searchField)
        sidebar.addSubview(navStack)
        sidebar.addSubview(emptyLabel)
        contentArea.addSubview(pageHost)

        backRow.onClick = { [weak self] in self?.onDismiss?() }

        ShellTextFieldStyle.configure(
            searchField, font: .systemFont(ofSize: 12.5), placeholder: L("Search settings…"))
        searchField.controlSize = .regular
        searchField.target = self
        searchField.action = #selector(searchChanged)
        (searchField.cell as? NSSearchFieldCell)?.sendsSearchStringImmediately = true

        navStack.orientation = .vertical
        navStack.alignment = .leading
        navStack.spacing = 2

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = ShellStyle.tertiaryText
        emptyLabel.isHidden = true

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),

            contentArea.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            contentArea.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentArea.topAnchor.constraint(equalTo: topAnchor),
            contentArea.bottomAnchor.constraint(equalTo: bottomAnchor),

            // 红绿灯行（中线距顶 26）之下
            backRow.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 48),
            backRow.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            backRow.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            backRow.heightAnchor.constraint(equalToConstant: 30),

            searchField.topAnchor.constraint(equalTo: backRow.bottomAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),

            navStack.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 22),
            navStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            navStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),

            emptyLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 26),
            emptyLabel.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 22),

            pageHost.topAnchor.constraint(equalTo: contentArea.topAnchor),
            pageHost.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
            pageHost.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            pageHost.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
        ])
        rebuildNav()
        showPage(currentPage)
    }

    /// 语言切换后整页文案重建（导航 + 当前页），选中页保持；重点色变了只重画当前页。
    @objc private func preferencesDidChange(_ note: Notification) {
        switch PreferenceKind.from(note) {
        case .accent, .terminalTheme:
            showPage(currentPage)
            return
        case .language:
            break
        default:
            return
        }
        backRow.title = L("Back to app")
        searchField.placeholderString = L("Search settings…")
        emptyLabel.stringValue = L("No matching settings")
        rebuildNav()
        showPage(currentPage)
    }

    // MARK: - 左栏导航

    private func rebuildNav() {
        navStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        navRows.removeAll()

        let header = NSTextField(labelWithString: L("Personal"))
        header.font = .systemFont(ofSize: 11.5, weight: .medium)
        header.textColor = ShellStyle.tertiaryText
        navStack.addArrangedSubview(header)
        navStack.setCustomSpacing(6, after: header)
        header.leadingAnchor.constraint(equalTo: navStack.leadingAnchor, constant: 12).isActive = true

        for page in Page.allCases {
            let row = SettingsNavRow(symbol: page.symbol, title: page.title)
            row.selectable = true
            row.isSelected = page == currentPage
            row.onClick = { [weak self] in self?.showPage(page) }
            navStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: navStack.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: 30).isActive = true
            navRows[page] = row
        }
        applySearchFilter()
    }

    @objc private func searchChanged() {
        applySearchFilter()
    }

    private func applySearchFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        var anyVisible = false
        for (page, row) in navRows {
            let match = query.isEmpty
                || page.title.localizedCaseInsensitiveContains(query)
                || page.rawValue.localizedCaseInsensitiveContains(query)
            row.isHidden = !match
            anyVisible = anyVisible || match
        }
        navStack.arrangedSubviews.first?.isHidden = !anyVisible
        emptyLabel.isHidden = anyVisible
    }

    // MARK: - 右侧页面

    func showPage(_ page: Page) {
        currentPage = page
        for (p, row) in navRows { row.isSelected = p == page }
        pageHost.subviews.forEach { $0.removeFromSuperview() }
        agentCommandFields.removeAll()
        agentCommandPreview = nil

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        column.setHuggingPriority(.init(1), for: .horizontal)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = SettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        pageHost.addSubview(scroll)
        document.addSubview(column)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: pageHost.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: pageHost.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: pageHost.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: pageHost.trailingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.bottomAnchor.constraint(equalTo: column.bottomAnchor, constant: 32),
        ])
        // 内容列：在内容区里居中，宽 = 区宽 − 112 且 ≤ 720（参考 ChatGPT：宽窗口时
        // 内容居中封顶，不贴任何一边）；窗口窄时留白退到 24，再压内容宽。
        let centered = column.centerXAnchor.constraint(equalTo: document.centerXAnchor)
        centered.priority = .init(800)
        let fill = column.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -112)
        fill.priority = .init(750)
        let minWidth = column.widthAnchor.constraint(greaterThanOrEqualToConstant: 300)
        minWidth.priority = .init(900)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: document.topAnchor, constant: 64),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: 24),
            column.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -24),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
            centered, fill, minWidth,
        ])

        let title = NSTextField(labelWithString: page.title)
        title.font = .systemFont(ofSize: 24, weight: .medium)
        title.textColor = ShellStyle.primaryText
        column.addArrangedSubview(title)
        column.setCustomSpacing(40, after: title)

        switch page {
        case .general: buildGeneral(into: column)
        case .appearance: buildAppearance(into: column)
        case .handoff: buildHandoff(into: column)
        case .archive:
            if let store = AppState.shared?.taskStore {
                let archive = ArchivedTasksView(store: store)
                column.addArrangedSubview(archive)
                archive.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            }
        }
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = ShellStyle.primaryText
        return label
    }

    // —— General ——

    private func buildGeneral(into column: NSStackView) {
        let group = SettingsGroup()
        // 自绘下拉（ShellDropdown）：颜色走 ShellStyle，靠行右端、只占自身宽度
        let dropdown = ShellDropdown(
            options: LanguagePreference.allCases.map {
                ShellDropdown.Option(id: $0.rawValue, title: $0.title)
            },
            selectedID: LanguagePreference.current().rawValue)
        dropdown.onChange = { id in
            if let option = LanguagePreference(rawValue: id) { LanguagePreference.set(option) }
        }
        group.addRow(title: L("Language"), control: dropdown)
        column.addArrangedSubview(group)
        group.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        column.setCustomSpacing(12, after: group)

        let hint = NSTextField(wrappingLabelWithString:
            L("Language changes apply to menus and sidebars right away; a few labels refresh after relaunch."))
        hint.font = .systemFont(ofSize: 11.5)
        hint.textColor = ShellStyle.tertiaryText
        column.addArrangedSubview(hint)
        hint.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        column.setCustomSpacing(28, after: hint)

        let hooksGroup = SettingsGroup()
        let hooksButton = NSButton(title: L("Manage…"), target: self,
                                   action: #selector(showHookSetup))
        hooksButton.bezelStyle = .rounded
        hooksButton.font = .systemFont(ofSize: 12)
        hooksGroup.addRow(title: L("Agent status hooks"), control: hooksButton)
        column.addArrangedSubview(hooksGroup)
        hooksGroup.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        column.setCustomSpacing(28, after: hooksGroup)
        column.addArrangedSubview(sectionLabel("Agent"))
        column.setCustomSpacing(12, after: column.arrangedSubviews.last!)
        let agents = SettingsGroup()
        let defaultAgent = ShellDropdown(
            options: LaunchAgent.allCases.map { .init(id: $0.rawValue, title: $0.title) },
            selectedID: AgentLaunchPreference.selected().rawValue)
        defaultAgent.onChange = { id in
            if let agent = LaunchAgent(rawValue: id) { AgentLaunchPreference.select(agent) }
        }
        agents.addRow(title: L("Default Agent"), control: defaultAgent)
        // 一个开关管所有 Agent：用户表达的是「跳过权限确认」这个意图，
        // 翻译成 --permission-mode bypassPermissions / --yolo 是 lightty 的事。
        let bypass = ShellToggle(isOn: AgentLaunchPreference.bypassEnabled())
        bypass.onChange = { [weak self] enabled in
            AgentLaunchPreference.setBypass(enabled)
            self?.refreshAgentCommandPreview()
        }
        bypass.setAccessibilityLabel(L("Bypass mode (skip permission prompts)"))
        agents.addRow(title: L("Bypass mode (skip permission prompts)"), control: bypass)
        for agent in [LaunchAgent.claudeCode, .codex] {
            let field = NSTextField(string: AgentLaunchPreference.customArguments(for: agent))
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.placeholderString = L("None")
            field.delegate = self
            field.setAccessibilityLabel(L("%@ extra arguments", agent.title))
            // 套进 ShellFieldBox：这两个框原来是彻底原生的——系统凹槽加系统焦点环，
            // 深色下就是一圈浅边配近黑底，和同一张卡片里其他控件完全两种语言。
            // 系统焦点环还跟着用户的系统强调色走，与「重点色只从 ShellStyle.accent
            // 取」那条相冲。
            let box = ShellFieldBox(field)
            box.widthAnchor.constraint(equalToConstant: 200).isActive = true
            agentCommandFields[agent] = field
            agents.addRow(title: L("%@ extra arguments", agent.title), control: box)
        }
        column.addArrangedSubview(agents)
        agents.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        column.setCustomSpacing(12, after: agents)
        let reset = NSButton(title: L("Reset Agent options"), target: self,
                             action: #selector(resetAgentCommands))
        reset.bezelStyle = .rounded
        column.addArrangedSubview(reset)
        // 参数框只说「加什么」，拼出来的整行在这里给出——开关翻译成哪个参数一看就知道。
        column.setCustomSpacing(18, after: reset)
        column.addArrangedSubview(sectionLabel(L("Launch command")))
        column.setCustomSpacing(8, after: column.arrangedSubviews.last!)
        let preview = NSTextField(wrappingLabelWithString: "")
        preview.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        preview.textColor = ShellStyle.secondaryText
        agentCommandPreview = preview
        refreshAgentCommandPreview()
        column.addArrangedSubview(preview)
        preview.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        let commandHint = NSTextField(wrappingLabelWithString:
            L("This command runs in the new terminal’s shell; resuming a session reuses the same options."))
        commandHint.font = .systemFont(ofSize: 11.5)
        commandHint.textColor = ShellStyle.tertiaryText
        column.setCustomSpacing(8, after: preview)
        column.addArrangedSubview(commandHint)
        commandHint.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }

    private func refreshAgentCommandPreview() {
        // 等宽字体下按最长的标题补齐，两行命令左端对齐。
        let width = [LaunchAgent.claudeCode, .codex].map(\.title.count).max() ?? 0
        agentCommandPreview?.stringValue = [LaunchAgent.claudeCode, .codex]
            .map { "\($0.title.padding(toLength: width, withPad: " ", startingAt: 0))   \(AgentLaunchPreference.command(for: $0))" }
            .joined(separator: "\n")
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let agent = agentCommandFields.first(where: { $0.value === field })?.key else { return }
        if !AgentLaunchPreference.setCustomArguments(field.stringValue, for: agent) { NSSound.beep() }
        field.stringValue = AgentLaunchPreference.customArguments(for: agent)
        refreshAgentCommandPreview()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let agent = agentCommandFields.first(where: { $0.value === field })?.key else { return }
        AgentLaunchPreference.setCustomArguments(field.stringValue, for: agent)
        refreshAgentCommandPreview()
    }

    @objc private func resetAgentCommands() {
        window?.makeFirstResponder(self)
        AgentLaunchPreference.reset()
        showPage(currentPage)
    }

    @objc private func showHookSetup() { onShowHookSetup?() }

    // —— Appearance ——

    private func buildAppearance(into column: NSStackView) {
        column.addArrangedSubview(sectionLabel(L("Theme")))
        column.setCustomSpacing(14, after: column.arrangedSubviews.last!)

        let cards = NSStackView()
        cards.orientation = .horizontal
        cards.alignment = .top
        cards.spacing = 16
        cards.distribution = .fillEqually
        cards.setHuggingPriority(.init(1), for: .horizontal)
        let current = AppearancePreference.current()
        for option in AppearancePreference.allCases {
            let card = ThemeOptionView(option: option)
            card.isSelected = option == current
            card.onSelect = { [weak self] in self?.selectAppearance(option) }
            cards.addArrangedSubview(card)
        }
        column.addArrangedSubview(cards)
        cards.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        column.setCustomSpacing(20, after: cards)

        // 重点色：命名色下拉（行首色点 + 尾部勾选，ChatGPT 桌面版式）
        let accentGroup = SettingsGroup()
        let accentDropdown = ShellDropdown(
            options: AccentPreference.allCases.map {
                ShellDropdown.Option(id: $0.rawValue, title: $0.title, swatch: $0.swatch)
            },
            selectedID: AccentPreference.current().rawValue)
        accentDropdown.onChange = { id in
            if let option = AccentPreference(rawValue: id) { AccentPreference.set(option) }
        }
        accentGroup.addRow(title: L("Accent"), control: accentDropdown)
        let toggle = ShellToggle(isOn: TerminalThemePreference.usesBuiltInTheme())
        toggle.onChange = { on in
            TerminalThemePreference.setUsesBuiltInTheme(on)
            GhosttyRuntime.shared.reloadGlobalConfig()
            PreferenceKind.terminalTheme.post()
        }
        accentGroup.addRow(title: L("Use the built-in Lightty terminal configuration"), control: toggle)
        column.addArrangedSubview(accentGroup)
        accentGroup.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }

    private func selectAppearance(_ option: AppearancePreference) {
        AppearancePreference.set(option)
        showPage(.appearance)
    }

    // —— Handoff ——

    /// 交接协议展示页：**只读**。
    ///
    /// 这一栏回答的是「lightty 到底替我对 Agent 说了什么、什么时候说」——在此之前
    /// 这是用户唯一碰不到也看不到的东西。这一版不放开自定义，所以页面上没有任何
    /// 可编辑控件；等真要开放时，改的是这里的控件，文本来源不变。
    ///
    /// 全部文本取自 `HandoffProtocol`，不另存副本：副本迟早跟真正注入的对不上，
    /// 而「用户照着设置页读、Agent 收到的却是别的」是最难被发现的一种不一致。
    private func buildHandoff(into column: NSStackView) {
        addWide(hintLabel(L("This is what lightty says to the Agent when a terminal has a task bound. It is fixed in this version.")), to: column)
        column.setCustomSpacing(28, after: column.arrangedSubviews.last!)

        let path = Self.sampleTaskPath
        addSection(L("Injected at session start"),
                   hint: L("Sent once when a session starts in a terminal that already has a task bound."),
                   body: HandoffProtocol.injection(path: path, body: Self.sampleTaskFile, lateBinding: false),
                   to: column)

        // 中途绑定那版与开场版只有开头不同，后面逐字相同。整段再贴一次，这一页就要
        // 多滚一屏读同样的字，用户会以为自己滚回去了——只展示不同的那一段。
        addSection(L("Injected when a task is bound later"),
                   hint: L("Sent with the next message after a task is bound, rebound, or renamed."),
                   body: HandoffProtocol.injection(path: path, body: Self.sampleTaskFile,
                                                   lateBinding: true),
                   to: column)

        buildHandoffSkill(path: path, into: column)

        addSection(L("Typed in when the plugin is not installed"),
                   hint: L("The button falls back to this. It carries the whole contract on its own, so it works without the plugin and without the session-start text."),
                   body: HandoffProtocol.directInstruction(path: path),
                   to: column)

        column.addArrangedSubview(sectionLabel(L("When lightty injects")))
        column.setCustomSpacing(10, after: column.arrangedSubviews.last!)
        for line in [
            L("Session start: injected whenever the terminal has a task bound."),
            L("Later binding or rename: injected again only when the session or the file path changed."),
            L("Unbinding: nothing is injected, and the next binding starts fresh."),
        ] {
            addWide(hintLabel(line), to: column)
            column.setCustomSpacing(6, after: column.arrangedSubviews.last!)
        }
    }

    /// 技能一节。调用写法两家不一样，且都按插件名加前缀——这是页面上唯一「照着敲」
    /// 的内容，所以单独成行、可选中，不埋在正文里。
    ///
    /// 装没装是**查出来的**，不是断言。这一栏的自陈目的就是「告诉用户 lightty 到底
    /// 做了什么」，而技能没装时敲下去是静默失败（两家都不报错），在这点上写一句
    /// 「已随插件安装」等于骗人。
    private func buildHandoffSkill(path: String, into column: NSStackView) {
        column.addArrangedSubview(sectionLabel(L("Skill")))
        column.setCustomSpacing(12, after: column.arrangedSubviews.last!)
        let invocations = SettingsGroup()
        // 名字取自 LaunchAgent.title，不在这里重打一遍："Claude Code" 这类产品名
        // 已经有主了，抄一份迟早两处对不上。
        // 展示的是**裸写法**，不带路径：用户手敲不需要背一长串路径，技能自己会去
        // `~/.lightty/panes/$LIGHTTY_PANE_ID/task` 找回来。按钮发的那一份是带路径的
        // （见 `AgentCommand.handoff`），那是内部形式，不该摆在"你该输入什么"这里。
        let agents: [(SessionAgent, LaunchAgent)] = [(.claude, .claudeCode), (.codex, .codex)]
        var unavailable: [String] = []
        for (agent, launch) in agents {
            let value = NSTextField(labelWithString:
                HandoffProtocol.skillInvocation(agent: agent, plugin: HookMarketplace.pluginName,
                                                path: nil))
            value.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            value.textColor = ShellStyle.secondaryText
            value.isSelectable = true
            invocations.addRow(title: launch.title, control: value)
            if !HookInstaller.handoffSkillAvailable(for: agent) { unavailable.append(launch.title) }
        }
        addWide(invocations, to: column)
        column.setCustomSpacing(12, after: invocations)
        addWide(hintLabel(L("Typing the invocation runs it; the Agent can also reach it when you ask in your own words. Append what the next session should focus on to tailor the document to it.")), to: column)
        column.setCustomSpacing(6, after: column.arrangedSubviews.last!)
        // 一家一行，不拼成一句：拼接要一个分隔符，而中英的分隔符不一样，
        // 为两家 agent 引进一个"顿号 / 逗号"的本地化键不划算。
        for name in unavailable {
            addWide(hintLabel(L("%@ cannot run it yet. Install or update the lightty plugin under General, Agent status hooks, Manage….", name)), to: column)
            column.setCustomSpacing(6, after: column.arrangedSubviews.last!)
        }
        column.setCustomSpacing(12, after: column.arrangedSubviews.last!)
        addWide(protocolBlock(HandoffProtocol.skillDocument), to: column)
        column.setCustomSpacing(32, after: column.arrangedSubviews.last!)
    }

    /// 一节 = 标题 + 说明 + 协议原文（+ 可选的收尾说明）。几处结构一样，抽出来
    /// 免得间距各写各的。
    private func addSection(_ title: String, hint: String, body: String, to column: NSStackView) {
        column.addArrangedSubview(sectionLabel(title))
        column.setCustomSpacing(8, after: column.arrangedSubviews.last!)
        addWide(hintLabel(hint), to: column)
        column.setCustomSpacing(12, after: column.arrangedSubviews.last!)
        addWide(protocolBlock(body), to: column)
        column.setCustomSpacing(32, after: column.arrangedSubviews.last!)
    }

    /// 列里的每个子视图都要显式占满列宽：列是 `.leading` 对齐且贴合内容，
    /// 不给约束的话长文本会把列撑到窗口外。
    private func addWide(_ view: NSView, to column: NSStackView) {
        column.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }

    private func hintLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = ShellStyle.tertiaryText
        return label
    }

    /// 协议原文：等宽、可选中、**不走本地化**——它是跨会话的数据格式协议，
    /// 固定英文（同 `Localization.swift` 的边界说明）。
    ///
    /// 套一层与 `SettingsGroup` 同源的容器：这一页的等宽正文有几十行，裸铺在页面
    /// 背景上分不清哪儿是一块的起止。本页确有裸等宽的先例（启动命令预览），但那是
    /// 两行。
    private func protocolBlock(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        label.textColor = ShellStyle.secondaryText
        return ProtocolBlockView(label)
    }

    /// 路径用**占位符**而不是一条像模像样的假路径。这一处是 lightty 运行时替换的
    /// 槽位，写成 `/Users/me/.lightty/tasks/Rewrite the launch composer.md` 会让人
    /// 分不清那是示例还是真会出现的字面量——尖括号一眼就是占位。
    ///
    /// 与下面的 `sampleTaskFile` 是两回事，两者刻意不同口径：那份是**用户文件的
    /// 内容**，拿真实感的样例数据演示格式才有用；这一处是我们要填的槽。
    private static let sampleTaskPath = "<task file path>"

    /// 注入的是任务文件**全文**（含 frontmatter）——「只重写结束 `---` 之后」那条
    /// 指令得让 Agent 对着实物看，所以示意值也带上 frontmatter。`sessions` 要出现：
    /// 它是唯一的多行键，也正是「别的 frontmatter 键一个都别动」最容易被违反的地方。
    private static let sampleTaskFile = """
        ---
        name: Rewrite the launch composer
        status: active
        workdir: /Users/me/project/app
        tool: claude
        created: 2026-09-01T09:00:00Z
        updated: 2026-09-08T17:20:00Z
        sessions:
          - claude:3551e356-5b15-43d1-86a5-69764b142807
        ---
        ## Next steps
        - …
        """

}

/// 协议原文的容器：与 `SettingsGroup` 同一套外观（圆角 12、1pt 描边、抬升底色），
/// 内边距对齐它的 16。
///
/// 单独一个类型而不是复用 `SettingsGroup`：那个的 `addRow` 是「左标题右控件、
/// 行高至少 48」的布局，几十行等宽正文塞进去会被挤进右侧窄条。这里要的只是它
/// 的外壳。
private final class ProtocolBlockView: NSView {
    init(_ content: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        layer?.backgroundColor = ShellStyle.raisedSurface.shellResolvedCGColor(for: effectiveAppearance)
        layer?.borderColor = ShellStyle.divider.shellResolvedCGColor(for: effectiveAppearance)
    }
}

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - 左栏导航行

/// 图标 + 文字的一行：hover 浅底；选中态 = 选中底 + 主文字色，不描边。
final class SettingsNavRow: NSView {
    var onClick: (() -> Void)?
    var selectable = false
    var isSelected = false { didSet { applyLook() } }
    var title: String {
        didSet { label.stringValue = title }
    }

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { applyLook() } }

    init(symbol: String, title: String) {
        self.title = title
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = ShellStyle.controlCornerRadius
        HoverCursor.installPointingHand(on: self)

        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12.5, weight: .medium))
        label.stringValue = title
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail

        for v in [icon, label] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyLook()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLook()
    }

    private func applyLook() {
        let appearance = effectiveAppearance
        let fill: NSColor = isSelected ? ShellStyle.selectionFill : (hovered ? ShellStyle.hoverFill : .clear)
        layer?.backgroundColor = fill.shellResolvedCGColor(for: appearance)
        let text: NSColor = (isSelected || hovered) ? ShellStyle.primaryText : ShellStyle.secondaryText
        label.textColor = text
        icon.contentTintColor = text
    }
}

// MARK: - 设置分组卡

/// 圆角描边的设置分组：每行 = 左标题 + 右控件，行间细分隔线。
final class SettingsGroup: NSView {
    private let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.setHuggingPriority(.init(1), for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    func addRow(title: String, control: NSView) {
        if !stack.arrangedSubviews.isEmpty {
            let line = ShellBackdropView(fill: ShellStyle.divider)
            stack.addArrangedSubview(line)
            line.heightAnchor.constraint(equalToConstant: 1).isActive = true
            line.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
            line.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 16).isActive = true
        }
        let row = NSView()
        // 标签可折两行：窄窗口下控件保住，标题换行而不是被截断
        let label = NSTextField(wrappingLabelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.textColor = ShellStyle.primaryText
        label.maximumNumberOfLines = 2
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [label, control] {
            v.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(v)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 12),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            // 控件保持自身尺寸靠右，标签占左侧余量（可折行）；不把控件拉伸铺满
            control.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 16),
        ])
        control.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        layer?.backgroundColor = ShellStyle.raisedSurface.shellResolvedCGColor(for: effectiveAppearance)
        layer?.borderColor = ShellStyle.divider.shellResolvedCGColor(for: effectiveAppearance)
    }
}

// MARK: - 主题三选一

/// 一张主题预览卡 + 标题：选中时外圈描边。
final class ThemeOptionView: NSView {
    var onSelect: (() -> Void)?
    var isSelected = false { didSet { preview.isSelected = isSelected; needsDisplay = true } }

    private let preview: ThemePreview
    private let caption = NSTextField(labelWithString: "")

    init(option: AppearancePreference) {
        preview = ThemePreview(option: option)
        super.init(frame: .zero)
        HoverCursor.installPointingHand(on: self)
        caption.stringValue = option.title
        caption.font = .systemFont(ofSize: 12.5)
        caption.textColor = ShellStyle.secondaryText
        caption.alignment = .center
        for v in [preview, caption] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: topAnchor),
            preview.leadingAnchor.constraint(equalTo: leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor),
            preview.heightAnchor.constraint(equalTo: preview.widthAnchor, multiplier: 0.7),
            caption.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 10),
            caption.centerXAnchor.constraint(equalTo: centerXAnchor),
            caption.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onSelect?() }
    }
}

/// 主题缩略图：小窗口示意（侧栏条 + 内容条）。system = 左浅右深对半。
final class ThemePreview: NSView {
    var isSelected = false { didSet { needsDisplay = true } }
    private let option: AppearancePreference

    init(option: AppearancePreference) {
        self.option = option
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private struct Palette {
        let backdrop: NSColor, window: NSColor, bar: NSColor, strongBar: NSColor
        static let light = Palette(
            backdrop: NSColor(srgbRed: 0.949, green: 0.949, blue: 0.949, alpha: 1),
            window: .white,
            bar: NSColor(srgbRed: 0.878, green: 0.878, blue: 0.878, alpha: 1),
            strongBar: NSColor(srgbRed: 0.80, green: 0.80, blue: 0.80, alpha: 1))
        static let dark = Palette(
            backdrop: NSColor(srgbRed: 0.353, green: 0.353, blue: 0.353, alpha: 1),
            window: NSColor(srgbRed: 0.24, green: 0.24, blue: 0.24, alpha: 1),
            bar: NSColor(srgbRed: 0.42, green: 0.42, blue: 0.42, alpha: 1),
            strongBar: NSColor(srgbRed: 0.50, green: 0.50, blue: 0.50, alpha: 1))
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 3, dy: 3)
        let clip = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)

        func paint(_ palette: Palette, in region: NSRect) {
            NSGraphicsContext.saveGraphicsState()
            clip.addClip()
            region.clip()
            palette.backdrop.setFill()
            rect.fill()
            // 顶部两根短条（标题 / 副标题）
            let w = rect.width
            let cx = rect.midX
            palette.strongBar.setFill()
            NSBezierPath(roundedRect: NSRect(x: cx - w * 0.22, y: rect.maxY - rect.height * 0.28,
                                             width: w * 0.44, height: 6), xRadius: 3, yRadius: 3).fill()
            palette.bar.setFill()
            NSBezierPath(roundedRect: NSRect(x: cx - w * 0.32, y: rect.maxY - rect.height * 0.28 - 12,
                                             width: w * 0.64, height: 5), xRadius: 2.5, yRadius: 2.5).fill()
            // 内容窗
            let win = NSRect(x: rect.minX + w * 0.14, y: rect.minY, width: w * 0.72, height: rect.height * 0.58)
            palette.window.setFill()
            NSBezierPath(roundedRect: win, xRadius: 8, yRadius: 8).fill()
            palette.bar.setFill()
            for i in 0..<3 {
                let lineWidth = w * (i == 1 ? 0.36 : 0.26)
                let y = win.maxY - 18 - CGFloat(i) * 15
                NSBezierPath(roundedRect: NSRect(x: win.minX + 14, y: y, width: lineWidth, height: 5),
                             xRadius: 2.5, yRadius: 2.5).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        switch option {
        case .light: paint(.light, in: bounds)
        case .dark: paint(.dark, in: bounds)
        case .system:
            let half = bounds.width / 2
            paint(.light, in: NSRect(x: bounds.minX, y: bounds.minY, width: half, height: bounds.height))
            paint(.dark, in: NSRect(x: bounds.minX + half, y: bounds.minY, width: half, height: bounds.height))
        }

        if isSelected {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
            ring.lineWidth = 2
            ShellStyle.primaryText.setStroke()
            ring.stroke()
        } else {
            let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            edge.lineWidth = 1
            ShellStyle.divider.setStroke()
            edge.stroke()
        }
    }
}
