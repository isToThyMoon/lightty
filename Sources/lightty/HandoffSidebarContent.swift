import AppKit
import LighttyCore

/// 任务列表的手动序（拖拽排序的持久层）。存 preferences.json 的文件名列表，
/// 不写进任务文件：frontmatter 保持纯任务语义，一次拖动也不该重写一串 md。
/// 空列表 = 用户从未手动排过 → 列表维持派生序（活跃置顶 + 最近更新）；
/// 拖过一次即整列入序、手动序接管。改名后文件名变化的任务视同新任务浮顶。
enum TaskManualOrder {
    private static let key = "lightty.taskOrder"
    static func load() -> [String] {
        FilePreferences.shared.stringArray(forKey: key) ?? []
    }
    static func save(_ fileNames: [String]) {
        FilePreferences.shared.set(fileNames, forKey: key)
    }
}

/// Handoff list content. PrimarySidebar owns chrome and mode switching.
final class HandoffSidebarContent: NSView, NSTableViewDataSource, NSTableViewDelegate {

    private struct Entry {
        let fileURL: URL
        let task: TaskFile
        /// 有 pane 绑着 = 活跃（派生态，仅存在于 UI 层，不落盘）
        let running: (controller: TerminalWindowController, pane: PaneView)?
    }

    private struct HandoffState: Equatable {
        var rows: [HandoffRowSnapshot]
        var showsEmpty: Bool
    }
    private var renderedRows: [HandoffRowSnapshot] = []
    private var renderedShowsEmpty: Bool?

    /// 活跃/休眠是 UI 派生态（有无 pane 绑定）。文件里的 status 不展示：
    /// 分诊细节走单击气泡的 handoff 摘要，列表只保留存在性 + 时间。
    private func snapshot(of entry: Entry) -> HandoffRowSnapshot {
        HandoffRowSnapshot(
            id: entry.fileURL.lastPathComponent,
            name: entry.task.name,
            subtitle: "\(entry.running != nil ? L("Active") : L("Dormant"))  ·  \(relativeTime(entry.task.updated))",
            running: entry.running != nil)
    }

    // MARK: - 列表页

    private let listPage = NSView()
    private let tableView = ReorderingTableView()
    private let emptyLabel = NSTextField(labelWithString: L("No tasks yet"))
    private var allEntries: [Entry] = []
    private var filtered: [Entry] = []


