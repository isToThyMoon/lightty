import AppKit
import LighttyCore

/// 双栏侧栏的左栏：标签页 › pane 两级树（cmux 形态的窗口活地图）。
/// spec: docs/specs/double-sidebar.md。标签页可折叠，折叠状态仅当前侧栏会话内保留。
///
/// 层级表达（Safari 侧栏标签页组同款）：标签页行 = 容器图标 + semibold 标题 +
/// pane 计数，活跃时图标/标题染强调色但**不给填充**；pane 行 = 缩进的圆点 +
/// 常规字重单行。全侧栏唯一的填充高亮是当前 pane（强调色淡底）——当前标签页
/// 必然包含当前 pane，两级选中不需要两块底色。
///
/// 标签页行：单击切换、点 chevron 折叠、双击改名、hover ⋯ 菜单；
/// pane 行：单行 = 圆点 + pane 名 [· 任务名]，cwd 挪 tooltip，hover 出现 ✕。
/// 重命名 pane 唯一入口保持灵动岛，此处不提供。
final class TabColumnView: NSView {
    private let sectionLabel = NSTextField(labelWithString: L("Tabs"))
    private let splitRightButton = ShellIconButton(
        symbol: "rectangle.split.2x1", accessibilityLabel: L("Split right"),
        target: nil, action: nil)
    private let splitDownButton = ShellIconButton(
        symbol: "rectangle.split.1x2", accessibilityLabel: L("Split down"),
        target: nil, action: nil)
    private let newTabButton = ShellIconButton(
        symbol: "plus.rectangle.on.rectangle", accessibilityLabel: L("New tab"),
        target: nil, action: nil)
    private let scroll = NSScrollView()
    private let rowsStack = NSStackView()
    private var reloadScheduled = false
    /// pane 行按 pane id 索引，供状态原地更新用。
    /// 不能走 `reload()`：它拆掉重建每一行，而状态是高频的
    /// （一次工具调用就有 PreToolUse + PostToolUse 两发），拆建必闪。
    private var paneRows: [UUID: PaneRowView] = [:]
    /// 标签页没有持久化折叠语义；仅在当前侧栏实例内记忆，reload 不丢。
    private var collapsedTabIDs = Set<UUID>()

    private var controller: TerminalWindowController? {
        window?.windowController as? TerminalWindowController
    }

    init() {
        super.init(frame: .zero)

        sectionLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        sectionLabel.textColor = ShellStyle.tertiaryText

        splitRightButton.target = self
        splitRightButton.action = #selector(splitRight)
        splitDownButton.target = self
        splitDownButton.action = #selector(splitDown)
        newTabButton.target = self
        newTabButton.action = #selector(newTab)

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

        for v in [sectionLabel, splitRightButton, splitDownButton, newTabButton, scroll] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            // 首行行心对齐 pane header 行心（两者都从各自 chrome 顶开始 + 14）
            newTabButton.topAnchor.constraint(equalTo: topAnchor),
            newTabButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            newTabButton.widthAnchor.constraint(equalToConstant: 28),
            newTabButton.heightAnchor.constraint(equalToConstant: 28),

            splitDownButton.trailingAnchor.constraint(
                equalTo: newTabButton.leadingAnchor, constant: -1),
            splitDownButton.centerYAnchor.constraint(equalTo: newTabButton.centerYAnchor),
            splitDownButton.widthAnchor.constraint(equalToConstant: 28),
            splitDownButton.heightAnchor.constraint(equalToConstant: 28),

            splitRightButton.trailingAnchor.constraint(
                equalTo: splitDownButton.leadingAnchor, constant: -1),
            splitRightButton.centerYAnchor.constraint(equalTo: newTabButton.centerYAnchor),
            splitRightButton.widthAnchor.constraint(equalToConstant: 28),
            splitRightButton.heightAnchor.constraint(equalToConstant: 28),

            // 12 边距 + 行内 10 缩进：标题与行文字左对齐
            sectionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            sectionLabel.centerYAnchor.constraint(equalTo: newTabButton.centerYAnchor),
            sectionLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: splitRightButton.leadingAnchor, constant: -4),

