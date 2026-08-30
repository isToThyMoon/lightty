import AppKit

/// hook 安装引导：窗内蒙层，不是独立窗口。
///
/// 这是**主动弹**的——用户没要求看它，所以默认只给「决定装不装」所需的最少信息：
/// 一句话说明 + 每个 agent 一行 + 一个按钮。路径、事件清单、备份策略、隐私说明
/// 全部收进 Details。
///
/// 早先版本把这些细节全摊在正面，理由是「lightty 要改用户自己的配置文件，藏一点
/// 都会显得可疑」。方向对，做法错了：一墙字本身就可疑，而且没人读。信任来自
/// 「随时能展开看到全部」，不是「一次性糊到脸上」。
///
/// 用蒙层而不是 NSWindow：独立窗口对一次性引导太重（要管层级、聚焦、多窗重复），
/// 而 app 已经有成熟的窗内浮层语言（搜索面板、灵动岛）。
final class HookSetupOverlay: NSView {
    /// 主动弹过一次就不再弹。菜单项是唯一的回头路，文案里必须告诉用户。
    private static let dismissedKey = "lightty.hookSetup.dismissed"

    var onDismiss: (() -> Void)?

    private let card = NSView()
    private let rootStack = NSStackView()
    private let detailsStack = NSStackView()
    private let detailsToggle = NSButton()
    private let helperLabel = NSTextField(wrappingLabelWithString: "")
    private var rows: [HookAgent: AgentRow] = [:]
    private lazy var closeButton = Self.button(
        L("Not now"), emphasis: .primary, target: self, action: #selector(closeTapped))
    private var didInstallSomething = false
    /// 正在跑的行 → 它在跑什么。`reload()` 会重刷所有行，得靠它把进行中的行
    /// 恢复成「安装中…」，否则另一家先完成时会把这一家的按钮打回 Install。
    private var inFlight: [HookAgent: AgentRow.Action] = [:]

    // MARK: - 入口

    /// 菜单项走这里：无条件展示，忽略"已忽略"标记。
    static func present(in controller: TerminalWindowController) {
        controller.presentHookSetup()
    }

    /// 启动后自动调用。只有「装了 agent 却没装 hook」才值得打断——
    /// 没装 agent 的人看到这个只会困惑，装好了的人再看就是纯噪音。
    static func presentIfNeeded(in controller: TerminalWindowController) {
        guard !UserDefaults.standard.bool(forKey: dismissedKey) else { return }
        let worthAsking = HookInstaller.reports().contains { report in
            guard report.isAgentPresent else { return false }
            switch report.state {
            case .notInstalled, .partial: return true
            // unreadable 我们帮不上忙（铁律是绝不覆盖），installed 无事可做
            case .installed, .unreadable, .agentMissing: return false
            }
        }
        guard worthAsking else { return }
        present(in: controller)
    }

    // MARK: - 构建

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        buildCard()
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildCard() {
        card.wantsLayer = true
        addSubview(card)

        let title = NSTextField(labelWithString: L("Know when your agents finish"))
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.textColor = ShellStyle.primaryText

        let subtitle = NSTextField(wrappingLabelWithString: L(
            "lightty ships a small plugin and asks claude/codex to install it with "
            + "their own CLI. lightty never edits your agent config itself."))
        subtitle.font = .systemFont(ofSize: 11.5)
        subtitle.textColor = ShellStyle.secondaryText

        for agent in HookAgent.allCases {
            let row = AgentRow(agent: agent)
            row.onAction = { [weak self] action in self?.perform(action, on: agent) }
            rows[agent] = row
        }

        buildDetails()

        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 8
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(title)
        rootStack.addArrangedSubview(subtitle)
        rootStack.setCustomSpacing(16, after: subtitle)
        for agent in HookAgent.allCases {
            if let row = rows[agent] { rootStack.addArrangedSubview(row) }
        }
        rootStack.setCustomSpacing(14, after: rows[HookAgent.allCases.last!]!)
        rootStack.addArrangedSubview(detailsToggle)
        rootStack.addArrangedSubview(detailsStack)

        let footerHint = NSTextField(wrappingLabelWithString: L(
            "You can reopen this any time from the lightty menu."))
        footerHint.font = .systemFont(ofSize: 10.5)
        footerHint.textColor = ShellStyle.tertiaryText

        // 内容超出可用高度时才滚动（展开 Details 或长本地化文案）。document 必须翻转
        // 坐标系，否则超出视口时 NSScrollView 默认停在**底部**——一打开看到的是末尾。
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rootStack)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document

        for v in [scroll, footerHint, closeButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(v)
        }

        // 约束只到 card 为止：卡片自身 frame 在 layout() 手算，对窗口尺寸零反压
        // （对 themeFrame 建约束会反向驱动窗口大小，平铺 WM 会因此重排——已踩过）
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footerHint.topAnchor, constant: -14),

            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            rootStack.topAnchor.constraint(equalTo: document.topAnchor),
            rootStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 22),
            rootStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -22),
            rootStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),

            footerHint.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            footerHint.trailingAnchor.constraint(
                lessThanOrEqualTo: closeButton.leadingAnchor, constant: -12),
            footerHint.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
            closeButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
        ])
        for view in [title, subtitle, detailsStack] {
            view.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        }
        for row in rows.values {
            row.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        }
    }

    /// 细节区：默认折叠。放的是"想核对的人要看的"——路径、事件清单、备份与隐私。
    private func buildDetails() {
        detailsToggle.setButtonType(.onOff)
        detailsToggle.bezelStyle = .inline
        detailsToggle.isBordered = false
        detailsToggle.title = L("Details")
        detailsToggle.font = .systemFont(ofSize: 11)
        detailsToggle.contentTintColor = ShellStyle.secondaryText
        detailsToggle.image = NSImage(
            systemSymbolName: "chevron.right", accessibilityDescription: nil)
        detailsToggle.alternateImage = NSImage(
            systemSymbolName: "chevron.down", accessibilityDescription: nil)
        detailsToggle.imagePosition = .imageLeading
        detailsToggle.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        detailsToggle.target = self
        detailsToggle.action = #selector(toggleDetails)

        detailsStack.orientation = .vertical
        detailsStack.alignment = .leading
        detailsStack.spacing = 6
        detailsStack.isHidden = true

        detailsStack.addArrangedSubview(Self.caption(L("Plugin source:")))
        detailsStack.addArrangedSubview(Self.mono(Self.abbreviate(HookMarketplace.root.path)))
        detailsStack.addArrangedSubview(Self.caption(L("Registered command:")))
        detailsStack.addArrangedSubview(Self.mono(Self.abbreviate(HookInstaller.shimPath.path)))
        helperLabel.font = .systemFont(ofSize: 10.5)
        helperLabel.textColor = ShellStyle.tertiaryText
        detailsStack.addArrangedSubview(helperLabel)

        // 把**将要执行的命令原样列出来**——这是这套设计最值得展示的一点：
        // 写配置的是它们自己的 CLI，用户能照着自己跑一遍验证，也能自己撤销。
        for agent in HookAgent.allCases {
            let caption = Self.caption(L("%@ · commands lightty will run", agent.displayName))
            detailsStack.addArrangedSubview(caption)
            detailsStack.setCustomSpacing(10, after: detailsStack.arrangedSubviews[
                detailsStack.arrangedSubviews.count - 2])
            let lines = agent.installCommands(
                marketplaceRoot: HookMarketplace.root, isPluginInstalled: false)
                .map { ([agent.executableName] + $0).joined(separator: " ") }
                .joined(separator: "\n")
            detailsStack.addArrangedSubview(Self.mono(Self.abbreviate(lines)))
            detailsStack.addArrangedSubview(Self.caption(agent.events.joined(separator: ", ")))
        }

        let policy = Self.body(L(
            "The plugin is generated under ~/.lightty and registered by your agent’s own "
            + "CLI — lightty does not write your agent config. Uninstall removes it the "
            + "same way. Status files stay under ~/.lightty and are never uploaded."))
        detailsStack.addArrangedSubview(policy)
        detailsStack.setCustomSpacing(12, after: detailsStack.arrangedSubviews[
            detailsStack.arrangedSubviews.count - 2])

        for view in detailsStack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: detailsStack.widthAnchor).isActive = true
        }
    }

    @objc private func toggleDetails() {
        detailsStack.isHidden = detailsToggle.state != .on
        needsLayout = true
    }

    // MARK: - 外观

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // layer 配置延后到挂窗之后：backing layer 会被 AppKit 重建，init 里设的会丢。
        applyColors()
        card.layer?.cornerRadius = 14
        card.layer?.borderWidth = 1
        // 投影用 NSView.shadow（AppKit 维护，layer 重建后自动重涂；
        // 直接写 layer.shadow* 会在挂窗时丢失——搜索浮层已踩过）
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
        shadow.shadowBlurRadius = 52
        shadow.shadowOffset = NSSize(width: 0, height: -14)
        card.shadow = shadow
        window?.makeFirstResponder(self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        // 蒙层压暗底下的终端，把注意力收进卡片；同时它也是"这是模态"的唯一视觉信号
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        card.layer?.backgroundColor =
            ShellStyle.raisedSurface.shellResolvedCGColor(for: effectiveAppearance)
        card.layer?.borderColor = ShellStyle.divider.shellResolvedCGColor(for: effectiveAppearance)
    }

    override func layout() {
        super.layout()
        let w = max(min(bounds.width - 120, 480), 320)
        // 卡片按内容收缩：固定高度会在折叠态留一大片空白，那片空白会让人
        // 以为内容被截断了。
        //
        // **必须先定宽再量高**：卡片宽度 → 滚动区 → rootStack 宽度 → 文本换行 →
        // 内容高度 → 卡片高度，是一条环。宽度没定就量，等于按上一轮（首帧是 0）
        // 的宽度换行，行数虚高，卡片就被撑出一截空白。
        if abs(card.frame.width - w) > 0.5 {
            card.frame.size.width = w
            card.layoutSubtreeIfNeeded()
        }
        let content = rootStack.fittingSize.height
        let chrome: CGFloat = 22 + 14 + 24 + 18   // 上边距 + 间隔 + 页脚行 + 下边距
        let h = min(content + chrome, bounds.height - 120)
        card.frame = NSRect(
            x: (bounds.width - w) / 2,
            y: (bounds.height - h) / 2,
            width: max(w, 320),
            height: max(h, 220)).integral
    }

    /// 覆盖下层终端注册的 I-beam 光标区（搜索浮层同款问题同款解法）
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    // MARK: - 交互

    override var acceptsFirstResponder: Bool { true }

    /// 卡外点击关闭，与搜索浮层同一套手感（那是本 app 已确立的浮层惯例，
    /// 这里另搞一套只会让人以为坏了）。卡内点击被吞掉，不穿透到终端。
    ///
    /// 早先刻意做成「卡外不关闭」，怕误触后关掉就再也不见。这个顾虑不成立：
    /// 菜单项随时能重开，卡片底部也明写了这一句。
    override func mouseDown(with event: NSEvent) {
        let point = card.convert(event.locationInWindow, from: nil)
        guard !card.bounds.contains(point) else { return }
        closeTapped()
    }

    override func cancelOperation(_ sender: Any?) { closeTapped() }

    @objc private func closeTapped() {
        // 主动弹过就记下，之后只走菜单
        UserDefaults.standard.set(true, forKey: Self.dismissedKey)
        onDismiss?()
    }

    // MARK: - 刷新与动作

    private func reload() {
        switch HookInstaller.refreshShim() {
        case .linked(let target):
            helperLabel.stringValue = L("Currently points at %@", Self.abbreviate(target.path))
            helperLabel.textColor = ShellStyle.tertiaryText
        case .helperMissing(let expected):
            helperLabel.stringValue = L(
                "The helper is missing — expected at %@. Reinstall lightty, or build the "
                + "lightty-hook target if you are running from source.", expected.path)
            helperLabel.textColor = ShellStyle.secondaryText
        case .failed(let reason):
            helperLabel.stringValue = L("Could not refresh the helper link: %@", reason)
            helperLabel.textColor = ShellStyle.secondaryText
        }
        for report in HookInstaller.reports() {
            rows[report.agent]?.apply(report)
        }
        // apply() 会按最新状态重设按钮，把还在跑的那行盖掉——补回来
        for (agent, action) in inFlight { rows[agent]?.setWorking(action) }
        // 装完之后「暂不」就不再是准确的动作名了
        closeButton.label = didInstallSomething ? L("Done") : L("Not now")
        needsLayout = true
    }

    /// 注册要起子进程跑它们的 CLI，是**秒级**操作，同步调会把窗口冻住，所以走
    /// completion 版本。
    ///
    /// 两家各装各的：点了 Claude 再点 Codex，两行都进「安装中…」、各自出结果。
    /// 底层仍是一条串行队列，但那是为了保护**我们自己**的两处共享写
    /// （`~/.lightty/marketplace` 的生成，与台账文件的读-改-写），
    /// 与两家 agent 无关——它们的配置文件互相独立。串行的是执行，不是交互。
    private func perform(_ action: AgentRow.Action, on agent: HookAgent) {
        inFlight[agent] = action
        rows[agent]?.setWorking(action)
        let finish: (Result<HookInstaller.Outcome, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let outcome):
                if !outcome.removed { self.didInstallSomething = true }
                self.rows[agent]?.showResult(
                    Self.describe(outcome, action: action), isProblem: false)
            case .failure(let error):
                self.rows[agent]?.showResult(Self.describe(error), isProblem: true)
            }
            self.inFlight[agent] = nil
            self.reload()
        }
        switch action {
        case .install, .update: HookInstaller.install(agent, completion: finish)
        case .uninstall:        HookInstaller.uninstall(agent, completion: finish)
        }
    }

    private static func describe(_ outcome: HookInstaller.Outcome, action: AgentRow.Action) -> String {
        if outcome.commands.isEmpty {
            return L("Already up to date — nothing was changed.")
        }
        if outcome.removed { return L("Removed.") }
        // 「重开会话」这句不能省：hook 配置是 agent 启动时读的，装完不重开就是
        // 「点了没反应」，而用户第一反应会是我们坏了。
        return action == .update
            ? L("Updated. Restart claude/codex in your panes to pick it up.")
            : L("Installed. Restart claude/codex in your panes to pick it up.")
    }

    private static func describe(_ error: Error) -> String {
        // CLI 的原始输出是排障时最有用的东西，但可能很长——截断后展示，
        // 并把命令行原样给出去，用户能自己复制粘贴重跑一遍看全文。
        if let error = error as? HookCLIError {
            switch error {
            case .notFound(let executable):
                return L("The %@ command was not found on this Mac.", executable)
            case .timedOut(let command, let seconds):
                return L("“%@” did not finish within %ds. You can run it yourself to see why.",
                         command, Int(seconds))
            case .failed(let command, _, let output):
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                let clipped = trimmed.count > 300
                    ? String(trimmed.prefix(300)) + "…"
                    : trimmed
                return clipped.isEmpty
                    ? L("“%@” failed. Nothing was changed.", command)
                    : L("“%@” failed: %@", command, clipped)
            }
        }
        guard let error = error as? HookInstallError else { return error.localizedDescription }
        switch error {
        case .unparseable(let path, let reason):
            return L("Could not read %@ to check the current state (%@).", path, reason)
        case .unexpectedShape(let detail):
            return L("Could not read the current state — unrecognised config shape (%@).", detail)
        case .writeFailed(let path, let reason):
            return L("Could not write %@ (%@).", path, reason)
        case .shimUnavailable(let expected):
            return L("The hook helper is not available at %@ yet.", expected)
        }
    }

    // MARK: - 排版原语

    static func body(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = ShellStyle.secondaryText
        label.isSelectable = true
        return label
    }

    static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 10.5)
        label.textColor = ShellStyle.tertiaryText
        return label
    }

    /// 家目录缩成 `~`：绝对路径本身很长，展开的 home 只是噪音，
    /// 而缩写后的形式用户也能直接粘进终端。
    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.replacingOccurrences(of: home, with: "~")
    }

    /// 路径一律等宽且可选中——用户要能原样复制去核对
    static func mono(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        label.textColor = ShellStyle.primaryText
        label.isSelectable = true
        return label
    }

    static func button(
        _ title: String,
        emphasis: ShellTextButton.Emphasis = .quiet,
        target: AnyObject,
        action: Selector
    ) -> ShellTextButton {
        let button = ShellTextButton(title, emphasis: emphasis, target: target, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 24),
            button.widthAnchor.constraint(
                greaterThanOrEqualToConstant: max(72, button.intrinsicContentSize.width + 22)),
        ])
        return button
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - 单个 agent 一行

