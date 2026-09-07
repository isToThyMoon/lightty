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

    private var reloadScheduled = false

    @objc private func tasksDidChange() {
        // 合并到下一个 runloop tick：bind() 在 pane 挂进视图树之前发通知，
        // 同步 reload 会读到「已绑定但还不在树上」的中间态，误判为休眠。
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.reloadScheduled = false
            self?.reload()
        }
    }

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

        emptyLabel.isHidden = !filtered.isEmpty
        tableView.reloadData()
        if !filtered.isEmpty {
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

    /// 新建 handoff 任务文档（只建档，不开终端；开终端由任务气泡的目的地承担）。
    func newTask(from anchor: NSView) {
        NameEditorPopover.present(
            from: anchor, title: L("New task"), confirmLabel: L("Create")
        ) { name in
            do {
                _ = try AppState.shared.taskStore.create(
                    name: name,
                    workdir: FileManager.default.homeDirectoryForCurrentUser.path,
                    tool: nil)
                NotificationCenter.default.post(name: .lighttyTasksDidChange, object: nil)
            } catch {
                NSSound.beep()
                NSLog("task create failed: \(error)")
            }
        }
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
        tableView.reloadData()
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ShellTableRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = filtered[row]

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = dotColor(for: entry).cgColor

        let title = NSTextField(labelWithString: entry.task.name)
        title.font = .systemFont(ofSize: 12.5, weight: .medium)
        title.textColor = ShellStyle.primaryText
        title.lineBreakMode = .byTruncatingTail

        // 活跃/休眠是 UI 派生态（有无 pane 绑定）。文件里的 status 不展示：
        // 分诊细节走单击气泡的 handoff 摘要，列表只保留存在性 + 时间。
        let activity = entry.running != nil ? L("Active") : L("Dormant")
        let subtitle = NSTextField(
            labelWithString: "\(activity)  ·  \(relativeTime(entry.task.updated))")
        subtitle.font = .systemFont(ofSize: 10.5)
        subtitle.textColor = ShellStyle.secondaryText
        subtitle.lineBreakMode = .byTruncatingTail

        // 更多操作（⋯）：与行本体的"跳转/打开"语义分开——管理动作都在这个菜单里。
        let detailButton = ShellIconButton(
            symbol: "ellipsis", accessibilityLabel: L("More actions"), target: self,
            action: #selector(showRowMenu(_:)))
        detailButton.tag = row

        let cell = NSView()
        for v in [dot, title, subtitle, detailButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        NSLayoutConstraint.activate([
            // Align the leading status marker with the other primary-sidebar rows.
            dot.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            dot.topAnchor.constraint(equalTo: cell.topAnchor, constant: 12),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),

            title.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 9),
            title.trailingAnchor.constraint(lessThanOrEqualTo: detailButton.leadingAnchor, constant: -6),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),

            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: detailButton.leadingAnchor, constant: -6),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),

            detailButton.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            detailButton.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            detailButton.widthAnchor.constraint(equalToConstant: 26),
            detailButton.heightAnchor.constraint(equalToConstant: 26),
        ])
        return cell
    }

    /// 任务行的圆点只表达「有没有 pane 绑着它」，不掺 agent 活动状态：
    /// 这张表是全量 reload 重建的（`lighttyTasksDidChange`），跟不上状态的频率，
    /// 显示一个可能已经过期的状态比不显示更糟。实时状态在 pane 头和标签页侧栏。
    private func dotColor(for entry: Entry) -> NSColor {
        ShellStyle.dotColor(bound: entry.running != nil, activity: nil)
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
        guard sender.tag >= 0, sender.tag < filtered.count else { return }
        let entry = filtered[sender.tag]

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
                    let alert = NSAlert()
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
        RestoreFlow.begin(
            fileURL: entry.fileURL, task: entry.task,
            from: anchor, in: controller)
    }
}