            scroll.topAnchor.constraint(equalTo: newTabButton.bottomAnchor, constant: 12),
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

        // pane 绑定/改名/解绑经 lighttyTasksDidChange 广播；标签页结构变化
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

    /// pane 焦点变化只原地切换行底色，不拆建标签页树。
    func applyActivePane(_ paneID: UUID?) {
        for (rowPaneID, row) in paneRows {
            row.setActive(rowPaneID == paneID)
        }
    }

    /// shell 的 OSC PWD 更新只改对应 pane 第二行，不重建标签页树。
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

    @objc private func newTab() {
        // 有活跃 pane 时走 Ghostty action 通路：新标签页继承当前 pane 的
        // cwd/font/context。空态（全部标签页已关）没有活跃 pane，直接建一个。
        if let active = controller?.activePane {
            active.terminal.performBindingAction("new_tab")
        } else {
            controller?.addTab(initialPane: PaneView())
        }
    }

    @objc private func splitRight() {
        controller?.activePane?.terminal.performBindingAction("new_split:right")
    }

    @objc private func splitDown() {
        controller?.activePane?.terminal.performBindingAction("new_split:down")
    }

    func reload() {
        guard let controller else { return }
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        paneRows.removeAll()
        let overview = controller.tabOverview()
        let activePaneID = controller.activePane?.dragIdentifier
        collapsedTabIDs.formIntersection(overview.map(\.id))
        for entry in overview {
            let index = entry.index
            let tabID = entry.id
            let wasActive = entry.isActive
            let isCollapsed = collapsedTabIDs.contains(entry.id)
            let row = TabRowView(
                title: entry.title,
                count: entry.panes.count,
                isActive: entry.isActive,
                isCollapsed: isCollapsed)
            row.tabIndex = index
            row.onSelect = { [weak self] in
                guard let self else { return }
                if wasActive {
                    self.toggleTabCollapse(tabID)
                } else {
                    self.controller?.selectTab(at: index)
                }
            }
            row.onToggleCollapse = { [weak self] in
                self?.toggleTabCollapse(tabID)
            }
            row.onPaneDrop = { [weak self] paneID in
                self?.controller?.movePane(withID: paneID, toTabAt: index) ?? false
            }
            row.onRename = { [weak self, weak row] in
                guard let self, let anchor = row, let controller = self.controller else { return }
                NameEditorPopover.present(
                    from: anchor, title: L("Rename tab"),
                    initial: entry.title, confirmLabel: L("Rename")
                ) { name in controller.renameTab(at: index, to: name) }
            }
            row.onMenu = { [weak self, weak row] in
                guard let self, let anchor = row else { return }
                ShellMenuPopover.present(from: anchor, items: [
                    .action(L("Rename tab")) { [weak self] in
                        guard let controller = self?.controller else { return }
                        NameEditorPopover.present(
                            from: anchor, title: L("Rename tab"),
                            initial: entry.title, confirmLabel: L("Rename")
                        ) { name in controller.renameTab(at: index, to: name) }
                    },
                ])
            }
            row.onClose = { [weak self] in self?.controller?.closeTab(at: index) }
            // 组与组之间加一档呼吸：紧凑单行 pane 后，块的边界靠这 8pt 成立
            if let last = rowsStack.arrangedSubviews.last {
                rowsStack.setCustomSpacing(8, after: last)
            }
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

    private func toggleTabCollapse(_ tabID: UUID) {
        if collapsedTabIDs.contains(tabID) {
            collapsedTabIDs.remove(tabID)
        } else {
            collapsedTabIDs.insert(tabID)
        }
        reload()
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
            // 落点提示：跳转可能伴随标签页切换，多分屏下必须告诉视线去哪
            pane.flashReveal()
        }
        paneRow.onClose = { [weak pane] in
            pane?.terminal.requestCloseFromUser()
        }
        paneRow.onPaneDrop = { [weak self, weak pane] sourceID in
            guard let self, let pane else { return false }
            return self.controller?.movePane(withID: sourceID, to: pane, zone: .right) ?? false
        }
        paneRow.onBeginDrag = { [weak self, weak paneRow] event in
            guard let self, let paneRow else { return }
            self.beginPaneRowDrag(source: paneRow, paneID: pane.dragIdentifier, event: event)
        }
        paneRows[pane.dragIdentifier] = paneRow
        return paneRow
    }

    // MARK: - pane 行拖拽（手动跟手循环，与任务列表同一套机件）

    /// 接管一条 pane 行的拖拽：快照浮层 1:1 跟随光标（浮在整条侧栏之上，不被
    /// scroll 裁剪），逐帧命中兄弟行（pane 行 / 标签页行）并高亮落点；释放时
    /// 走既有的移动通路（落在 pane 行 = 移到其右侧分屏，落在标签页行 = 移入该
    /// 标签页）。与任务列表的重排共用 ReorderDrag，手感一致。
    private func beginPaneRowDrag(source: PaneRowView, paneID: UUID, event: NSEvent) {
        guard let image = ReorderDrag.snapshot(of: source) else { return }
        let startFrame = convert(source.bounds, from: source)  // self（非翻转）坐标
        let snap = ReorderDrag.makeSnapshot(image, frame: startFrame)
        addSubview(snap)
        // 与任务列表同款：源行原地隐身但保留占位 = 随光标流动的空档，其余 pane
        // 行让位。alpha 0（不是 isHidden）才会保住这条槽位当空档。
        source.alphaValue = 0

        let cursorInSelf = convert(event.locationInWindow, from: nil)
        let grabOffsetY = cursorInSelf.y - startFrame.minY

        // 源行在 arranged 序列中的插入位（以“排除源行后的其余行”为基准）。
        func others() -> [NSView] { rowsStack.arrangedSubviews.filter { $0 !== source } }
        func applied() -> Int {  // 源行当前落在 others 里的哪个插入位
            let arranged = rowsStack.arrangedSubviews
            let si = arranged.firstIndex(of: source) ?? 0
            return arranged[..<si].filter { $0 !== source }.count
        }
        // 起手时的邻居快照，用于结束时判空动（没真动就不折腾 split 树）。
        let (origPrev, origNext) = neighborPaneIDs(of: source)
        var lastIdx = applied()

        ReorderDrag.run(
            host: self,
            snapshotView: snap,
            startEvent: event,
            grabOffsetY: grabOffsetY,
            onMove: { [weak self] c in
                guard let self else { return }
                // 光标之上（self 非翻转：y 越大越靠上）的其余行数 = 目标插入位
                let peers = others()
                var idx = 0
                for v in peers {
                    if self.convert(v.bounds, from: v).midY > c.y { idx += 1 } else { break }
                }
                idx = min(max(idx, 1), peers.count)  // 不越过第一条标签页标题
                guard idx != lastIdx else { return }
                lastIdx = idx
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.16
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    ctx.allowsImplicitAnimation = true
                    self.rowsStack.removeArrangedSubview(source)
                    self.rowsStack.insertArrangedSubview(source, at: idx)
                    self.rowsStack.layoutSubtreeIfNeeded()
                }
            },
            dropFrame: { [weak self, weak source] in
                guard let self, let source else { return nil }
                return self.convert(source.bounds, from: source)  // 落进自己让出的空档
            },
            onCommit: { [weak self, weak source] in
                guard let self, let source else { return }
                self.commitPaneRowDrop(
                    source: source, paneID: paneID, origPrev: origPrev, origNext: origNext)
            },
            onEnd: { [weak self, weak source] in
                source?.alphaValue = 1
                self?.reload()
            }
        )
    }