    init() {
        super.init(frame: .zero)

        clipsToBounds = false
        wantsLayer = true
        // 不 pin Aqua：壳层 palette 是明暗动态色，随系统外观切换。

        buildListPage()
        listPage.translatesAutoresizingMaskIntoConstraints = false
        addSubview(listPage)
        NSLayoutConstraint.activate([
            listPage.topAnchor.constraint(equalTo: topAnchor),
            listPage.bottomAnchor.constraint(equalTo: bottomAnchor),
            listPage.leadingAnchor.constraint(equalTo: leadingAnchor),
            listPage.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        reload()

        // pane 命名/绑定落盘后实时刷新列表。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(tasksDidChange),
            name: .lighttyTasksDidChange,
            object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// 合并到下一个 runloop tick：bind() 在 pane 挂进视图树之前发通知，
    /// 同步 reload 会读到「已绑定但还不在树上」的中间态，误判为休眠。
    private lazy var reloads = Coalescer(.nextTick) { [weak self] in self?.reload() }
    @objc private func tasksDidChange() { reloads.schedule() }

    // MARK: - 数据

    func reload() {
        let running = AppState.shared.runningPanes()
        allEntries = AppState.shared.taskStore.list().tasks
            .map { entry in
                let bound = running.first {
                    $0.pane.taskFileURL?.standardizedFileURL == entry.fileURL.standardizedFileURL
                }
                return Entry(fileURL: entry.fileURL, task: entry.task, running: bound)
            }
            .sorted(by: entryOrdering())
        applyFilter("")
    }

    /// 排序谓词。没有手动序时维持派生序：活跃置顶、其余按最近更新。
    /// 有手动序后它整个接管——状态变化不再重排（刚排好的列表不能因为
    /// 某个任务被激活又跳回顶上），未入序的新任务按最近更新浮在顶部。
    private func entryOrdering() -> (Entry, Entry) -> Bool {
        let rank = Dictionary(
            uniqueKeysWithValues: TaskManualOrder.load().enumerated()
                .map { ($1, $0) })
        if rank.isEmpty {
            return {
                if ($0.running != nil) != ($1.running != nil) { return $0.running != nil }
                return $0.task.updated > $1.task.updated
            }
        }
        return {
            switch (rank[$0.fileURL.lastPathComponent], rank[$1.fileURL.lastPathComponent]) {
            case let (a?, b?): return a < b
            case (nil, nil): return $0.task.updated > $1.task.updated
            case (nil, _): return true
            case (_, nil): return false
            }
        }
    }

    private func applyFilter(_ query: String) {
        if query.isEmpty {
            filtered = allEntries
        } else {
            filtered = allEntries
                .compactMap { entry -> (Entry, Int)? in
                    guard let score = FuzzyMatch.score(pattern: query, in: entry.task.name) else { return nil }
                    return (entry, score)
                }
                .sorted { $0.1 > $1.1 }
                .map { $0.0 }
        }

        render(HandoffState(rows: filtered.map(snapshot(of:)), showsEmpty: filtered.isEmpty))
    }

    /// 唯一写表格的地方。**不重置选中**——原来每次任务变更都把选中打回第 0 行，
    /// 用户正看着的那一条会被抢走。
    private func render(_ state: HandoffState) {
        if renderedShowsEmpty != state.showsEmpty {
            renderedShowsEmpty = state.showsEmpty
            emptyLabel.isHidden = !state.showsEmpty
        }
        let previous = renderedRows
        guard previous != state.rows else { return }
        let selectedID = previous.indices.contains(tableView.selectedRow)
            ? previous[tableView.selectedRow].id : nil
        renderedRows = state.rows

        // 稳定标识决定增删；内容变了的行单独重配，没变的行连同悬停与 tracking 一起留着。
        let difference = state.rows.map(\.id).difference(from: previous.map(\.id))
        var removed = IndexSet(), inserted = IndexSet()
        for change in difference {
            switch change {
            case .remove(let index, _, _): removed.insert(index)
            case .insert(let index, _, _): inserted.insert(index)
            }
        }
        if !difference.isEmpty {
            tableView.beginUpdates()
            tableView.removeRows(at: removed, withAnimation: [])
            tableView.insertRows(at: inserted, withAnimation: [])
            tableView.endUpdates()
        }
        let oldByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        for (index, row) in state.rows.enumerated()
        where !inserted.contains(index) && oldByID[row.id] != row {
            (tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? HandoffListCell)?
                .configure(row)
        }
        // 选中跟着那一行走。它整行没了就不干预——表格自己会落到相邻行，
        // 那比清空、更比「一律打回第一行」（原来的做法）合理。
        if let selectedID, let index = state.rows.firstIndex(where: { $0.id == selectedID }),
           tableView.selectedRow != index {
            tableView.selectRowIndexes([index], byExtendingSelection: false)
        } else if previous.isEmpty, tableView.selectedRow == -1, !state.rows.isEmpty {
            // 只有第一次填充才主动落在第一行。
            tableView.selectRowIndexes([0], byExtendingSelection: false)
        }
    }

    private var selectedEntry: Entry? {
        guard tableView.selectedRow >= 0, tableView.selectedRow < filtered.count else { return nil }
        return filtered[tableView.selectedRow]
    }

    // MARK: - 列表页

    private func buildListPage() {
        let column = NSTableColumn(identifier: .init("task"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        // 关掉系统的 inset 表格样式：它给 cell 两侧各塞 16pt 内衬，而行高亮
        // （ShellTableRowView 自绘）是全宽的，行尾的 ⋯ 就离行右缘一截。
        // 行内衬由 cell 约束自己定。
        tableView.style = .plain
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.rowHeight = 48
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        // 单击/双击与拖拽重排都走 ReorderingTableView 的自建循环（跟手、无脱手图）。
        tableView.onRowClick = { [weak self] row in
            guard let self, self.filtered.indices.contains(row) else { return }
            self.tableView.selectRowIndexes([row], byExtendingSelection: false)
            self.presentTaskPopover(for: self.filtered[row], at: row)
        }
        tableView.onRowDoubleClick = { [weak self] row in
            guard let self, self.filtered.indices.contains(row) else { return }
            self.tableView.selectRowIndexes([row], byExtendingSelection: false)
            self.jumpOrRestoreSelected()
        }
        // 过滤/搜索态展示序 ≠ 真实序，禁止重排
        tableView.canReorder = { [weak self] in
            guard let self else { return false }
            return self.filtered.count == self.allEntries.count
        }
        tableView.previewMove = { [weak self] from, to in
            self?.previewReorderMove(from: from, to: to)
        }
        tableView.commitReorder = { [weak self] _ in self?.commitReorder() }

        let scroll = SidebarListScrollView()
        scroll.documentView = tableView

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = ShellStyle.tertiaryText
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        for v in [scroll, emptyLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            listPage.addSubview(v)
        }

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: listPage.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: listPage.leadingAnchor, constant: SidebarListScrollView.leadingMargin),
            scroll.trailingAnchor.constraint(equalTo: listPage.trailingAnchor, constant: -SidebarListScrollView.trailingMargin),
            scroll.bottomAnchor.constraint(equalTo: listPage.bottomAnchor, constant: -8),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor, constant: -24),
        ])
    }

    func openSearchPalette() {
        (window?.windowController as? TerminalWindowController)?.toggleSearchPalette()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    // MARK: - 拖拽排序（手动跟手循环，机件见 ReorderDrag / ReorderingTableView）

    /// 逐帧让位：把第 from 行落到第 to 行，模型与视图同步（视图移动由表自身做）。
    private func previewReorderMove(from: Int, to: Int) {
        guard filtered.indices.contains(from) else { return }
        let entry = filtered.remove(at: from)
        filtered.insert(entry, at: min(max(to, 0), filtered.count))
        allEntries = filtered  // 拖拽仅在未过滤态开放，两者此刻同序
    }

    /// 释放落定：模型已随 preview 同步，这里只固化手动序并重建行（复原隐藏 + 干净态）。
    private func commitReorder() {
        // 一次拖动即把当前整列固化为手动序（此后派生重排全部退位）
        TaskManualOrder.save(filtered.map { $0.fileURL.lastPathComponent })
        // 拖动直接改了 `filtered`，没走 `render`；重载之后必须把差异基线对齐，
        // 否则下一次 `render` 会拿旧顺序去算增删。
        renderedRows = filtered.map(snapshot(of:))
        tableView.reloadData()
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = ShellTableRowView()
        // 这里的选中是键盘光标，不是状态：`tableViewSelectionDidChange` 是空的，
        // 它只记录上下键/点击停在哪儿，回车拿它开气泡。失焦还留着就会被当成
        // 「这个任务怎么了」——而真正的状态信号是行上那个绿点。
        view.showsSelectionOnlyWhenFocused = true
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("handoff-list-cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? HandoffListCell
            ?? HandoffListCell(target: self, action: #selector(showRowMenu(_:)))
        cell.identifier = identifier
        cell.configure(snapshot(of: filtered[row]))
        return cell
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = max(0, -date.timeIntervalSinceNow)
        if seconds < 60 { return L("just now") }
        if seconds < 3_600 { return L("%d min ago", Int(seconds / 60)) }
        if seconds < 86_400 { return L("%d hr ago", Int(seconds / 3_600)) }
        if seconds < 604_800 { return L("%d days ago", Int(seconds / 86_400)) }
        let formatter = DateFormatter()
        formatter.dateFormat = L("MMM d")
        return formatter.string(from: date)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {}

    // MARK: - 行「⋯」菜单（自绘气泡；纯管理动作，跳转走单击气泡/双击）

    @objc private func showRowMenu(_ sender: NSButton) {
        // 按行标识找，不按索引：单元格会被复用，索引会过期。
        guard let cell = sender.superview as? HandoffListCell, let id = cell.rowID,
              let entry = filtered.first(where: { $0.fileURL.lastPathComponent == id })
        else { return }

        var items: [ShellMenuPopover.Item] = [
            .action(L("Rename task…")) { [weak self, weak sender] in
                guard let anchor = sender ?? self else { return }
                NameEditorPopover.present(
                    from: anchor, title: L("Rename task"),
                    initial: entry.task.name, confirmLabel: L("Rename")
                ) { name in
                    do {
                        try AppState.shared.renameTask(at: entry.fileURL, to: name)
                    } catch {
                        NSSound.beep()
                        NSLog("task rename failed: \(error)")
                    }
                }
            },
            .separator,
        ]
        // 状态不提供手动修改也不展示：活跃/休眠由 pane 绑定派生；
        // 文件 status 字段已弃用（见 docs/task-format.md）。
        items.append(.action(L("Open handoff document")) {
            NSWorkspace.shared.open(entry.fileURL)
        })
        items.append(.action(L("Open with…")) { [weak self, weak sender] in
            guard let anchor = sender ?? self else { return }
            // 列系统里注册可打开 md 的应用；勾选 = 当前系统默认（想全局换默认
            // 走 Finder 显示简介 →「全部更改」，此处只做单次选择不持久化）。
            let tab = NSWorkspace.shared
            let defaultApp = tab.urlForApplication(toOpen: entry.fileURL)
            var seenNames = Set<String>()
            var appItems: [ShellMenuPopover.Item] = []
            for appURL in tab.urlsForApplications(toOpen: entry.fileURL) {
                let name = FileManager.default.displayName(atPath: appURL.path)
                guard seenNames.insert(name).inserted else { continue }
                appItems.append(.action(name, checked: appURL == defaultApp) {
                    tab.open(
                        [entry.fileURL], withApplicationAt: appURL,
                        configuration: NSWorkspace.OpenConfiguration(),
                        completionHandler: nil)
                })
            }
            guard !appItems.isEmpty else { NSSound.beep(); return }
            appItems.sort {
                switch ($0.checked, $1.checked) {
                case (true, false): return true
                case (false, true): return false
                default: return $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
            }
            ShellMenuPopover.present(from: anchor, items: appItems)
        })
        items.append(.action(L("Reveal in Finder")) {
            NSWorkspace.shared.activateFileViewerSelecting([entry.fileURL])
        })
        items.append(.separator)
        items.append(.action(L("Archive task")) {
            do {
                // 移入 archive/ 子目录（文件保留，列表消失）；绑定中的 pane 解绑。
                try AppState.shared.taskStore.archive(at: entry.fileURL)
                for (_, pane) in AppState.shared.runningPanes()
                where pane.taskFileURL?.standardizedFileURL
                    == entry.fileURL.standardizedFileURL {
                    pane.unbind()
                }
                NotificationCenter.default.post(
                    name: .lighttyTasksDidChange, object: nil)
                if !FilePreferences.shared.bool(forKey: "handoffArchiveNoticeShown") {
                    FilePreferences.shared.set(true, forKey: "handoffArchiveNoticeShown")
                    let alert = AppBranding.makeAlert()
                    alert.messageText = L("Task archived")
                    alert.informativeText = L("You can restore it or permanently delete it in Settings > Archive.")
                    alert.addButton(withTitle: L("OK"))
                    alert.runModal()
                }
            } catch {
                NSSound.beep()
                NSLog("task archive failed: \(error)")
            }
        })
        items.append(.action(L("Delete task (move to Trash)"), destructive: true) {
            do {
                // 移到废纸篓（可恢复）；绑定中的 pane 解除绑定。
                try FileManager.default.trashItem(
                    at: entry.fileURL, resultingItemURL: nil)
                for (_, pane) in AppState.shared.runningPanes()
                where pane.taskFileURL?.standardizedFileURL
                    == entry.fileURL.standardizedFileURL {
                    pane.unbind()
                }
                NotificationCenter.default.post(
                    name: .lighttyTasksDidChange, object: nil)
            } catch {
                NSSound.beep()
                NSLog("task delete failed: \(error)")
            }
        })

        ShellMenuPopover.present(from: sender, items: items)
    }

    /// 单击：统一弹任务气泡（已打开的列跳转行 + 打开到三目的地），侧栏保持展开。

    /// 双击 / Enter 快捷路径：运行中直接跳最近绑定 pane；休眠同单击弹气泡。
    /// 双击/Enter：运行中直接跳最近绑定 pane；休眠弹恢复气泡。
    private func jumpOrRestoreSelected() {
        guard let entry = selectedEntry else { return }
        if let running = entry.running {
            running.controller.window?.makeKeyAndOrderFront(nil)
            running.controller.reveal(pane: running.pane)
            running.pane.flashReveal()
        } else {
            presentTaskPopover(for: entry, at: tableView.selectedRow)
        }
    }

    private func presentTaskPopover(for entry: Entry, at row: Int) {
        guard let controller = window?.windowController as? TerminalWindowController
        else { return }
        let anchor = tableView.rowView(atRow: row, makeIfNecessary: false) ?? self
        LaunchComposer.begin(.task(fileURL: entry.fileURL, task: entry.task),
                             from: anchor, in: controller)
    }
}

/// 一行**真正显示出来**的东西，可比较。
///
/// 这个列表原来每次任务变更都 `reloadData()` 全量重建，还顺手把选中重置到第 0 行；
/// 单元格也是每行每次新建一整棵视图树加十三条约束。现在跟会话侧栏同一个形状：
/// 稳定标识决定增删，行值决定要不要重配，选中不动。
///
/// `id` 用文件名而不是完整路径：改名走的是移动语义，路径会变，而它仍是同一行。
/// 副标题存的是**渲染好的字符串**而不是原始时间——比较的就是显示出来的东西。
private struct HandoffRowSnapshot: Equatable {
    let id: String
    let name: String
    let subtitle: String
    let running: Bool
}

/// Handoff 列表的单元格。**建一次、复用、只改变了的字段**——原来是每行每次新建
/// 一整棵视图树加十三条约束，任务一变就全表重来。
private final class HandoffListCell: NSView {
    private let dot = NSView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let detailButton: ShellIconButton
    /// 行标识：单元格会被复用，菜单不能按索引找行。
    private(set) var rowID: String?
    private var rendered: HandoffRowSnapshot?

    init(target: AnyObject, action: Selector) {
        detailButton = ShellIconButton(symbol: "ellipsis", accessibilityLabel: L("More actions"),
                                       target: target, action: action)
        super.init(frame: .zero)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        title.font = .systemFont(ofSize: 12.5, weight: .medium)
        title.textColor = ShellStyle.primaryText
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 10.5)
        subtitle.textColor = ShellStyle.secondaryText
        subtitle.lineBreakMode = .byTruncatingTail
        for view in [dot, title, subtitle, detailButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            // Align the leading status marker with the other primary-sidebar rows.
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            dot.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),

            title.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 9),
            title.trailingAnchor.constraint(lessThanOrEqualTo: detailButton.leadingAnchor, constant: -6),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: detailButton.leadingAnchor, constant: -6),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),

            detailButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            detailButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailButton.widthAnchor.constraint(equalToConstant: 26),
            detailButton.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ snapshot: HandoffRowSnapshot) {
        rowID = snapshot.id
        guard rendered != snapshot else { return }
        let previous = rendered
        rendered = snapshot
        if previous?.name != snapshot.name { title.stringValue = snapshot.name }
        if previous?.subtitle != snapshot.subtitle { subtitle.stringValue = snapshot.subtitle }
        if previous?.running != snapshot.running {
            dot.layer?.backgroundColor = ShellStyle.dotColor(bound: snapshot.running, activity: nil).cgColor
        }
    }
}
