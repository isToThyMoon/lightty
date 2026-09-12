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
///
/// 叶子标签页：标签页只有一个 pane、且还叫默认名时，容器行和 pane 行合并成一条
/// ——「标签页 N · 1」两样都是空信息，独占一行只会让列表变重。合并行沿用两级树的
/// 网格：标签页图标占容器行图标那一列，pane 内容从子级缩进位起，看上去仍是"标签页
/// 包着一个 pane"。行本身是 pane 行（状态原地更新、拖拽源），标签页语义叠在上面：
/// 落点 = 移入该标签页，⋯ / 双击 = 重命名标签页。
/// 用户给标签页起了名字，它就有了自己的身份，恢复容器行 + pane 行呈现，名字始终可见；
/// 开出第二个分屏同样展开成两级树，关回一个（且仍是默认名）再收回。
/// 侧栏一行的身份。每一项都记住所属标签页：拖拽落点要分辨"落在某个标签页的
/// pane 块里"还是"落在两个标签页之间"，没有归属就分辨不了。
/// `leaf` = 单 pane 标签页的合并行：它既是可拖走的 pane，本身又是一个标签页。
enum TabRowKind: Equatable {
    case tab(Int)
    case pane(tab: Int, pane: UUID)
    case leaf(tab: Int, pane: UUID)
}

final class TabColumnView: NSView, NSTableViewDataSource, NSTableViewDelegate {
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
    private let clearTabsButton = ShellIconButton(
        symbol: "ellipsis", accessibilityLabel: L("More actions"), target: nil, action: nil)
    private let scroll = SidebarListScrollView()
    private let table = NSTableView()
    private struct RowItem {
        let kind: TabRowKind
        let makeView: (NSView?) -> NSView
    }
    private var rowItems: [RowItem] = []
    /// pane 行按 pane id 索引，供状态原地更新用。
    /// 不能走 `reload()`：它拆掉重建每一行，而状态是高频的
    /// （一次工具调用就有 PreToolUse + PostToolUse 两发），拆建必闪。
    private let paneRows = NSMapTable<NSUUID, PaneRowView>(keyOptions: .strongMemory, valueOptions: .weakMemory)
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
        clearTabsButton.target = self
        clearTabsButton.action = #selector(clearTabs)