    /// 源行在 arranged 序列里的同区上下相邻 pane（跨标签页标题即断，视为无邻居）。
    private func neighborPaneIDs(of source: PaneRowView) -> (prev: UUID?, next: UUID?) {
        let arranged = rowsStack.arrangedSubviews
        guard let si = arranged.firstIndex(of: source) else { return (nil, nil) }
        var prev: UUID?
        for v in arranged[..<si].reversed() {
            if v is TabRowView { break }
            if let r = v as? PaneRowView { prev = r.paneID; break }
        }
        var next: UUID?
        for v in arranged[(si + 1)...] {
            if v is TabRowView { break }
            if let r = v as? PaneRowView { next = r.paneID; break }
        }
        return (prev, next)
    }

    /// 把源行拖后的最终位置翻译成一次 split 树移动：优先落到“下方同区 pane 的左侧”，
    /// 否则“上方同区 pane 的右侧”，都没有则整体移进上方那个标签页。没真动则跳过。
    private func commitPaneRowDrop(
        source: PaneRowView, paneID: UUID, origPrev: UUID?, origNext: UUID?
    ) {
        let (prev, next) = neighborPaneIDs(of: source)
        guard prev != origPrev || next != origNext else { return }  // 没动，别折腾树
        func pane(_ id: UUID?) -> PaneView? {
            guard let id else { return nil }
            return controller?.panes().first { $0.dragIdentifier == id }
        }
        if let dest = pane(next) {
            _ = controller?.movePane(withID: paneID, to: dest, zone: .left)
        } else if let dest = pane(prev) {
            _ = controller?.movePane(withID: paneID, to: dest, zone: .right)
        } else if let wsIndex = tabIndexAbove(source) {
            _ = controller?.movePane(withID: paneID, toTabAt: wsIndex)
        }
    }

