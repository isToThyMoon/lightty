import AppKit

/// 应用设置页：整窗覆盖的一页（ChatGPT / Codex 桌面版式），不是独立窗口。
/// 左栏：返回 / 搜索 / 分组导航；右侧：当前页内容。红绿灯仍在左上（页面垫在
/// 标题栏容器之下）。Esc 或「返回应用」关闭。
final class SettingsView: NSView {
    enum Page: String, CaseIterable {
        case general, appearance

        var title: String {
            switch self {
            case .general: return L("General")
            case .appearance: return L("Appearance")
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .appearance: return "sun.max"
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

        searchField.placeholderString = L("Search settings…")
        searchField.font = .systemFont(ofSize: 12.5)
        searchField.controlSize = .regular
        searchField.focusRingType = .none
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

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        column.setHuggingPriority(.init(1), for: .horizontal)
        pageHost.addSubview(column)
        // 内容列：在内容区里居中，宽 = 区宽 − 112 且 ≤ 720（参考 ChatGPT：宽窗口时
        // 内容居中封顶，不贴任何一边）；窗口窄时留白退到 24，再压内容宽。
        let centered = column.centerXAnchor.constraint(equalTo: pageHost.centerXAnchor)
        centered.priority = .init(800)
        let fill = column.widthAnchor.constraint(equalTo: pageHost.widthAnchor, constant: -112)
        fill.priority = .init(750)
        let minWidth = column.widthAnchor.constraint(greaterThanOrEqualToConstant: 300)
        minWidth.priority = .init(900)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: pageHost.topAnchor, constant: 64),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: pageHost.leadingAnchor, constant: 24),
            column.trailingAnchor.constraint(lessThanOrEqualTo: pageHost.trailingAnchor, constant: -24),
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

        let terminalGroup = SettingsGroup()
        let toggle = ShellToggle(isOn: TerminalThemePreference.usesBuiltInTheme())
        toggle.onChange = { on in
            TerminalThemePreference.setUsesBuiltInTheme(on)
            GhosttyRuntime.shared.reloadGlobalConfig()
            PreferenceKind.terminalTheme.post()
        }
        terminalGroup.addRow(title: L("Use the built-in Lightty terminal theme"), control: toggle)
        let hooksButton = NSButton(title: L("Manage…"), target: self,
                                   action: #selector(showHookSetup))
        hooksButton.bezelStyle = .rounded
        hooksButton.font = .systemFont(ofSize: 12)
        terminalGroup.addRow(title: L("Agent status hooks"), control: hooksButton)
        column.addArrangedSubview(terminalGroup)
        terminalGroup.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
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
        column.addArrangedSubview(accentGroup)
        accentGroup.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }

    private func selectAppearance(_ option: AppearancePreference) {
        AppearancePreference.set(option)
        showPage(.appearance)
    }

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