        let column = NSTableColumn(identifier: .init("tab-tree"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.setAccessibilityLabel(L("Tabs"))
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        for v in [sectionLabel, clearTabsButton, splitRightButton, splitDownButton, newTabButton, scroll] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            // 首行行心对齐 pane header 行心（两者都从各自 chrome 顶开始 + 14）
            newTabButton.topAnchor.constraint(equalTo: topAnchor),
            newTabButton.trailingAnchor.constraint(equalTo: clearTabsButton.leadingAnchor, constant: -1),
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
            clearTabsButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            clearTabsButton.centerYAnchor.constraint(equalTo: newTabButton.centerYAnchor),
            clearTabsButton.widthAnchor.constraint(equalToConstant: 28),
            clearTabsButton.heightAnchor.constraint(equalToConstant: 28),

            scroll.topAnchor.constraint(equalTo: newTabButton.bottomAnchor, constant: 12),
            // Keep the leading gutter; the shared trailing rail keeps scrolling clear of row actions.
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SidebarListScrollView.trailingMargin),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

        ])

        // Handoff 任务绑定/改名/解绑经 lighttyTasksDidChange 广播；标签页结构变化
        // 由 TerminalWindowController.refreshTabStrip 直接调 reload。
        NotificationCenter.default.addObserver(
            self, selector: #selector(scheduleReload),
            name: .lighttyTasksDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    func numberOfRows(in tableView: NSTableView) -> Int { rowItems.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rowItems[row].kind {
        case .tab: return row == 0 ? 30 : 36
        case .pane: return 42
        // 叶子行之间比同标签页内的 pane 行多留一点气口（它们是不同的标签页），
        // 但比容器行的组间距小一档，列表不至于散。
        case .leaf: return row == 0 ? 42 : 46
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier: NSUserInterfaceItemIdentifier
        switch rowItems[row].kind {
        case .tab: identifier = .init("tab-row")
        case .pane: identifier = .init("pane-row")
        // 缩进在 PaneRowView 初始化时定死，叶子行与缩进 pane 行不共用复用池。
        case .leaf: identifier = .init("leaf-row")
        }
        let container = tableView.makeView(withIdentifier: identifier, owner: nil) as? TabRowContainer ?? TabRowContainer()
        container.identifier = identifier
        container.bind(rowItems[row].makeView(container.content))
        return container
    }

    override func layout() {
        super.layout()
        let width = scroll.contentSize.width
        if table.frame.width != width {
            table.setFrameSize(NSSize(width: width, height: table.frame.height))
            table.tableColumns.first?.width = width
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: .lighttySessionLibraryDidChange, object: nil)
        if window != nil {
            reload()
            if let library = controller?.sessionLibrary {
                NotificationCenter.default.addObserver(self, selector: #selector(sessionsDidChange(_:)),
                    name: .lighttySessionLibraryDidChange, object: library)
            }
        }
    }

    @objc private func sessionsDidChange(_ notification: Notification) {
        guard let change = SessionChange.from(notification), let controller else { return }
        for id in change.panes.keys {
            guard let state = controller.sessionLibrary.paneState(for: id) else { continue }
            paneRows.object(forKey: id as NSUUID)?.applySession(state)
        }
        if change.windows.contains(controller.sessionWindowID) {
            applyActivePane(controller.sessionLibrary.selectedPane(in: controller.sessionWindowID))
        }
    }

    /// pane 焦点变化只原地切换行底色，不拆建标签页树。
    func applyActivePane(_ paneID: UUID?) {
        for case let row as PaneRowView in paneRows.objectEnumerator() ?? NSEnumerator() {
            row.setActive(row.paneID == paneID)
        }
    }

    private lazy var reloads = Coalescer(.nextTick) { [weak self] in self?.reload() }
    @objc private func scheduleReload() { reloads.schedule() }

    @objc private func newTab() {
        // 有活跃 pane 时走 Ghostty action 通路：新标签页继承当前 pane 的
        // cwd/font/context。空态（全部标签页已关）没有活跃 pane，直接建一个。
        if let active = controller?.activePane {
            active.terminal.performBindingAction("new_tab")
        } else {
            controller?.addTab(initialPane: PaneView())
        }
    }

    @objc private func clearTabs() {
        ShellMenuPopover.present(from: clearTabsButton, items: [
            .action(L("Close all tabs in this window"), destructive: true) { [weak self] in
                self?.controller?.requestClearTabs()
            },
        ])
    }

    @objc private func splitRight() {
        controller?.activePane?.terminal.performBindingAction("new_split:right")
    }

    @objc private func splitDown() {
        controller?.activePane?.terminal.performBindingAction("new_split:down")
    }

    func reload() {
        guard let controller else { return }
        reload(overview: controller.tabOverview())
    }

    typealias OverviewEntry = (
        id: UUID, index: Int, title: String, hasCustomTitle: Bool, isActive: Bool, panes: [PaneView])
    private struct TabPresentation {
        let id: UUID
        let index: Int
        let title: String
        let isActive: Bool
        let count: Int
    }

    func reload(overview: [OverviewEntry]) {
        rowItems.removeAll(keepingCapacity: true)
        paneRows.removeAllObjects()
        collapsedTabIDs.formIntersection(overview.map(\.id))
        for entry in overview {
            if entry.panes.count == 1, !entry.hasCustomTitle, let pane = entry.panes.first {
                // 叶子标签页：折叠对它无意义，折叠集合里的残留不影响它。
                let index = entry.index
                let title = entry.title
                rowItems.append(RowItem(kind: .leaf(tab: index, pane: pane.dragIdentifier),
                    makeView: { [weak self, weak pane] existing in
                        guard let self, let pane else { return NSView() }
                        return self.makeLeafRow(for: pane, tabIndex: index, tabTitle: title,
                            reusing: existing as? PaneRowView)
                    }))
                continue
            }
            let isCollapsed = collapsedTabIDs.contains(entry.id)
            let presentation = TabPresentation(id: entry.id, index: entry.index, title: entry.title,
                isActive: entry.isActive, count: entry.panes.count)
            rowItems.append(RowItem(kind: .tab(entry.index), makeView: { [weak self] existing in
                self?.makeTabRow(presentation, isCollapsed: isCollapsed, reusing: existing as? TabRowView) ?? NSView()
            }))

            guard !isCollapsed else { continue }
            for pane in entry.panes {
                rowItems.append(RowItem(kind: .pane(tab: entry.index, pane: pane.dragIdentifier), makeView: { [weak self, weak pane] existing in
                    guard let self, let pane else { return NSView() }
                    return self.makePaneRow(for: pane, leading: .nested,
                        isActive: pane.dragIdentifier == self.controller?.activePane?.dragIdentifier,
                        reusing: existing as? PaneRowView)
                }))
            }
        }
        table.reloadData()
        window?.invalidateCursorRects(for: self)
    }

    private func makeTabRow(_ entry: TabPresentation, isCollapsed: Bool, reusing existing: TabRowView?) -> TabRowView {
        let index = entry.index
        let tabID = entry.id
        let wasActive = entry.isActive
        let row = existing ?? TabRowView(
            title: entry.title,
            count: entry.count,
            isActive: entry.isActive,
            isCollapsed: isCollapsed)
        row.configure(title: entry.title, count: entry.count, isActive: entry.isActive, isCollapsed: isCollapsed)
        row.tabIndex = index
        row.onSelect = { [weak self] in
            guard let self else { return }
            if wasActive {
                self.toggleTabCollapse(tabID)
            } else {
                // 切到一个折叠着的标签页时顺手展开：选中它就是要看它的 pane
                self.collapsedTabIDs.remove(tabID)
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
        return row
    }

    private func toggleTabCollapse(_ tabID: UUID) {
        if collapsedTabIDs.contains(tabID) {
            collapsedTabIDs.remove(tabID)
        } else {
            collapsedTabIDs.insert(tabID)
        }
        reload()
    }

    /// 单 pane 标签页的合并行：pane 行的皮、标签页的骨。
    private func makeLeafRow(
        for pane: PaneView,
        tabIndex: Int,
        tabTitle: String,
        reusing existing: PaneRowView?
    ) -> PaneRowView {
        let row = makePaneRow(for: pane, leading: .leafTab,
            isActive: pane.dragIdentifier == controller?.activePane?.dragIdentifier,
            reusing: existing)
        // 落点语义换成标签页的：拖进来 = 移入该标签页（内核会把它排到这个 pane 旁边）。
        row.onPaneDrop = { [weak self] sourceID in
            self?.controller?.movePane(withID: sourceID, toTabAt: tabIndex) ?? false
        }
        let rename: () -> Void = { [weak self, weak row] in
            guard let self, let anchor = row, let controller = self.controller else { return }
            NameEditorPopover.present(
                from: anchor, title: L("Rename tab"),
                initial: tabTitle, confirmLabel: L("Rename")
            ) { name in controller.renameTab(at: tabIndex, to: name) }
        }
        row.onRename = rename
        row.onMenu = { [weak row] in
            guard let anchor = row else { return }
            ShellMenuPopover.present(from: anchor, items: [.action(L("Rename tab"), handler: rename)])
        }
        return row
    }

    private func makePaneRow(
        for pane: PaneView,
        leading: PaneRowView.Leading,
        isActive: Bool,
        reusing existing: PaneRowView? = nil
    ) -> PaneRowView {
        let state = pane.sessionState
        if let existing, paneRows.object(forKey: existing.paneID as NSUUID) === existing {
            paneRows.removeObject(forKey: existing.paneID as NSUUID)
        }
        let paneRow = existing ?? PaneRowView(
            paneID: pane.dragIdentifier,
            name: state.title,
            taskName: pane.header.titleOfBoundTask,
            bound: pane.header.titleOfBoundTask != nil,
            leading: leading,
            isActive: isActive,
            workingDirectory: state.workingDirectory)
        paneRow.configure(paneID: pane.dragIdentifier, name: state.title,
            taskName: pane.header.titleOfBoundTask, isActive: isActive,
            workingDirectory: state.workingDirectory, sessionAgent: state.sessionKey?.agent)
        // 标签页语义的回调只有叶子行会装；普通 pane 行复用时必须清掉。
        paneRow.onMenu = nil
        paneRow.onRename = nil
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
        paneRow.onBeginDrag = { [weak self, weak paneRow, weak pane] event in
            guard let self, let paneRow, let pane else { return }
            self.beginPaneRowDrag(source: paneRow, paneID: pane.dragIdentifier, event: event)
        }
        paneRow.applySession(state)
        paneRows.setObject(paneRow, forKey: pane.dragIdentifier as NSUUID)
        return paneRow
    }

    // MARK: - 行拖拽（手动跟手循环，与任务列表同一套机件）

    /// 拖拽落点只有两种语义，因为列表只有两级：
    /// - `insideTab`：落在某个标签页的 pane 块里 → 并进那棵分屏树。
    /// - `betweenTabs`：落在两个标签页之间 → 顶层重排。源行是整条标签页（叶子行）
    ///   就换标签页的位次；源行是某个标签页里的分屏 pane，就把它拆出来独立成新标签页。
    ///
    /// 判定只看紧邻：下方紧邻是缩进 pane 行，说明落点在那个标签页块内；否则看上方。
    /// 两边都不是缩进 pane 行，落点就在标签页之间。折叠的标签页在列表里只有一行，
    /// 对它而言"块内"不存在——要并进去得把行拖到它身上（见 MergeTarget）。
    enum DropSlot: Equatable {
        case insideTab(next: UUID?, previous: UUID?)
        case betweenTabs(Int)
    }

    /// 合并落点：光标压在某一行的中央带上时，意图是"并进这一行"而不是"插到它前后"。
    /// 这是拖动排序与拖动合并的分界——中央带合并，上下两端排序，与 iOS 主屏建文件夹、
    /// 浏览器标签页成组是同一套肌肉记忆。合并期间停止让位，目标行不会在脚下移动。
    private struct MergeTarget {
        let row: Int
        let kind: TabRowKind
    }

    /// 行高的这个比例之内算中央带（上下各留 25% 给排序）。
    private static let mergeBand: CGFloat = 0.25

    private var mergeTarget: MergeTarget?

    /// 接管一条 pane 行 / 叶子行的拖拽：快照浮层 1:1 跟随光标（浮在整条侧栏之上，
    /// 不被 scroll 裁剪），逐帧判定是排序还是合并；释放时翻译成一次真实移动。
    private func beginPaneRowDrag(source: PaneRowView, paneID: UUID, event: NSEvent) {
        guard let image = ReorderDrag.snapshot(of: source) else { return }
        let startFrame = convert(source.bounds, from: source)  // self（非翻转）坐标
        let snap = ReorderDrag.makeSnapshot(image, frame: startFrame)
        addSubview(snap)
        // 与任务列表同款：源行原地隐身但保留占位 = 随光标流动的空档，其余行让位。
        // alpha 0（不是 isHidden）才会保住这条槽位当空档。
        source.alphaValue = 0

        let cursorInSelf = convert(event.locationInWindow, from: nil)
        let grabOffsetY = cursorInSelf.y - startFrame.minY

        // 源行是整条标签页（叶子行）还是标签页里的一个分屏 pane，决定顶层落点的动作。
        let sourceTab: Int? = sourceIndex(paneID).flatMap {
            if case .leaf(let tab, _) = rowItems[$0].kind { return tab }
            return nil
        }
        // 起手时的落点，用于结束时判空动（没真动就不折腾树）。
        let origin = dropSlot(for: paneID)
        var lastIndex = sourceIndex(paneID) ?? 0

        ReorderDrag.run(
            host: self,
            snapshotView: snap,
            startEvent: event,
            grabOffsetY: grabOffsetY,
            onMove: { [weak self] c in
                guard let self else { return }
                if self.updateMergeTarget(at: c, sourceID: paneID) { return }  // 合并态不让位
                // 光标之上（self 非翻转：y 越大越靠上）的其余行数 = 目标插入位
                let from = self.sourceIndex(paneID)
                let peers = self.rowItems.indices.filter { $0 != from }
                var index = 0
                for peer in peers {
                    guard self.convert(self.table.rect(ofRow: peer), from: self.table).midY > c.y
                    else { break }
                    index += 1
                }
                index = min(max(index, 0), peers.count)
                guard index != lastIndex, let from else { return }
                lastIndex = index
                let item = self.rowItems.remove(at: from)
                self.rowItems.insert(item, at: index)
                self.table.beginUpdates()
                self.table.moveRow(at: from, to: index)
                self.table.endUpdates()
            },
            dropFrame: { [weak self] in
                guard let self else { return nil }
                // 合并时浮层飞进目标行，落点看得见。
                let row = self.mergeTarget?.row ?? self.sourceIndex(paneID)
                guard let row else { return nil }
                return self.convert(self.table.rect(ofRow: row), from: self.table)
            },
            onCommit: { [weak self] in
                self?.commitRowDrop(paneID: paneID, sourceTab: sourceTab, origin: origin)
            },
            onEnd: { [weak self, weak source] in
                source?.alphaValue = 1
                self?.setMergeTarget(nil)
                self?.reload()
            }
        )
    }

    /// 光标是否压在某一行的中央带上。是则进入合并态（高亮目标行）并返回 true。
    private func updateMergeTarget(at cursor: NSPoint, sourceID: UUID) -> Bool {
        let source = sourceIndex(sourceID)
        for row in rowItems.indices where row != source {
            let rect = convert(table.rect(ofRow: row), from: table)
            guard rect.contains(NSPoint(x: rect.midX, y: cursor.y)) else { continue }
            guard abs(cursor.y - rect.midY) <= rect.height * Self.mergeBand else { break }
            setMergeTarget(MergeTarget(row: row, kind: rowItems[row].kind))
            return true
        }
        setMergeTarget(nil)
        return false
    }

    private func setMergeTarget(_ target: MergeTarget?) {
        guard mergeTarget?.row != target?.row else { return }
        if let previous = mergeTarget?.row { dropRow(at: previous)?.setDropHighlighted(false) }
        mergeTarget = target
        if let row = target?.row { dropRow(at: row)?.setDropHighlighted(true) }
    }

    private func dropRow(at index: Int) -> (any SidebarPaneDropRow)? {
        guard rowItems.indices.contains(index) else { return nil }
        let container = table.view(atColumn: 0, row: index, makeIfNecessary: false)
        return (container as? TabRowContainer)?.content as? any SidebarPaneDropRow
    }

    /// 源行落定后的位置翻译成落点语义。
    private func dropSlot(for paneID: UUID) -> DropSlot? {
        guard let si = sourceIndex(paneID) else { return nil }
        return Self.dropSlot(in: rowItems.map(\.kind), sourceIndex: si)
    }

    /// 纯函数：只看落定后的行序与源行位置。拖拽循环没法在单测里跑，判定逻辑
    /// 单独摘出来才测得动。
    static func dropSlot(in rows: [TabRowKind], sourceIndex si: Int) -> DropSlot? {
        guard rows.indices.contains(si) else { return nil }
        if si + 1 < rows.count, case .pane(_, let id) = rows[si + 1] {
            return .insideTab(next: id, previous: nil)
        }
        if si > 0, case .pane(_, let id) = rows[si - 1] {
            return .insideTab(next: nil, previous: id)
        }
        // 顶层位次 = 上方还有几个标签页（容器行 + 叶子行各算一个，源行自己不算）。
        var index = 0
        for row in rows[..<si] {
            switch row {
            case .tab, .leaf: index += 1
            case .pane: continue
            }
        }
        return .betweenTabs(index)
    }

    /// 把落点翻译成一次真实移动。合并优先：它是用户明确压在某一行上的意图。
    private func commitRowDrop(paneID: UUID, sourceTab: Int?, origin: DropSlot?) {
        guard let controller else { return }
        if let merge = mergeTarget {
            switch merge.kind {
            case .tab(let index):
                controller.movePane(withID: paneID, toTabAt: index)
            case .pane(_, let id), .leaf(_, let id):
                guard let destination = pane(id) else { return }
                controller.movePane(withID: paneID, to: destination, zone: .right)
            }
            return
        }
        guard let slot = dropSlot(for: paneID), slot != origin else { return }
        switch slot {
        case .insideTab(let next, let previous):
            if let destination = pane(next) {
                controller.movePane(withID: paneID, to: destination, zone: .left)
            } else if let destination = pane(previous) {
                controller.movePane(withID: paneID, to: destination, zone: .right)
            }
        case .betweenTabs(let index):
            if let sourceTab {
                controller.moveTab(from: sourceTab, to: index)
            } else {
                controller.detachPane(withID: paneID, toNewTabAt: index)
            }
        }
    }

    private func pane(_ id: UUID?) -> PaneView? {
        guard let id else { return nil }
        return controller?.panes().first { $0.dragIdentifier == id }
    }

    private func sourceIndex(_ paneID: UUID) -> Int? {
        rowItems.firstIndex {
            switch $0.kind {
            case .pane(_, let id), .leaf(_, let id): return id == paneID
            case .tab: return false
            }
        }
    }
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

private final class TabRowContainer: NSView {
    private(set) var content: NSView?
    func bind(_ view: NSView) {
        guard content !== view else { return }
        content?.removeFromSuperview()
        content = view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

private final class TabRowView: NSView, SidebarPaneDropRow, SidebarHoverRow {
    /// 拖拽落点映射用：空区落到本标签页时按此 index 走 movePane(toTabAt:)。
    var tabIndex = 0
    var onSelect: (() -> Void)?
    var onToggleCollapse: (() -> Void)?
    var onRename: (() -> Void)?
    var onMenu: (() -> Void)?
    var onClose: (() -> Void)?
    /// pane 拖到标签页行：移进该标签页。返回是否接受。
    var onPaneDrop: ((UUID) -> Bool)?

    private var isActive: Bool
    private var isCollapsed: Bool
    private let label = NSTextField(labelWithString: "")
    private let disclosureButton = NSButton()
    private let countLabel = NSTextField(labelWithString: "")
    private let menuButton = NSButton()
    private let closeButton = NSButton()
    private var tracking: NSTrackingArea?
    /// 当前字形的身份；未变化时不重设 image——`NSButtonCell.setImage` 会让整套
    /// 按钮样式失效重算，而 `configure` 每次复用都会走到这里。
    private var glyphKey: String?
    private var hovered = false {
        didSet {
            guard oldValue != hovered else { return }
            applyFill()
            applyGlyph()
            menuButton.isHidden = !hovered
            closeButton.isHidden = !hovered
            // tooltip 只在 hover 时挂：NSToolTipManager 每帧都会重算所有已注册
            // tooltip 的矩形，几十行常驻就是滚动期的一笔固定开销。
            closeButton.toolTip = hovered ? L("Close tab") : nil
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

        label.stringValue = title
        label.font = .systemFont(ofSize: 12.5, weight: .semibold)
        label.textColor = isActive ? ShellStyle.navigationAccent : ShellStyle.primaryText
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

        menuButton.image = SymbolImages.image(
            "ellipsis", pointSize: 10, weight: .medium, description: L("More actions"))
        menuButton.isBordered = false
        menuButton.imagePosition = .imageOnly
        menuButton.focusRingType = .none
        menuButton.contentTintColor = ShellStyle.secondaryText
        menuButton.isHidden = true
        menuButton.target = self
        menuButton.action = #selector(menuTapped)

        closeButton.image = SymbolImages.image(
            "xmark", pointSize: 8.5, weight: .bold, description: L("Close tab"))
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.focusRingType = .none
        closeButton.contentTintColor = ShellStyle.secondaryText
        closeButton.isHidden = true
        closeButton.target = self
        closeButton.action = #selector(closeTapped)

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
    func configure(title: String, count: Int, isActive: Bool, isCollapsed: Bool) {
        sidebarHoverExited()
        hovered = false
        alphaValue = 1
        setDropHighlighted(false)
        self.isActive = isActive
        self.isCollapsed = isCollapsed
        label.stringValue = title
        label.textColor = isActive ? ShellStyle.navigationAccent : ShellStyle.primaryText
        countLabel.stringValue = "\(count)"
        disclosureButton.toolTip = isCollapsed ? L("Expand tab") : L("Collapse tab")
        applyGlyph()
        applyFill()
    }
    @objc private func menuTapped() { onMenu?() }
    @objc private func closeTapped() { onClose?() }

    /// Safari 标签页组同款：始终显示容器图标（与「新标签页」按钮同族的 rectangle
    /// 组合）。hover 不换成折叠 chevron——同一个位置换图标只会让人以为多了一个控件。
    /// 折叠态改用同一形状的实心版表达：空心=展开（看得进去），实心=收起（pane 都
    /// 收在里面）。形状不变，所以仍然只是「标签页图标」的两种样子。
    private func applyGlyph() {
        let key = "tab:\(isActive):\(isCollapsed)"
        guard key != glyphKey else { return }
        glyphKey = key
        disclosureButton.image = SymbolImages.image(
            isCollapsed ? "rectangle.fill.on.rectangle.fill" : "rectangle.on.rectangle",
            pointSize: 10, weight: .medium,
            description: isCollapsed ? L("Collapsed tab") : L("Tab"))
        disclosureButton.contentTintColor =
            isActive ? ShellStyle.navigationAccent : ShellStyle.secondaryText
    }

    private func applyFill() {
        // 活跃标签页：导航色淡底（比活跃 pane 行更淡一档，两级同色系不打架）；
        // hover 用中性选中底，压过活跃底以给出可点反馈。
        let fill: NSColor
        if hovered {
            fill = ShellStyle.selectionFill
        } else if isActive {
            fill = ShellStyle.navigationTint(0.08)
        } else {
            fill = .clear
        }
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
        // .inVisibleRect 由 AppKit 自行跟随可见区，建一次即可。滚动时 AppKit 每帧
        // 都会调到这里，反复 remove/add 是侧栏滚动期主线程的固定开销之一。
        guard tracking == nil else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    func setSidebarHovered(_ value: Bool) { hovered = value }
    override func mouseEntered(with event: NSEvent) { sidebarHoverEntered() }
    override func mouseExited(with event: NSEvent) { sidebarHoverExited() }

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
            on ? ShellStyle.navigationTint(0.7).shellResolvedCGColor(for: effectiveAppearance) : nil
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
private final class PaneRowView: NSView, SidebarPaneDropRow, SidebarHoverRow {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    /// 别的 pane 拖到本行：移到本 pane 右侧。返回是否接受。
    var onPaneDrop: ((UUID) -> Bool)?
    /// 起手拖拽本行（由所属 TabColumnView 接管跟手循环，与任务列表同款）。
    var onBeginDrag: ((NSEvent) -> Void)?
    /// 叶子标签页行才装：hover 出 ⋯ 菜单、双击改名。普通 pane 行为 nil，行尾不留槽位。
    var onMenu: (() -> Void)? { didSet { applyMenuSlot() } }
    var onRename: (() -> Void)?

    /// 行首形态。`nested`：标签页下的子行，圆点缩进到子级位；`leafTab`：单 pane 标签页
    /// 的合并行，标签页图标占容器行图标那一列、pane 内容仍从子级位起——两种行的
    /// pane 文字轴严格对齐，列表扫下来是一条直线。
    enum Leading { case nested, leafTab }

    /// 行持有 pane 身份（以前只拿到一堆字符串），才谈得上原地更新。
    /// 存 id 而不是 pane 引用：行只需要向 store 取状态，不需要够到 pane 本体，
    /// 少一条会让关掉的 pane 多活一会儿的强/弱引用。
    private(set) var paneID: UUID

    private let dotView = NSView()
    private let closeButton = NSButton()
    private let menuButton = NSButton()
    private var menuButtonWidth: NSLayoutConstraint!
    /// 叶子标签页行的标签页图标（与容器行同一字形、同一列），nested 行没有。
    private let tabGlyph: NSImageView?
    private var tracking: NSTrackingArea?
    private var bound: Bool
    private var taskName: String?
    private let nameLabel = NSTextField(labelWithString: "")
    private let agentIcon = NSImageView()
    private var displayedAgent: SessionAgent?
    private var agentIconWidth: NSLayoutConstraint!
    private var agentIconGap: NSLayoutConstraint!
    private let taskLabel = NSTextField(labelWithString: "")
    private let directoryLabel = NSTextField(labelWithString: "")
    private let statusLabel = PaneStatusLabel()
    private var status: PaneStatus?
    private var isUnread = false
    private var terminalWorkingDirectory: String?
    private var activity: PaneActivity? { status?.state }
    private var isActive: Bool
    private var hovered = false {
        didSet {
            guard oldValue != hovered else { return }
            applyFill()
            closeButton.isHidden = !hovered
            menuButton.isHidden = !hovered || onMenu == nil
            applyToolTips()
        }
    }

    init(
        paneID: UUID,
        name: String,
        taskName: String?,
        bound: Bool,
        leading: Leading,
        isActive: Bool,
        workingDirectory: String?
    ) {
        self.paneID = paneID
        self.bound = bound
        self.taskName = taskName
        self.isActive = isActive
        terminalWorkingDirectory = workingDirectory
        tabGlyph = leading == .leafTab ? NSImageView() : nil
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        registerForDraggedTypes([.lighttyPaneID])
        HoverCursor.installPointingHand(on: self)

        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 3

        closeButton.image = SymbolImages.image(
            "xmark", pointSize: 7.5, weight: .bold, description: L("Close pane"))
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.focusRingType = .none
        closeButton.contentTintColor = ShellStyle.secondaryText
        closeButton.isHidden = true
        closeButton.target = self
        closeButton.action = #selector(closeTapped)

        menuButton.image = SymbolImages.image(
            "ellipsis", pointSize: 10, weight: .medium, description: L("More actions"))
        menuButton.isBordered = false
        menuButton.imagePosition = .imageOnly
        menuButton.focusRingType = .none
        menuButton.contentTintColor = ShellStyle.secondaryText
        menuButton.isHidden = true
        menuButton.target = self
        menuButton.action = #selector(menuTapped)

        nameLabel.stringValue = name
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.textColor = ShellStyle.primaryText
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        taskLabel.font = .systemFont(ofSize: 10, weight: .medium)
        taskLabel.textColor = ShellStyle.secondaryText
        taskLabel.lineBreakMode = .byTruncatingTail
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
        statusLabel.textColor = ShellStyle.secondaryText
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        agentIcon.contentTintColor = ShellStyle.primaryText
        agentIconWidth = agentIcon.widthAnchor.constraint(equalToConstant: 0)
        agentIconGap = nameLabel.leadingAnchor.constraint(equalTo: agentIcon.trailingAnchor)
        menuButtonWidth = menuButton.widthAnchor.constraint(equalToConstant: 0)
        for v in [dotView, closeButton, menuButton, agentIcon, nameLabel, statusLabel, secondaryStack] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        if let tabGlyph {
            tabGlyph.image = SymbolImages.image(
                "rectangle.on.rectangle", pointSize: 10, weight: .medium, description: L("Tab"))
            tabGlyph.translatesAutoresizingMaskIntoConstraints = false
            addSubview(tabGlyph)
            // 与容器行的图标同列同尺寸（leading 5、宽 18），跟第一行对齐。
            // 要等 nameLabel 已进视图树再激活，否则约束引用不在层级里的视图会直接炸。
            NSLayoutConstraint.activate([
                tabGlyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
                tabGlyph.widthAnchor.constraint(equalToConstant: 18),
                tabGlyph.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 42),

            // 嵌进标签页标题的文字轴之下再退一步，属地关系靠缩进本身表达；
            // 圆点跟第一行对齐，不悬在两行中间。叶子行同样从子级位起，前面的
            // 标签页图标负责说明"这是一个标签页"。
            dotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            dotView.widthAnchor.constraint(equalToConstant: 6),
            dotView.heightAnchor.constraint(equalToConstant: 6),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
            // ⋯ 槽位只在装了菜单（叶子行）时占宽，普通 pane 行不为它让出标题空间。
            menuButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor),
            menuButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            menuButtonWidth,
            menuButton.heightAnchor.constraint(equalToConstant: 18),

            agentIcon.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 7),
            agentIcon.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            agentIcon.heightAnchor.constraint(equalToConstant: 12),
            agentIconWidth,
            agentIconGap,
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            dotView.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),

            // 状态固定在行尾且保持完整；pane 名吃掉中间弹性空间，过长时先截断。
            // close 槽位始终预留，hover 出现 ✕ 时状态不会横跳。
            statusLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 6),
            statusLabel.trailingAnchor.constraint(
                equalTo: menuButton.leadingAnchor, constant: -4),
            statusLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),

            // 第二行顶到 pane 内容左轴；不再为第一行的状态圆点留空，
            // 路径也能多拿到 13pt 的有效宽度。
            secondaryStack.leadingAnchor.constraint(equalTo: dotView.leadingAnchor),
            secondaryStack.trailingAnchor.constraint(
                lessThanOrEqualTo: menuButton.leadingAnchor, constant: -4),
            secondaryStack.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            secondaryStack.bottomAnchor.constraint(
                lessThanOrEqualTo: bottomAnchor, constant: -4),
        ])
        applyDotColor()
        applyStatusLabel()
        applyMetadataLine()
        applyFill()
        applyTabGlyphTint()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func closeTapped() { onClose?() }
    @objc private func menuTapped() { onMenu?() }

    /// 与容器行一致：活跃标签页的图标染导航色。
    private func applyTabGlyphTint() {
        tabGlyph?.contentTintColor = isActive ? ShellStyle.navigationAccent : ShellStyle.secondaryText
    }

    private func applyMenuSlot() {
        menuButtonWidth.constant = onMenu == nil ? 0 : 20
        menuButton.isHidden = !hovered || onMenu == nil
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        applyFill()
        applyTabGlyphTint()
    }

    func configure(
        paneID: UUID, name: String, taskName: String?, isActive: Bool, workingDirectory: String?,
        sessionAgent: SessionAgent? = nil
    ) {
        sidebarHoverExited()
        hovered = false
        alphaValue = 1
        setDropHighlighted(false)
        self.paneID = paneID
        self.taskName = taskName
        bound = taskName != nil
        self.isActive = isActive
        terminalWorkingDirectory = workingDirectory
        status = nil
        isUnread = false
        nameLabel.stringValue = name
        displayedAgent = sessionAgent
        agentIcon.image = sessionAgent.flatMap { AgentSessionIcon.image(for: $0) }
        agentIconWidth.constant = sessionAgent == nil ? 0 : 12
        agentIconGap.constant = sessionAgent == nil ? 0 : 5
        applyDotColor()
        applyStatusLabel()
        applyMetadataLine()
        applyFill()
        applyTabGlyphTint()
    }

    func applyWorkingDirectory(_ directory: String?) {
        guard terminalWorkingDirectory != directory else { return }
        terminalWorkingDirectory = directory
        applyMetadataLine()
    }

    /// Update visible fields in place; metadata changes must not reset hover or activity.
    func applySession(_ state: PaneSessionState) {
        if nameLabel.stringValue != state.title {
            nameLabel.stringValue = state.title
            applyToolTips()
        }
        let agent = state.sessionKey?.agent
        if displayedAgent != agent {
            displayedAgent = agent
            agentIcon.image = agent.flatMap { AgentSessionIcon.image(for: $0) }
            agentIconWidth.constant = agent == nil ? 0 : 12
            agentIconGap.constant = agent == nil ? 0 : 5
        }
        applyWorkingDirectory(state.workingDirectory)
        applyStatus(state.status, isUnread: state.isUnread)
    }

    /// 原地更新：这个插槽没有竞争（✕ 在行尾，不抢圆点位），改个颜色就完事。
    /// 这一行**真正显示出来**的三样东西。
    ///
    /// 比较它，而不是比较原始状态里的字段：以后往这一行加显示项，就必须加进这个值，
    /// 守卫自动跟着走；否则会出现「加了新字段但守卫没加，界面悄悄不刷新」。
    ///
    /// 也别照抄终端头那边的字段表——那边显示 `detail`（进 tooltip），这一行不显示；
    /// 这一行显示 `cwd`（无 OSC PWD 时第二行的兜底），那边不显示。
    /// **各自比自己显示的东西**，取并集只会让两边都多刷。
    ///
    /// `tool` 不在里面：这个视图从头到尾没用过它（用它的 `detailLine(for:)` 是终端头
    /// 和菜单栏在调）。而 `PreToolUse`/`PostToolUse` 每次工具调用都会送一发状态过来，
    /// 把它放进守卫等于每次都白穿过一遍。
    private struct Rendered: Equatable {
        var activity: PaneActivity?
        var text: String?
        var cwd: String?
        var isUnread: Bool
        /// 纯函数，**不另存一份缓存**：缓存要在视图复用时记得清掉，那是一个新的失败
        /// 模式；前后各算一次就没有可失效的东西。
        init(of status: PaneStatus?, isUnread: Bool) {
            activity = status?.state
            text = TabPaneStatusPresentation.text(for: status)
            cwd = status?.cwd
            self.isUnread = isUnread
        }
    }

    func applyStatus(_ status: PaneStatus?, isUnread: Bool) {
        let previous = Rendered(of: self.status, isUnread: self.isUnread)
        let next = Rendered(of: status, isUnread: isUnread)
        // 原始状态照存：下面几个 apply 都从 `self.status` 读。
        self.status = status
        self.isUnread = isUnread
        guard previous != next else { return }
        // 圆点跟真实 activity 走；文字比的是展示值，thinking ↔ tool 不重复写 label。
        if previous.activity != next.activity {
            applyDotColor()
            applyFill()
        }
        if previous.text != next.text || previous.isUnread != next.isUnread { applyStatusLabel() }
        if previous.cwd != next.cwd { applyMetadataLine() }
    }

    /// 活动状态与 pane 名同在第一行；空闲时隐藏，不用任务名补位。
    ///
    /// **颜色不能单独承担语义**——用户没有图例就是在猜"蓝色是什么意思"。
    /// 圆点负责快速扫色，次级文字负责解释语义；不再铺 badge 底色与当前行
    /// 高亮争抢视觉重心。任务名是稳定信息，固定保留在第二行。
    private func applyStatusLabel() {
        statusLabel.apply(status, isUnread: isUnread)
        applyToolTips()
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
        applyToolTips()
    }

    /// tooltip 只在 hover 时挂：NSToolTipManager 每帧都会重算所有已注册 tooltip
    /// 的矩形，几十行 × 四五个 tooltip 常驻是滚动期主线程的一笔固定开销。
    /// tooltip 本来也只在指针停在行上时才会出现，行为不变。
    private func applyToolTips() {
        let on = hovered
        // 叶子行关的是整个标签页（最后一个 pane 关掉 = 标签页关掉），提示照实说。
        closeButton.toolTip = on ? (onRename != nil ? L("Close tab") : L("Close pane")) : nil
        nameLabel.toolTip = on ? nameLabel.stringValue : nil
        taskLabel.toolTip = on ? taskName : nil
        statusLabel.toolTip = on && !statusLabel.isHidden ? statusLabel.stringValue : nil
        directoryLabel.toolTip = on ? (terminalWorkingDirectory ?? status?.cwd) : nil
    }

    private func applyDotColor() {
        dotView.layer?.backgroundColor = ShellStyle
            .dotColor(bound: bound, activity: activity)
            .shellResolvedCGColor(for: effectiveAppearance)
    }

    private func applyFill() {
        // Fill means selection/hover only. Completion is conveyed by the dot and text.
        if isActive {
            layer?.backgroundColor = ShellStyle.navigationTint(0.14)
                .shellResolvedCGColor(for: effectiveAppearance)
        } else if hovered {
            layer?.backgroundColor = ShellStyle.controlFill
                .shellResolvedCGColor(for: effectiveAppearance)
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
        // .inVisibleRect 由 AppKit 自行跟随可见区，建一次即可。滚动时 AppKit 每帧
        // 都会调到这里，反复 remove/add 是侧栏滚动期主线程的固定开销之一。
        guard tracking == nil else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    func setSidebarHovered(_ value: Bool) { hovered = value }
    override func mouseEntered(with event: NSEvent) { sidebarHoverEntered() }
    override func mouseExited(with event: NSEvent) { sidebarHoverExited() }

    // MARK: - 拖拽（源 + 落点）

    /// 与 PaneHeaderView 同款 click/drag 分流：3pt 内是点击，超出启动 pane 拖拽。
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let onRename { onRename(); return }
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
            on ? ShellStyle.navigationTint(0.7).shellResolvedCGColor(for: effectiveAppearance) : nil
    }
}