    /// 源行上方最近的标签页标题的 index（落进空/首位时用）。
    private func tabIndexAbove(_ source: PaneRowView) -> Int? {
        let arranged = rowsStack.arrangedSubviews
        guard let si = arranged.firstIndex(of: source) else { return nil }
        for v in arranged[..<si].reversed() {
            if let ws = v as? TabRowView { return ws.tabIndex }
        }
        return nil
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

/// 标签页行（容器级）：未激活时单击切换；已激活时单击折叠/展开 panes；
/// disclosure 始终直接切换折叠。双击改名；hover 显示重命名菜单与独立关闭键，
/// 关闭不在菜单里重复出现。
///
/// 活跃态只染强调色（图标 + 标题），不给填充——填充留给当前 pane 行独占。
/// 侧栏里可接收 pane 拖拽落点的行（标签页行 + pane 行）。手动拖拽循环
/// （见 ReorderDrag）据此统一命中与高亮，与任务列表同一套跟手机件。
private protocol SidebarPaneDropRow: NSView {
    func acceptsPaneDrop(_ id: UUID) -> Bool
    func performPaneDrop(_ id: UUID) -> Bool
    func setDropHighlighted(_ on: Bool)
}

private final class TabRowView: NSView, SidebarPaneDropRow {
    /// 拖拽落点映射用：空区落到本标签页时按此 index 走 movePane(toTabAt:)。
    var tabIndex = 0
    var onSelect: (() -> Void)?
    var onToggleCollapse: (() -> Void)?
    var onRename: (() -> Void)?
    var onMenu: (() -> Void)?
    var onClose: (() -> Void)?
    /// pane 拖到标签页行：移进该标签页。返回是否接受。
    var onPaneDrop: ((UUID) -> Bool)?

    private let isActive: Bool
    private let isCollapsed: Bool
    private let disclosureButton = NSButton()
    private let countLabel = NSTextField(labelWithString: "")
    private let menuButton = NSButton()
    private let closeButton = NSButton()
    private var tracking: NSTrackingArea?
    private var hovered = false {
        didSet {
            applyFill()
            applyGlyph()
            menuButton.isHidden = !hovered
            closeButton.isHidden = !hovered
            // 计数与 ⋯/✕ 共用行尾，hover 时让位
            countLabel.isHidden = hovered
        }
    }

    init(title: String, count: Int, isActive: Bool, isCollapsed: Bool) {
        self.isActive = isActive
        self.isCollapsed = isCollapsed
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        registerForDraggedTypes([.lighttyPaneID])
        HoverCursor.installPointingHand(on: self)

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12.5, weight: .semibold)
        label.textColor = isActive ? ShellStyle.accent : ShellStyle.secondaryText
        label.lineBreakMode = .byTruncatingTail

        disclosureButton.isBordered = false
        disclosureButton.imagePosition = .imageOnly
        disclosureButton.focusRingType = .none
        disclosureButton.target = self
        disclosureButton.action = #selector(toggleCollapse)
        disclosureButton.toolTip =
            isCollapsed ? L("Expand tab") : L("Collapse tab")
        applyGlyph()

        countLabel.stringValue = "\(count)"
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = ShellStyle.tertiaryText

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
            systemSymbolName: "xmark", accessibilityDescription: L("Close tab"))?
            .withSymbolConfiguration(.init(pointSize: 8.5, weight: .bold))
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.focusRingType = .none
        closeButton.contentTintColor = ShellStyle.secondaryText
        closeButton.isHidden = true
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.toolTip = L("Close tab")

        for v in [disclosureButton, label, countLabel, menuButton, closeButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            disclosureButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            disclosureButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosureButton.widthAnchor.constraint(equalToConstant: 18),
            disclosureButton.heightAnchor.constraint(equalToConstant: 22),
            label.leadingAnchor.constraint(equalTo: disclosureButton.trailingAnchor, constant: 3),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: menuButton.leadingAnchor, constant: -6),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
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

    /// Safari 标签页组同款：常态显示容器图标（与「新标签页」按钮同族的
    /// rectangle 组合），hover 换成折叠 chevron——同一个 18pt 插槽，不吃行宽。
    /// 折叠态在常态下不单独表达：pane 行消失 + 计数仍在，信息已经够了。
    private func applyGlyph() {
        if hovered {
            disclosureButton.image = NSImage(
                systemSymbolName: isCollapsed ? "chevron.right" : "chevron.down",
                accessibilityDescription: disclosureButton.toolTip)?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
            disclosureButton.contentTintColor = ShellStyle.secondaryText
        } else {
            disclosureButton.image = NSImage(
                systemSymbolName: "rectangle.on.rectangle",
                accessibilityDescription: L("Tab"))?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
            disclosureButton.contentTintColor =
                isActive ? ShellStyle.accent : ShellStyle.secondaryText
        }
    }

    private func applyFill() {
        // 活跃标签页不给填充（标题/图标已染强调色）；填充只表达 hover
        let fill: NSColor = hovered ? ShellStyle.selectionFill : .clear
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

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onRename?() } else { onSelect?() }
    }

