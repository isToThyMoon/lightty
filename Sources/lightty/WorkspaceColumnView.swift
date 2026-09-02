import AppKit
import LighttyCore

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
    /// pane 行按 pane id 索引，供状态原地更新用。
    /// 不能走 `reload()`：它拆掉重建每一行，而状态是高频的
    /// （一次工具调用就有 PreToolUse + PostToolUse 两发），拆建必闪。
    private var paneRows: [UUID: PaneRowView] = [:]

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
            newButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            newButton.widthAnchor.constraint(equalToConstant: 28),
            newButton.heightAnchor.constraint(equalToConstant: 28),

            // 12 边距 + 行内 10 缩进：标题与行文字左对齐
            sectionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            sectionLabel.centerYAnchor.constraint(equalTo: newButton.centerYAnchor),
            sectionLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: newButton.leadingAnchor, constant: -8),

            scroll.topAnchor.constraint(equalTo: newButton.bottomAnchor, constant: 12),
            // 两侧对称 12 = 边缘钮宽度：task 卡片关着时，窗口左缘的展开钮
            // （EdgeToggleControl）正好落在左侧这条边沟里，行高亮到钮的圆角处止步。
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
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
        if window != nil {
            reload()
            // 向 presenter 报到而不是自己订阅通知：一次广播要分发到 header、
            // 灵动岛、侧栏三处，合流在 presenter 里做才只做一次防抖。
            PaneStatusPresenter.shared.register(column: self)
        }
    }

    /// 单 pane 原地更新：通知带着变化的 pane，整列扫一遍是白做的
    func applyStatus(for paneID: UUID) {
        paneRows[paneID]?.applyStatus(PaneStatusStore.shared.status(for: paneID))
    }

    /// 状态原地更新：只改圆点颜色与行底，不动视图树。
    func applyStatuses() {
        for (paneID, row) in paneRows {
            row.applyStatus(PaneStatusStore.shared.status(for: paneID))
        }
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
        paneRows.removeAll()
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
        // 重建后立刻补一次状态：新行默认是静息态，不补会闪一下再变回来
        applyStatuses()
        window?.invalidateCursorRects(for: self)
    }

    private func makePaneRow(for pane: PaneView, indented: Bool) -> PaneRowView {
        let paneRow = PaneRowView(
            paneID: pane.dragIdentifier,
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
        paneRows[pane.dragIdentifier] = paneRow
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

    /// 行持有 pane 身份（以前只拿到一堆字符串），才谈得上原地更新。
    /// 存 id 而不是 pane 引用：行只需要向 store 取状态，不需要够到 pane 本体，
    /// 少一条会让关掉的 pane 多活一会儿的强/弱引用。
    let paneID: UUID

    private let dotView = NSView()
    private let closeButton = NSButton()
    private var tracking: NSTrackingArea?
    private let bound: Bool
    private let taskName: String?
    private let taskLabel = NSTextField(labelWithString: "")
    private var status: PaneStatus?
    private var activity: PaneActivity? { status?.state }
    private var hovered = false {
        didSet {
            applyFill()
            closeButton.isHidden = !hovered
        }
    }

    init(paneID: UUID, name: String, taskName: String?, bound: Bool, indented: Bool) {
        self.paneID = paneID
        self.bound = bound
        self.taskName = taskName
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6

        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 3

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

        taskLabel.font = .systemFont(ofSize: 10.5)
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
        applyDotColor()
        applySecondaryLabel()
        applyFill()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func closeTapped() { onClose?() }

    /// 原地更新：这个插槽没有竞争（✕ 在行尾，不抢圆点位），改个颜色就完事。
    func applyStatus(_ status: PaneStatus?) {
        // tool 名也要进副标题，所以不能只比 state
        guard self.status?.state != status?.state || self.status?.tool != status?.tool
        else { return }
        self.status = status
        applyDotColor()
        applySecondaryLabel()
        applyFill()
    }

    /// 副标题槽位：有活跃状态时让位给状态文字，否则显示任务名。
    ///
    /// **颜色不能单独承担语义**——用户没有图例就是在猜"蓝色是什么意思"。
    /// 文字说明状态、颜色与圆点同色，两者互相解释；扫读时看色块，
    /// 停下来时看文字。任务名是稳定信息、别处也看得到，让位给时效信息不亏。
    private func applySecondaryLabel() {
        if let text = Self.statusText(status) {
            taskLabel.stringValue = text
            taskLabel.textColor = ShellStyle.statusColor(for: status!.state)
        } else {
            taskLabel.stringValue = taskName.map { "· \($0)" } ?? ""
            taskLabel.textColor = ShellStyle.tertiaryText
        }
    }

    private static func statusText(_ status: PaneStatus?) -> String? {
        guard let status else { return nil }
        switch status.state {
        case .idle: return nil
        case .thinking: return L("Thinking")
        // 工具名比"忙着"有信息量得多——能看出它在编辑还是在跑命令
        case .tool: return status.tool.map { L("Running %@", $0) } ?? L("Working")
        case .attention: return L("Needs you")
        case .done: return L("Finished")
        }
    }

    private func applyDotColor() {
        dotView.layer?.backgroundColor = ShellStyle
            .dotColor(bound: bound, activity: activity)
            .shellResolvedCGColor(for: effectiveAppearance)
    }

    private func applyFill() {
        // hover 优先：指针反馈不能被状态底色吃掉。
        // `done` 给一层极淡的同色底——侧栏是"哪个 pane 完事了"的扫读面，
        // 一个 6pt 的点在满屏行里不够抓眼，整行透一点色才扫得出来。
        if hovered {
            layer?.backgroundColor = ShellStyle.controlFill
                .shellResolvedCGColor(for: effectiveAppearance)
        } else if activity == .done {
            layer?.backgroundColor = ShellStyle.statusDone
                .shellResolvedCGColor(for: effectiveAppearance)
                .copy(alpha: 0.12)
        } else {
            layer?.backgroundColor = NSColor.clear
                .shellResolvedCGColor(for: effectiveAppearance)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyDotColor()
        applyFill()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyDotColor()
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