/// 紧凑行：左边「名字 / 状态」，右边**一个**按钮。
/// 每种状态只给一个动作——未装给 Install、已装给 Uninstall。同时摆三个按钮
/// 会把「现在该做什么」这个唯一重要的信息稀释掉。配置文件路径在 Details 里。
private final class AgentRow: NSView {
    /// 每种状态只对应一个动作，按钮永远只有一个语义
    enum Action { case install, update, uninstall }

    var onAction: ((Action) -> Void)?

    private let agent: HookAgent
    private let nameLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(wrappingLabelWithString: "")
    private let resultLabel = NSTextField(wrappingLabelWithString: "")
    private let actionButton: ShellTextButton
    private var action: Action = .install
    private var canAct = false

    init(agent: HookAgent) {
        self.agent = agent
        actionButton = HookSetupOverlay.button(
            L("Install"), emphasis: .primary, target: RowActionProxy.shared,
            action: #selector(RowActionProxy.noop))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = ShellStyle.rowCornerRadius
        applyFill()
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFill()
    }

    private func applyFill() {
        layer?.backgroundColor =
            ShellStyle.controlFill.shellResolvedCGColor(for: effectiveAppearance)
    }

    private func build() {
        nameLabel.stringValue = agent.displayName
        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.textColor = ShellStyle.primaryText

        stateLabel.font = .systemFont(ofSize: 10.5)
        stateLabel.textColor = ShellStyle.secondaryText

        resultLabel.font = .systemFont(ofSize: 10.5)
        resultLabel.textColor = ShellStyle.secondaryText
        resultLabel.isSelectable = true
        resultLabel.isHidden = true

        actionButton.target = self
        actionButton.action = #selector(actionTapped)

        let text = NSStackView(views: [nameLabel, stateLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        for v in [text, actionButton, resultLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            text.trailingAnchor.constraint(
                lessThanOrEqualTo: actionButton.leadingAnchor, constant: -12),

            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
            actionButton.centerYAnchor.constraint(equalTo: text.centerYAnchor),

            resultLabel.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 6),
            resultLabel.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            resultLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
            resultLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
        ])
    }

    func apply(_ report: HookInstaller.Report) {
        var detail: String
        switch report.state {
        case .agentMissing:
            detail = L("Not found on this Mac")
        case .installed:
            detail = L("Hook installed")
        case .notInstalled:
            detail = L("Not installed")
        case .partial(let missing):
            detail = L("Partly installed — missing: %@", missing.joined(separator: ", "))
        case .unreadable(let reason):
            detail = L("Config unreadable, lightty will not touch it (%@)", reason)
        }
        // Codex 的 trust 提示压成一行摆在状态位——用户在按下 Install **之前**必须
        // 知道下次跑 codex 会被拦一次，否则那个弹窗会被理解成 lightty 在偷装东西。
        if agent.requiresTrustPrompt, !report.isInstalledState {
            detail += L(" · Codex will ask you to approve this on its next run")
        }
        // 两家都在安装时**拷贝**插件，改了事件表不重装等于没改
        if report.needsUpdate { detail += L(" · An update is available") }
        stateLabel.stringValue = detail

        action = report.needsUpdate ? .update : (report.isInstalledState ? .uninstall : .install)
        actionButton.label = Self.title(for: action)
        // 状态读不懂时禁用动作：读不懂就不动，是这套设计的一贯态度
        let readable: Bool
        if case .unreadable = report.state { readable = false } else { readable = true }
        canAct = report.isAgentPresent && readable
        actionButton.isEnabled = canAct
        // 必须显式复位：setWorking 会置灰，而 isEnabled 与 looksDisabled 是两条
        // 独立通路，只改前者的话跑完按钮会一直保持灰色观感。
        actionButton.looksDisabled = false
    }

    private static func title(for action: Action) -> String {
        switch action {
        case .install: return L("Install")
        case .update: return L("Update")
        case .uninstall: return L("Uninstall")
        }
    }

    /// 进行中：只影响这一行。另一家该能照常点自己的按钮。
    func setWorking(_ working: Action) {
        actionButton.label = Self.workingTitle(for: working)
        actionButton.isEnabled = false
        actionButton.looksDisabled = true
    }

    private static func workingTitle(for action: Action) -> String {
        switch action {
        case .install: return L("Installing…")
        case .update: return L("Updating…")
        case .uninstall: return L("Removing…")
        }
    }

    func showResult(_ text: String, isProblem: Bool) {
        resultLabel.stringValue = text
        resultLabel.textColor = isProblem ? ShellStyle.primaryText : ShellStyle.secondaryText
        resultLabel.isHidden = false
    }

    @objc private func actionTapped() { onAction?(action) }
}

/// ShellTextButton 的 target 在 init 时必填，而 AgentRow 此刻还没 super.init 完。
/// 用一个空目标占位，build() 里再改指向 self。
private final class RowActionProxy: NSObject {
    static let shared = RowActionProxy()
    @objc func noop() {}
}

extension HookInstaller.Report {
    var isInstalledState: Bool {
        if case .installed = state { return true }
        return false
    }
}

extension HookAgent {
    /// 产品名，不走本地化以外的加工——用户在自己机器上看到的就是这两个名字
    var displayName: String {
        switch self {
        case .claudeCode: return L("Claude Code")
        case .codex: return L("Codex")
        }
    }
}
