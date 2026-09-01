import AppKit

/// 双栏侧栏的左栏：工作区 › pane 两级树（cmux 形态的窗口活地图）。
/// spec: docs/specs/double-sidebar.md。全展开无折叠（单工作区 pane ≤6）。
/// 工作区行：单击切换、双击改名、hover ⋯ 菜单（重命名/关闭）；
/// pane 行：单击跨工作区聚焦、hover 时圆点变 ✕（内核关闭同路）、
/// 附绑定任务名次要色。重命名 pane 唯一入口保持灵动岛，此处不提供。
final class WorkspaceColumnView: NSView {
    private let sectionLabel = NSTextField(labelWithString: L("Workspaces"))
    private let newButton = ShellIconButton(
        symbol: "plus.rectangle.on.rectangle", accessibilityLabel: L("New workspace"),
        target: nil, action: nil)
    private let scroll = NSScrollView()
    private let rowsStack = NSStackView()
    private var reloadScheduled = false

    private var controller: TerminalWindowController? {
        window?.windowController as? TerminalWindowController
    }

    init() {
        super.init(frame: .zero)

        sectionLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        sectionLabel.textColor = ShellStyle.tertiaryText

        newButton.target = self
        newButton.action = #selector(newWorkspace)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 2

        let document = ColumnFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rowsStack)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay

        for v in [sectionLabel, newButton, scroll] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            // 首行行心对齐 pane header 行心（两者都从各自 chrome 顶开始 + 14）
            newButton.topAnchor.constraint(equalTo: topAnchor, constant: 0),
            newButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            newButton.widthAnchor.constraint(equalToConstant: 28),
            newButton.heightAnchor.constraint(equalToConstant: 28),

            sectionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            sectionLabel.centerYAnchor.constraint(equalTo: newButton.centerYAnchor),
            sectionLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: newButton.leadingAnchor, constant: -8),

            scroll.topAnchor.constraint(equalTo: newButton.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            // 对称 padding：边缘胶囊骑跨边界（半进半出），不侵占内容带
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            rowsStack.topAnchor.constraint(equalTo: document.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rowsStack.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            document.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            document.bottomAnchor.constraint(equalTo: rowsStack.bottomAnchor),
        ])

        // pane 绑定/改名/解绑经 lighttyTasksDidChange 广播；工作区结构变化
        // 由 TerminalWindowController.refreshTabStrip 直接调 reload。
        NotificationCenter.default.addObserver(
            self, selector: #selector(scheduleReload),
            name: .lighttyTasksDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { reload() }
    }

    @objc private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.reloadScheduled = false
            self?.reload()
        }
    }

    @objc private func newWorkspace() {
        guard let controller else { return }
        controller.addTab(initialPane: PaneView())
    }

    func reload() {
        guard let controller else { return }
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let overview = controller.workspaceOverview()
        // 单工作区：工作区层级没有信息量，直接平铺 pane 行（缩进减一级）
        let single = overview.count == 1
        for entry in overview {
            let index = entry.index
            if single {
                for pane in entry.panes {
                    add(makePaneRow(for: pane, indented: false))
                }
                continue
            }
            let row = WorkspaceRowView(title: entry.title, isActive: entry.isActive)
            row.onSelect = { [weak self] in self?.controller?.selectTab(at: index) }
            row.onRename = { [weak self, weak row] in
                guard let self, let anchor = row, let controller = self.controller else { return }
                NameEditorPopover.present(
                    from: anchor, title: L("Rename workspace"),
                    initial: entry.title, confirmLabel: L("Rename")
                ) { name in controller.renameTab(at: index, to: name) }
            }
            row.onMenu = { [weak self, weak row] in
                guard let self, let anchor = row else { return }
                ShellMenuPopover.present(from: anchor, items: [
                    .action(L("Rename workspace")) { [weak self] in
                        guard let controller = self?.controller else { return }
                        NameEditorPopover.present(
                            from: anchor, title: L("Rename workspace"),
                            initial: entry.title, confirmLabel: L("Rename")
                        ) { name in controller.renameTab(at: index, to: name) }
                    },
                    .action(L("Close workspace"), destructive: true) { [weak self] in
                        self?.controller?.closeTab(at: index)
                    },
                ])
            }
            row.onClose = { [weak self] in self?.controller?.closeTab(at: index) }
            add(row)

            for pane in entry.panes {
                add(makePaneRow(for: pane, indented: true))
            }
        }
        window?.invalidateCursorRects(for: self)
    }

    private func makePaneRow(for pane: PaneView, indented: Bool) -> PaneRowView {
        let paneRow = PaneRowView(
            name: pane.header.title,
            taskName: pane.header.titleOfBoundTask,
            bound: pane.header.titleOfBoundTask != nil,
            indented: indented)
        paneRow.onSelect = { [weak self, weak pane] in
            guard let pane else { return }
            self?.controller?.reveal(pane: pane)
        }
        paneRow.onClose = { [weak pane] in
            pane?.terminal.requestCloseFromUser()
        }
        return paneRow
    }

    private func add(_ row: NSView) {
        row.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
    }
}