    // MARK: - SidebarPaneDropRow
    func acceptsPaneDrop(_ id: UUID) -> Bool { true }   // 任何 pane 都能移进标签页
    func performPaneDrop(_ id: UUID) -> Bool { onPaneDrop?(id) ?? false }

    // MARK: - pane 落点

    private func acceptedPaneID(_ sender: NSDraggingInfo) -> UUID? {
        guard let raw = sender.draggingPasteboard.string(forType: .lighttyPaneID),
              let id = UUID(uuidString: raw) else { return nil }
        return id
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptedPaneID(sender) != nil else { return [] }
        setDropHighlighted(true)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { setDropHighlighted(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDropHighlighted(false)
        guard let id = acceptedPaneID(sender) else { return false }
        return onPaneDrop?(id) ?? false
    }

    func setDropHighlighted(_ on: Bool) {
        layer?.borderWidth = on ? 1.5 : 0
        layer?.borderColor =
            on ? ShellStyle.accentTint(0.7).shellResolvedCGColor(for: effectiveAppearance) : nil
    }
}

enum TabPaneStatusPresentation {
    /// 文字只表达三个值得打断扫读节奏的阶段：处理中、等待用户、已完成。
    /// 圆点仍按真实活动状态变色；tool hook 再密也不会让文字宽度反复跳动。
    static func text(for status: PaneStatus?) -> String? {
        guard let status else { return nil }
        switch status.state {
        case .idle: return nil
        case .thinking, .tool: return L("Thinking")
        case .attention: return L("Needs you")
        case .done: return L("Finished")
        }
    }

    /// tooltip / 菜单用的完整一行：状态动词 + 工具名 + detail 摘要。
    /// pane 头 tooltip 与菜单栏行共用，两处文案不许走岔。
    static func detailLine(for status: PaneStatus?) -> String? {
        guard let status, status.state != .idle else { return nil }
        var line: String
        switch status.state {
        case .thinking: line = L("Agent is thinking")
        case .tool: line = status.tool.map { L("Running %@", $0) } ?? L("Agent is working")
        case .attention: line = L("Agent needs your input")
        case .done: line = L("Agent finished")
        case .idle: return nil
        }
        // detail 来自 hook 写的文件，长度不可信（契约 §4.2 要求读方截断）
        if let detail = status.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
            !detail.isEmpty {
            line += " · " + String(detail.prefix(120))
        }
        return line
    }
}

/// pane 行（叶子级）：第一行 = 圆点 + pane 名 + 行尾轻量状态文字；
/// 第二行 = 绑定任务 + cwd（路径从头截断，优先保留末级目录）。
/// 曾试过砍掉第二行、cwd 挪 tooltip：悬浮气泡的观感和延迟都不如常驻
/// 次要色一行，用户点名要回来。
/// 当前 pane 用强调色淡底——全侧栏唯一的填充高亮；hover 时行尾出 ✕
/// （与标签页行的关闭位统一；内核关闭同路）。
/// pane header 胶囊的"圆点变 ✕"交互独立保留，不受此处影响。
private final class PaneRowView: NSView, SidebarPaneDropRow {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    /// 别的 pane 拖到本行：移到本 pane 右侧。返回是否接受。
    var onPaneDrop: ((UUID) -> Bool)?
    /// 起手拖拽本行（由所属 TabColumnView 接管跟手循环，与任务列表同款）。
    var onBeginDrag: ((NSEvent) -> Void)?

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
        registerForDraggedTypes([.lighttyPaneID])
        HoverCursor.installPointingHand(on: self)

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
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.textColor = ShellStyle.primaryText
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.toolTip = name
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

        statusLabel.isHidden = true
        statusLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        statusLabel.textColor = ShellStyle.secondaryText
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        for v in [dotView, closeButton, nameLabel, statusLabel, secondaryStack] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 42),

            // 嵌进标签页标题的文字轴之下再退一步，属地关系靠缩进本身表达；
            // 圆点跟第一行对齐，不悬在两行中间。
            dotView.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: indented ? 26 : 10),
            dotView.widthAnchor.constraint(equalToConstant: 6),
            dotView.heightAnchor.constraint(equalToConstant: 6),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),

            nameLabel.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 7),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            dotView.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),

            // 状态固定在行尾且保持完整；pane 名吃掉中间弹性空间，过长时先截断。
            // close 槽位始终预留，hover 出现 ✕ 时状态不会横跳。
            statusLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 6),
            statusLabel.trailingAnchor.constraint(
                equalTo: closeButton.leadingAnchor, constant: -4),
            statusLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),

            // 第二行顶到 pane 内容左轴；不再为第一行的状态圆点留空，
            // 路径也能多拿到 13pt 的有效宽度。
            secondaryStack.leadingAnchor.constraint(equalTo: dotView.leadingAnchor),
            secondaryStack.trailingAnchor.constraint(
                lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),
            secondaryStack.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            secondaryStack.bottomAnchor.constraint(
                lessThanOrEqualTo: bottomAnchor, constant: -4),
        ])
        applyDotColor()
        applyStatusLabel()
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
        // cwd 是第二行在无 OSC PWD 时的兜底；tool 名不进侧栏，避免高频跳字。
        guard self.status?.state != status?.state
                || self.status?.tool != status?.tool
                || self.status?.cwd != status?.cwd
        else { return }

        let previousActivity = activity
        let previousText = TabPaneStatusPresentation.text(for: self.status)
        let previousCWD = self.status?.cwd
        self.status = status

        // 圆点跟真实 activity 走；文字单独比较展示值，thinking ↔ tool 不重复写 label。
        if previousActivity != activity {
            applyDotColor()
            applyFill()
        }
        if previousText != TabPaneStatusPresentation.text(for: status) {
            applyStatusLabel()
        }
        if previousCWD != status?.cwd {
            applyMetadataLine()
        }
    }

    /// 活动状态与 pane 名同在第一行；空闲时隐藏，不用任务名补位。
    ///
    /// **颜色不能单独承担语义**——用户没有图例就是在猜"蓝色是什么意思"。
    /// 圆点负责快速扫色，次级文字负责解释语义；不再铺 badge 底色与当前行
    /// 高亮争抢视觉重心。任务名是稳定信息，固定保留在第二行。
    private func applyStatusLabel() {
        if let text = TabPaneStatusPresentation.text(for: status) {
            statusLabel.isHidden = false
            statusLabel.stringValue = text
            statusLabel.toolTip = text
        } else {
            statusLabel.isHidden = true
            // hidden 不会自动退出 Auto Layout；清空 intrinsic width，
            // 空闲时把空间还给 pane 名。
            statusLabel.stringValue = ""
            statusLabel.toolTip = nil
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

    private func applyDotColor() {
        dotView.layer?.backgroundColor = ShellStyle
            .dotColor(bound: bound, activity: activity)
            .shellResolvedCGColor(for: effectiveAppearance)
    }

    private func applyFill() {
        // 当前 pane 的强调色淡底是全侧栏唯一的填充高亮，压过 hover 与状态底。
        // `done` 给一层极淡的同色底——侧栏是"哪个 pane 完事了"的扫读面，
        // 一个 6pt 的点在满屏行里不够抓眼，整行透一点色才扫得出来。
        if isActive {
            layer?.backgroundColor = ShellStyle.accentTint(0.12)
                .shellResolvedCGColor(for: effectiveAppearance)
        } else if hovered {
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
        applyStatusLabel()
        applyFill()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyDotColor()
        applyStatusLabel()
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

    // MARK: - 拖拽（源 + 落点）

    /// 与 PaneHeaderView 同款 click/drag 分流：3pt 内是点击，超出启动 pane 拖拽。
    override func mouseDown(with event: NSEvent) {
        let origin = event.locationInWindow
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
        while let next = NSApp.nextEvent(
            matching: mask, until: .distantFuture, inMode: .eventTracking, dequeue: true
        ) {
            switch next.type {
            case .leftMouseDragged:
                let dx = next.locationInWindow.x - origin.x
                let dy = next.locationInWindow.y - origin.y
                guard hypot(dx, dy) >= 3 else { continue }
                onBeginDrag?(next)
                return
            case .leftMouseUp:
                onSelect?()
                return
            default:
                continue
            }
        }
    }

    // MARK: - SidebarPaneDropRow
    func acceptsPaneDrop(_ id: UUID) -> Bool { id != paneID }
    func performPaneDrop(_ id: UUID) -> Bool { onPaneDrop?(id) ?? false }

    // 落点：把别的 pane 拖到本行 = 移到本 pane 所在处（右侧分屏）
    private func acceptedPaneID(_ sender: NSDraggingInfo) -> UUID? {
        guard let raw = sender.draggingPasteboard.string(forType: .lighttyPaneID),
              let id = UUID(uuidString: raw), id != paneID else { return nil }
        return id
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptedPaneID(sender) != nil else { return [] }
        setDropHighlighted(true)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { setDropHighlighted(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDropHighlighted(false)
        guard let id = acceptedPaneID(sender) else { return false }
        return onPaneDrop?(id) ?? false
    }

    func setDropHighlighted(_ on: Bool) {
        layer?.borderWidth = on ? 1.5 : 0
        layer?.borderColor =
            on ? ShellStyle.accentTint(0.7).shellResolvedCGColor(for: effectiveAppearance) : nil
    }
}
