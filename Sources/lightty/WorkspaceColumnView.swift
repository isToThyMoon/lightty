import AppKit
import LighttyCore

/// 双栏侧栏的左栏：工作区 › pane 两级树（cmux 形态的窗口活地图）。
/// spec: docs/specs/double-sidebar.md。工作区可折叠，折叠状态仅当前侧栏会话内保留。
/// 工作区行：单击切换、点 disclosure 折叠、双击改名、hover ⋯ 菜单；
/// pane 行：双行展示任务/cwd，单击跨工作区聚焦并保持激活底色，hover 出现 ✕。
/// 重命名 pane 唯一入口保持灵动岛，此处不提供。
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
    /// 工作区没有持久化折叠语义；仅在当前侧栏实例内记忆，reload 不丢。
    private var collapsedWorkspaceIDs = Set<UUID>()

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

    /// pane 焦点变化只原地切换行底色，不拆建工作区树。
    func applyActivePane(_ paneID: UUID?) {
        for (rowPaneID, row) in paneRows {
            row.setActive(rowPaneID == paneID)
        }
    }

    /// shell 的 OSC PWD 更新只改对应 pane 第二行，不重建工作区树。
    func applyWorkingDirectory(_ directory: String?, for paneID: UUID) {
        paneRows[paneID]?.applyWorkingDirectory(directory)
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
        let activePaneID = controller.activePane?.dragIdentifier
        collapsedWorkspaceIDs.formIntersection(overview.map(\.id))
        for entry in overview {
            let index = entry.index
            let isCollapsed = collapsedWorkspaceIDs.contains(entry.id)
            let row = WorkspaceRowView(
                title: entry.title,
                isActive: entry.isActive,
                isCollapsed: isCollapsed)
            row.onSelect = { [weak self] in self?.controller?.selectTab(at: index) }
            row.onToggleCollapse = { [weak self] in
                guard let self else { return }
                if self.collapsedWorkspaceIDs.contains(entry.id) {
                    self.collapsedWorkspaceIDs.remove(entry.id)
                } else {
                    self.collapsedWorkspaceIDs.insert(entry.id)
                }
                self.reload()
            }
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

            guard !isCollapsed else { continue }
            for pane in entry.panes {
                add(makePaneRow(
                    for: pane, indented: true,
                    isActive: pane.dragIdentifier == activePaneID))
            }
        }
        // 重建后立刻补一次状态：新行默认是静息态，不补会闪一下再变回来
        applyStatuses()
        window?.invalidateCursorRects(for: self)
    }

    private func makePaneRow(
        for pane: PaneView,
        indented: Bool,
        isActive: Bool
    ) -> PaneRowView {
        let paneRow = PaneRowView(
            paneID: pane.dragIdentifier,
            name: pane.header.title,
            taskName: pane.header.titleOfBoundTask,
            bound: pane.header.titleOfBoundTask != nil,
            indented: indented,
            isActive: isActive,
            workingDirectory: pane.terminal.currentWorkingDirectory)
        paneRow.onSelect = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.controller?.reveal(pane: pane)
            self.applyActivePane(pane.dragIdentifier)
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
    var onToggleCollapse: (() -> Void)?
    var onRename: (() -> Void)?
    var onMenu: (() -> Void)?
    var onClose: (() -> Void)?

    private let isActive: Bool
    private let disclosureButton = NSButton()
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

    init(title: String, isActive: Bool, isCollapsed: Bool) {
        self.isActive = isActive
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: isActive ? .semibold : .medium)
        label.textColor = ShellStyle.primaryText
        label.lineBreakMode = .byTruncatingTail

        let disclosureTitle = isCollapsed ? L("Expand workspace") : L("Collapse workspace")
        disclosureButton.image = NSImage(
            systemSymbolName: isCollapsed ? "chevron.right" : "chevron.down",
            accessibilityDescription: disclosureTitle)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        disclosureButton.isBordered = false
        disclosureButton.imagePosition = .imageOnly
        disclosureButton.focusRingType = .none
        disclosureButton.contentTintColor = ShellStyle.secondaryText
        disclosureButton.target = self
        disclosureButton.action = #selector(toggleCollapse)
        disclosureButton.toolTip = disclosureTitle

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

        for v in [disclosureButton, label, menuButton, closeButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            disclosureButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            disclosureButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosureButton.widthAnchor.constraint(equalToConstant: 18),
            disclosureButton.heightAnchor.constraint(equalToConstant: 22),
            label.leadingAnchor.constraint(equalTo: disclosureButton.trailingAnchor, constant: 1),
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

    @objc private func toggleCollapse() { onToggleCollapse?() }
    @objc private func menuTapped() { onMenu?() }
    @objc private func closeTapped() { onClose?() }

    private func applyFill() {
        let fill: NSColor =
            isActive ? ShellStyle.pressedFill : (hovered ? ShellStyle.selectionFill : .clear)
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

/// pane 行（叶子级）：第一行 = 圆点 + pane 名 + 状态 badge；
/// 第二行 = 绑定任务 + cwd（路径从头截断，优先保留末级目录）。
/// 当前 pane 保持 hover 同款底色，hover 时行尾出 ✕（与工作区行的关闭位统一；
/// 内核关闭同路）。
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
    private let directoryLabel = NSTextField(labelWithString: "")
    private let statusBadge = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var status: PaneStatus?
    private var terminalWorkingDirectory: String?
    private var activity: PaneActivity? { status?.state }
    private var isActive: Bool
    private var hovered = false {
        didSet {
            applyFill()
            closeButton.isHidden = !hovered
        }
    }

    init(
        paneID: UUID,
        name: String,
        taskName: String?,
        bound: Bool,
        indented: Bool,
        isActive: Bool,
        workingDirectory: String?
    ) {
        self.paneID = paneID
        self.bound = bound
        self.taskName = taskName
        self.isActive = isActive
        terminalWorkingDirectory = workingDirectory
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
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        taskLabel.font = .systemFont(ofSize: 10, weight: .medium)
        taskLabel.textColor = ShellStyle.secondaryText
        taskLabel.lineBreakMode = .byTruncatingTail
        taskLabel.toolTip = taskName
        taskLabel.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(740), for: .horizontal)

        directoryLabel.font = .systemFont(ofSize: 10)
        directoryLabel.textColor = ShellStyle.tertiaryText
        directoryLabel.lineBreakMode = .byTruncatingHead
        directoryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        directoryLabel.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(750), for: .horizontal)

        let secondaryStack = NSStackView(views: [taskLabel, directoryLabel])
        secondaryStack.orientation = .horizontal
        secondaryStack.alignment = .firstBaseline
        secondaryStack.spacing = 4

        statusBadge.wantsLayer = true
        statusBadge.layer?.cornerRadius = 5
        statusBadge.isHidden = true
        statusLabel.font = .systemFont(ofSize: 10, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusBadge.addSubview(statusLabel)

        for v in [dotView, closeButton, nameLabel, statusBadge, secondaryStack] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),

            // 嵌套态缩进一级；圆点跟第一行对齐，不悬在两行中间。
            dotView.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: indented ? 20 : 10),
            dotView.widthAnchor.constraint(equalToConstant: 6),
            dotView.heightAnchor.constraint(equalToConstant: 6),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),

            nameLabel.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 7),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            dotView.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),

            statusBadge.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 6),
            statusBadge.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            statusBadge.heightAnchor.constraint(equalToConstant: 18),
            statusBadge.trailingAnchor.constraint(
                lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),

            statusLabel.leadingAnchor.constraint(equalTo: statusBadge.leadingAnchor, constant: 6),
            statusLabel.trailingAnchor.constraint(equalTo: statusBadge.trailingAnchor, constant: -6),
            statusLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),
            statusLabel.topAnchor.constraint(
                greaterThanOrEqualTo: statusBadge.topAnchor, constant: 1),
            statusLabel.bottomAnchor.constraint(
                lessThanOrEqualTo: statusBadge.bottomAnchor, constant: -1),

            secondaryStack.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            secondaryStack.trailingAnchor.constraint(
                lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),
            secondaryStack.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            secondaryStack.bottomAnchor.constraint(
                lessThanOrEqualTo: bottomAnchor, constant: -4),
        ])
        applyDotColor()
        applyStatusBadge()
        applyMetadataLine()
        applyFill()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func closeTapped() { onClose?() }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        applyFill()
    }

    func applyWorkingDirectory(_ directory: String?) {
        guard terminalWorkingDirectory != directory else { return }
        terminalWorkingDirectory = directory
        applyMetadataLine()
    }

    /// 原地更新：这个插槽没有竞争（✕ 在行尾，不抢圆点位），改个颜色就完事。
    func applyStatus(_ status: PaneStatus?) {
        // tool 名进 badge，cwd 是第二行在无 OSC PWD 时的兜底。
        guard self.status?.state != status?.state
                || self.status?.tool != status?.tool
                || self.status?.cwd != status?.cwd
        else { return }
        self.status = status
        applyDotColor()
        applyStatusBadge()
        applyMetadataLine()
        applyFill()
    }

    /// 活动状态与 pane 名同在第一行；空闲时隐藏，不用任务名补位。
    ///
    /// **颜色不能单独承担语义**——用户没有图例就是在猜"蓝色是什么意思"。
    /// 文字说明状态、颜色与圆点同色，两者互相解释；扫读时看色块，
    /// 停下来时看文字。任务名是稳定信息，固定保留在第二行。
    private func applyStatusBadge() {
        if let text = Self.statusText(status) {
            let color = ShellStyle.statusColor(for: status!.state)
            statusBadge.isHidden = false
            statusLabel.stringValue = text
            statusLabel.textColor = color
            statusBadge.layer?.backgroundColor = color
                .shellResolvedCGColor(for: effectiveAppearance)
                .copy(alpha: 0.12)
        } else {
            statusBadge.isHidden = true
            statusBadge.layer?.backgroundColor = nil
        }
    }

    /// 第二行同时保留任务映射和 cwd。空间不足时任务名从尾部截断、cwd 从头部
    /// 截断，因此最有辨识度的任务前缀和路径末级目录都尽量留下。
    private func applyMetadataLine() {
        let rawDirectory = terminalWorkingDirectory ?? status?.cwd
        let displayDirectory = rawDirectory.map {
            ($0 as NSString).abbreviatingWithTildeInPath
        }
        taskLabel.isHidden = taskName == nil
        taskLabel.stringValue = taskName.map {
            displayDirectory == nil ? $0 : "\($0) ·"
        } ?? ""
        directoryLabel.isHidden = displayDirectory == nil
        directoryLabel.stringValue = displayDirectory ?? ""
        directoryLabel.toolTip = rawDirectory
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
        if hovered || isActive {
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
        applyStatusBadge()
        applyFill()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyDotColor()
        applyStatusBadge()
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