private final class ColumnFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 工作区行（容器级）：当前高亮、单击切换、双击改名、hover ⋯ 菜单。
private final class WorkspaceRowView: NSView {
    var onSelect: (() -> Void)?
    var onRename: (() -> Void)?
    var onMenu: (() -> Void)?
    var onClose: (() -> Void)?

    private let isActive: Bool
    private let menuButton = NSButton()
    private let closeButton = NSButton()
    private var tracking: NSTrackingArea?
    private var hovered = false {
        didSet {
            applyFill()
            menuButton.isHidden = !hovered
            closeButton.isHidden = !hovered
        }
    }

    init(title: String, isActive: Bool) {
        self.isActive = isActive
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: isActive ? .semibold : .medium)
        label.textColor = ShellStyle.primaryText
        label.lineBreakMode = .byTruncatingTail

        menuButton.image = NSImage(
            systemSymbolName: "ellipsis", accessibilityDescription: L("More actions"))?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        menuButton.isBordered = false
        menuButton.imagePosition = .imageOnly
        menuButton.focusRingType = .none
        menuButton.contentTintColor = ShellStyle.secondaryText
        menuButton.isHidden = true
        menuButton.target = self
        menuButton.action = #selector(menuTapped)

        closeButton.image = NSImage(
            systemSymbolName: "xmark", accessibilityDescription: L("Close workspace"))?
            .withSymbolConfiguration(.init(pointSize: 8.5, weight: .bold))
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.focusRingType = .none
        closeButton.contentTintColor = ShellStyle.secondaryText
        closeButton.isHidden = true
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.toolTip = L("Close workspace")

        for v in [label, menuButton, closeButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: menuButton.leadingAnchor, constant: -6),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),
            menuButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
            menuButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            menuButton.widthAnchor.constraint(equalToConstant: 20),
            menuButton.heightAnchor.constraint(equalToConstant: 20),
        ])
        applyFill()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func menuTapped() { onMenu?() }
    @objc private func closeTapped() { onClose?() }

    private func applyFill() {
        let fill: NSColor =
            isActive ? ShellStyle.selectionFill : (hovered ? ShellStyle.controlFill : .clear)
        layer?.backgroundColor = fill.shellResolvedCGColor(for: effectiveAppearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFill()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyFill()  // backing layer 挂窗重建后重涂
    }

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

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onRename?() } else { onSelect?() }
    }
}

/// pane 行（叶子级）：缩进一级；绑定态圆点常驻 + pane 名 + 任务名次要色；
/// hover 时行尾出 ✕（与工作区行的关闭位统一；内核关闭同路）。
/// pane header 胶囊的"圆点变 ✕"交互独立保留，不受此处影响。
private final class PaneRowView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let dotView = NSView()
    private let closeButton = NSButton()
    private var tracking: NSTrackingArea?
    private var hovered = false {
        didSet {
            applyFill()
            closeButton.isHidden = !hovered
        }
    }

    init(name: String, taskName: String?, bound: Bool, indented: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6

        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 3
        dotView.layer?.backgroundColor =
            (bound ? NSColor.systemGreen : .systemGray).cgColor

        closeButton.image = NSImage(
            systemSymbolName: "xmark", accessibilityDescription: L("Close pane"))?
            .withSymbolConfiguration(.init(pointSize: 7.5, weight: .bold))
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.focusRingType = .none
        closeButton.contentTintColor = ShellStyle.secondaryText
        closeButton.isHidden = true
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.toolTip = L("Close pane")

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 11.5)
        nameLabel.textColor = ShellStyle.primaryText
        nameLabel.lineBreakMode = .byTruncatingTail

        let taskLabel = NSTextField(labelWithString: taskName.map { "· \($0)" } ?? "")
        taskLabel.font = .systemFont(ofSize: 10.5)
        taskLabel.textColor = ShellStyle.tertiaryText
        taskLabel.lineBreakMode = .byTruncatingTail
        taskLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for v in [dotView, closeButton, nameLabel, taskLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),

            // 嵌套态缩进一级（容器行文字起点 + 10）；单工作区平铺态回到容器级起点
            dotView.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: indented ? 20 : 10),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 6),
            dotView.heightAnchor.constraint(equalToConstant: 6),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),

            nameLabel.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 7),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            taskLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 5),
            taskLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            taskLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),
        ])
        applyFill()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func closeTapped() { onClose?() }

    private func applyFill() {
        let fill: NSColor = hovered ? ShellStyle.controlFill : .clear
        layer?.backgroundColor = fill.shellResolvedCGColor(for: effectiveAppearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFill()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyFill()
    }

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

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) { onSelect?() }
}
