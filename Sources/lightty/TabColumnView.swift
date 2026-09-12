import AppKit
import LighttyCore

/// 侧栏一行的身份。每一项都记住所属标签页：拖拽落点要分辨"落在某个标签页的
/// pane 块里"还是"落在两个标签页之间"，没有归属就分辨不了。
/// 容器行同时带着标签页的身份：拖拽途中列表随时可能刷新，下标会变，身份不会。
/// `leaf` = 单 pane 标签页的合并行：它既是可拖走的 pane，本身又是一个标签页。
enum TabRowKind: Equatable {
    case tab(index: Int, id: UUID)
    case pane(tab: Int, pane: UUID)
    case leaf(tab: Int, pane: UUID)
}

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
    /// 控制器模型的如实投影，拖拽从不改写它。
    private var modelRows: [RowItem] = []
    /// 实际显示的行序：模型行加上拖拽会话推导出来（见 `RowDrag`）。
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
        decorate(container, row: row)
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
        var rowItems: [RowItem] = []
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
            // 拖容器行时它临时折叠：只影响这次显示，不写进用户的折叠状态。
            let isCollapsed = collapsedTabIDs.contains(entry.id) || drag?.collapsedForDrag == entry.id
            let presentation = TabPresentation(id: entry.id, index: entry.index, title: entry.title,
                isActive: entry.isActive, count: entry.panes.count)
            rowItems.append(RowItem(kind: .tab(index: entry.index, id: entry.id), makeView: { [weak self] existing in
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
        modelRows = rowItems
        self.rowItems = arrange(rowItems)
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
        row.onBeginDrag = { [weak self, weak row] event in
            guard let self, let row else { return }
            self.beginRowDrag(source: .tab(tabID), from: row, event: event)
        }
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
            self.beginRowDrag(source: .pane(pane.dragIdentifier), from: paneRow, event: event)
        }
        paneRow.applySession(state)
        paneRows.setObject(paneRow, forKey: pane.dragIdentifier as NSUUID)
        return paneRow
    }

    // MARK: - 行拖拽

    /// 拖的是什么：按身份记，不按下标。
    enum RowDragSource: Equatable {
        /// 缩进 pane 行或叶子行。
        case pane(UUID)
        /// 标签页容器行。
        case tab(UUID)
    }

    /// 松手后交给控制器执行的命令。
    enum RowDropCommand: Equatable {
        case moveTab(from: Int, to: Int)
        case detachPane(UUID, toNewTabAt: Int)
        case movePaneBeside(UUID, target: UUID, zone: PaneDropZone)
        case movePaneIntoTab(UUID, tabIndex: Int)
    }

    /// 拖拽落点只有两种语义，因为列表只有两级：
    /// - `insideTab`：落在某个标签页的 pane 块里 → 并进那棵分屏树。
    /// - `betweenTabs`：落在两个标签页之间 → 顶层重排。源行是整条标签页（叶子行）
    ///   就换标签页的位次；源行是某个标签页里的分屏 pane，就把它拆出来独立成新标签页。
    ///
    /// 判定只看紧邻：下方紧邻是缩进 pane 行，说明落点在那个标签页块内；否则看上方。
    /// 两边都不是缩进 pane 行，落点就在标签页之间。折叠的标签页在列表里只有一行，
    /// 对它而言"块内"不存在——要并进去得把行压到它的中央带上（合并）。
    enum DropSlot: Equatable {
        case insideTab(next: UUID?, previous: UUID?)
        case betweenTabs(Int)
    }

    /// 一次行拖拽的全部状态。
    ///
    /// 列表数据源从不被拖拽改写：`modelRows` 始终是控制器模型的如实投影，显示用的
    /// `rowItems` 由"模型行 + 这份状态"推导出来——源行挪到提议的位置、拖动的容器行
    /// 临时折叠。以前拖拽直接改数据源，途中来一次刷新（agent 状态、任务通知）就把源行
    /// 弹回原处、把拖拽记下的下标全部作废，松手什么都不发生；现在刷新只是重新推导一遍。
    ///
    /// 手势与改树也彻底分开：松手时只定下命令、冻结显示，命令放到下一拍交给控制器。
    private struct RowDrag {
        let source: RowDragSource
        /// 拖容器行时临时折叠的标签页：只影响显示，不碰用户自己的折叠状态。
        let collapsedForDrag: UUID?
        /// 源行在"其余各行"里的插入位；nil = 还没离开原位。
        var insertion: Int? = nil
        /// 压着中央带的那一行（按行身份记）。
        var merge: TabRowKind? = nil
        /// 松手之后、命令执行完之前：显示冻结在松手那一刻，不再响应指针。
        var committing = false
        let card: NSView
    }

    /// 行高的这个比例之内算中央带（上下各留 25% 给排序）。
    private static let mergeBand: CGFloat = 0.25

    private var drag: RowDrag?

    /// 当前显示出来的行序（测试与诊断用）。
    var displayedRows: [TabRowKind] { rowItems.map(\.kind) }

    static func matches(_ row: TabRowKind, _ source: RowDragSource) -> Bool {
        switch (row, source) {
        case (.pane(_, let id), .pane(let pane)), (.leaf(_, let id), .pane(let pane)): return id == pane
        case (.tab(_, let id), .tab(let tab)): return id == tab
        default: return false
        }
    }

    /// 显示行序：把源行挪到提议的插入位。纯函数，返回模型行下标的排列。
    static func arrangement(of rows: [TabRowKind], source: RowDragSource, insertion: Int?) -> [Int] {
        let order = Array(rows.indices)
        guard let insertion, let from = rows.firstIndex(where: { matches($0, source) }) else { return order }
        var others = order
        others.remove(at: from)
        others.insert(from, at: min(max(insertion, 0), others.count))
        return others
    }

    private func arrange(_ rows: [RowItem]) -> [RowItem] {
        guard let drag else { return rows }
        return Self.arrangement(of: rows.map(\.kind), source: drag.source, insertion: drag.insertion)
            .map { rows[$0] }
    }

    /// 松手时的命令。`rows` 是显示行序，`sourceIndex` 是源行在其中的位置。
    /// 合并优先：它是用户明确压在某一行上的意图。容器行只参与排序——把一整棵分屏树
    /// 并进另一个标签页是另一种操作。
    static func dropCommand(rows: [TabRowKind], sourceIndex si: Int, merge: TabRowKind?) -> RowDropCommand? {
        guard rows.indices.contains(si) else { return nil }
        switch rows[si] {
        case .tab(let index, _):
            return .moveTab(from: index, to: topLevelIndex(in: rows, before: si))
        case .pane(_, let pane), .leaf(_, let pane):
            switch merge {
            case .tab(let index, _)?:
                return .movePaneIntoTab(pane, tabIndex: index)
            case .pane(_, let target)?, .leaf(_, let target)?:
                return .movePaneBeside(pane, target: target, zone: .right)
            case nil:
                break
            }
            switch dropSlot(in: rows, sourceIndex: si) {
            case .insideTab(let next?, _)?:
                return .movePaneBeside(pane, target: next, zone: .left)
            case .insideTab(nil, let previous?)?:
                return .movePaneBeside(pane, target: previous, zone: .right)
            case .betweenTabs(let index)?:
                if case .leaf(let tab, _) = rows[si] { return .moveTab(from: tab, to: index) }
                return .detachPane(pane, toNewTabAt: index)
            case .insideTab(nil, nil)?, nil:
                return nil
            }
        }
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
        return .betweenTabs(topLevelIndex(in: rows, before: si))
    }

    /// 顶层位次 = 该行上方还有几个标签页（容器行 + 叶子行各算一个，源行自己不算）。
    static func topLevelIndex(in rows: [TabRowKind], before row: Int) -> Int {
        var index = 0
        for item in rows[..<min(row, rows.count)] {
            switch item {
            case .tab, .leaf: index += 1
            case .pane: continue
            }
        }
        return index
    }

    /// 接管一行的拖拽。跟手循环只是薄适配层：开始、移动、松手落在下面三个方法上，
    /// 与鼠标事件无关，测试可以直接驱动。
    private func beginRowDrag(source: RowDragSource, from row: NSView, event: NSEvent) {
        let startFrame = convert(row.bounds, from: row)  // self（非翻转）坐标
        guard let card = makeDragCard(of: row, frame: startFrame),
              startDrag(source: source, card: card) else { return }
        addSubview(card)
        let grabOffsetY = convert(event.locationInWindow, from: nil).y - startFrame.minY
        var landing: NSRect?
        ReorderDrag.run(
            host: self,
            snapshotView: card,
            startEvent: event,
            grabOffsetY: grabOffsetY,
            onMove: { [weak self] cursor in self?.moveDrag(to: cursor) },
            dropFrame: { landing },
            onCommit: { [weak self] in landing = self?.finishDrag() },
            onEnd: {})
    }

    /// 开始一次拖拽。源行不在列表里、或上一次拖拽还没收尾时返回 false。
    @discardableResult
    func startDrag(source: RowDragSource, card: NSView) -> Bool {
        guard drag == nil, modelRows.contains(where: { Self.matches($0.kind, source) }) else { return false }
        var collapse: UUID?
        if case .tab(let id) = source, !collapsedTabIDs.contains(id) { collapse = id }
        drag = RowDrag(source: source, collapsedForDrag: collapse, card: card)
        // 只有临时折叠要重新投影；拖 pane 行时显示还没变，不必整表刷新。
        if collapse != nil { reload() }
        return true
    }

    /// 指针移动（self 坐标）：压在中央带就进入合并态并停止让位，否则算插入位让列表让位。
    func moveDrag(to cursor: NSPoint) {
        guard var current = drag, !current.committing else { return }
        var target: TabRowKind?
        if case .pane = current.source { target = mergeTarget(at: cursor, source: current.source) }
        if target != current.merge {
            current.merge = target
            drag = current
            applyDragDecorations()
            applySnapshotLook(merging: target != nil)
        }
        guard target == nil,
              let from = rowItems.firstIndex(where: { Self.matches($0.kind, current.source) }) else { return }
        // 光标之上（self 非翻转：y 越大越靠上）的其余行数 = 插入位
        var insertion = 0
        for row in rowItems.indices where row != from {
            guard convert(table.rect(ofRow: row), from: table).midY > cursor.y else { break }
            insertion += 1
        }
        guard insertion != (current.insertion ?? from) else { return }
        current.insertion = insertion
        drag = current
        rowItems = arrange(modelRows)
        guard let to = rowItems.firstIndex(where: { Self.matches($0.kind, current.source) }), to != from else { return }
        table.beginUpdates()
        table.moveRow(at: from, to: to)
        table.endUpdates()
    }

    /// 松手：定下命令、冻结显示，返回卡片的落点；命令在下一拍交给控制器。
    ///
    /// 命令不在跟踪循环里执行，落地动画也不等它：卡片的去留与改树的成败互不牵连，
    /// 改树就算失败，卡片也照样落地消失。
    @discardableResult
    func finishDrag() -> NSRect? {
        guard var current = drag, !current.committing else { return nil }
        current.committing = true
        drag = current
        let rows = rowItems.map(\.kind)
        let sourceIndex = rows.firstIndex { Self.matches($0, current.source) }
        let original = modelRows.firstIndex { Self.matches($0.kind, current.source) }
        var command: RowDropCommand?
        if let sourceIndex, current.merge != nil || sourceIndex != original {
            command = Self.dropCommand(rows: rows, sourceIndex: sourceIndex, merge: current.merge)
        }
        let landingRow = current.merge.flatMap { rows.firstIndex(of: $0) } ?? sourceIndex
        let landing = landingRow.map { convert(table.rect(ofRow: $0), from: table) }
        DispatchQueue.main.async { [weak self] in self?.completeDrag(command) }
        return landing
    }

    private func completeDrag(_ command: RowDropCommand?) {
        if let command { perform(command) }
        drag = nil
        reload()  // 无论命令改没改动模型，都按最终模型重新投影一次
    }

    @discardableResult
    private func perform(_ command: RowDropCommand) -> Bool {
        guard let controller else { return false }
        switch command {
        case .moveTab(let from, let to):
            return controller.moveTab(from: from, to: to)
        case .detachPane(let pane, let index):
            return controller.detachPane(withID: pane, toNewTabAt: index)
        case .movePaneBeside(let pane, let target, let zone):
            guard let destination = controller.panes().first(where: { $0.dragIdentifier == target }) else { return false }
            return controller.movePane(withID: pane, to: destination, zone: zone)
        case .movePaneIntoTab(let pane, let index):
            return controller.movePane(withID: pane, toTabAt: index)
        }
    }

    private func mergeTarget(at cursor: NSPoint, source: RowDragSource) -> TabRowKind? {
        for row in rowItems.indices where !Self.matches(rowItems[row].kind, source) {
            let rect = convert(table.rect(ofRow: row), from: table)
            guard cursor.y >= rect.minY, cursor.y <= rect.maxY else { continue }
            return abs(cursor.y - rect.midY) <= rect.height * Self.mergeBand ? rowItems[row].kind : nil
        }
        return nil
    }

    /// 拖拽派生出来的行外观：源行留空位（容器透明）、合并目标描边。行每次绑定、
    /// 合并目标每次变化都按当前状态重算，刷新再多也不会留下残影。
    private func applyDragDecorations() {
        let visible = table.rows(in: table.visibleRect)
        for row in visible.location..<(visible.location + visible.length) {
            guard let container = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabRowContainer
            else { continue }
            decorate(container, row: row)
        }
    }

    private func decorate(_ container: TabRowContainer, row: Int) {
        guard rowItems.indices.contains(row) else { return }
        let kind = rowItems[row].kind
        container.alphaValue = drag.map { Self.matches(kind, $0.source) } == true ? 0 : 1
        (container.content as? any SidebarPaneDropRow)?.setDropHighlighted(drag?.merge == kind)
    }

    /// 合并态下浮层让出视线：目标行的落点框线正好压在浮层底下，浮层不淡一档就完全
    /// 看不见，用户只能靠猜自己要并进谁。只调透明度，不缩放：浮层是位图，缩放等于
    /// 把文字重采样，虚实一变就像卡了一帧。
    private func applySnapshotLook(merging: Bool) {
        guard let card = drag?.card else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            card.animator().alphaValue = merging ? 0.5 : 1
        }
    }

    /// 拖起来的卡片。两件事在这里统一：
    /// 1. 先摘掉 hover——hover 底色和 ⋯/✕ 是"指针停在这一行"的反馈，卡片上不该有。
    ///    不摘的话非活跃行会把不透明的 hover 底色烤进快照，活跃行却只有 14% 的强调
    ///    色淡底，同一个动作在两种行上一个看着实一个看着透。
    /// 2. 衬底用侧栏底色且**不透明**：卡片要和真行长得一模一样，落地换回真行才没有
    ///    可察觉的切换。半透明衬底会把文字的对比度压下去一档，落地一还原就是一次
    ///    "虚变实"，看着像掉帧。要让底下的行透出来是合并态的事，那时再单独调透明度。
    private func makeDragCard(of row: NSView, frame: NSRect) -> NSView? {
        (row as? SidebarHoverRow)?.setSidebarHovered(false)
        row.layoutSubtreeIfNeeded()
        row.displayIfNeeded()
        guard let image = ReorderDrag.snapshot(of: row) else { return nil }
        // 起手就对齐到像素：位图压在半个物理像素上会被重采样成毛边。
        let scale = window?.backingScaleFactor ?? 2
        var aligned = frame
        aligned.origin.x = (frame.origin.x * scale).rounded() / scale
        aligned.origin.y = (frame.origin.y * scale).rounded() / scale
        let card = ReorderDrag.makeSnapshot(image, frame: aligned)
        card.layer?.cornerRadius = 7
        card.layer?.backgroundColor =
            ShellStyle.sidebarBackground.shellResolvedCGColor(for: effectiveAppearance)
        // 位图层若按 1x 栅格化，2x 屏上等于把文字放大一倍，同样是发虚。
        card.layer?.contentsScale = scale
        card.subviews.first?.layer?.contentsScale = scale
        return card
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
    /// 起手拖拽本行（整条标签页换位次，由所属 TabColumnView 接管跟手循环）。
    var onBeginDrag: ((NSEvent) -> Void)?

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

    /// 与 pane 行同款 click/drag 分流：3pt 内是点击，超出启动标签页拖拽。
    /// 选中因此落在 mouseUp（与 pane 行一致），双击仍直接改名。
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onRename?(); return }
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
