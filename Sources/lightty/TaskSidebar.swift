import AppKit
import LighttyCore

/// 任务浮层卡片（Ulysses 式悬浮面板）：标题栏侧栏按钮控制开合。
/// 与工作区侧栏是两套独立面板——task↔pane 是绑定关系而非层级，
/// UI 上以"悬浮卡片"质感（抬升面 + 圆角 + 投影）与 docked 侧栏区隔。
final class TaskSidebar: NSView, NSTableViewDataSource, NSTableViewDelegate {

    private struct Entry {
        let fileURL: URL
        let task: TaskFile
        /// 有 pane 绑着 = 活跃（派生态，仅存在于 UI 层，不落盘）
        let running: (controller: TerminalWindowController, pane: PaneView)?
    }

    // MARK: - 列表页

    private let listPage = NSView()
    // 首行 = 节标签行：功能性小节标签（Finder「个人收藏」/ VS Code「EXPLORER」
    // 的角色，非品牌）+ 右侧 搜索/建档 图标按钮。品牌归 Dock 图标和 About。
    // 搜索走全文浮层（⇧⇧ 或点按钮），侧栏不再有常驻输入框。
    private let titleLabel = NSTextField(labelWithString: L("Tasks"))
    private let searchButton = ShellIconButton(
        symbol: "magnifyingglass", accessibilityLabel: L("Search tasks"),
        target: nil, action: nil)
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: L("No tasks yet"))
    private let newTaskButton = ShellIconButton(
        symbol: "doc.badge.plus", accessibilityLabel: L("New task"), target: nil, action: nil)
    private var allEntries: [Entry] = []
    private var filtered: [Entry] = []


    var onRequestClose: (() -> Void)?

    /// 卡片右缘贴边吸附的关闭钮（与窗口左缘展开钮同形镜像）。不作为子视图：
    /// 由 controller 挂到 themeFrame——命中区向右溢出卡片 bounds，做子视图会被裁断，
    /// 且卡片 layer 有圆角遮罩。
    let closeControl = EdgeToggleControl(pointing: .left)

    init() {
        super.init(frame: .zero)
        closeControl.onTap = { [weak self] in self?.onRequestClose?() }

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
        applyAppearanceColors()

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

    /// layer.backgroundColor 是 CGColor 快照，外观切换时必须按当前明暗重解析。
    private func applyAppearanceColors() {
        let appearance = effectiveAppearance
        layer?.backgroundColor =
            ShellStyle.raisedSurface.shellResolvedCGColor(for: appearance)
        layer?.borderColor =
            ShellStyle.divider.shellResolvedCGColor(for: appearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let layer else { return }
        // 悬浮卡片质感（layer 配置延迟到挂窗后：backing layer 重建会吃掉
        // init 期配置；投影用 NSView.shadow，AppKit 维护不丢）
        layer.cornerRadius = 12
        layer.borderWidth = 1
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 32
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        self.shadow = shadow
        applyAppearanceColors()
    }

    override func cancelOperation(_ sender: Any?) {
        onRequestClose?()
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
            .sorted {
                // 活跃置顶，其余按最近更新
                if ($0.running != nil) != ($1.running != nil) { return $0.running != nil }
                return $0.task.updated > $1.task.updated
            }
        applyFilter("")
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
        newTaskButton.target = self
        newTaskButton.action = #selector(newTask)

        titleLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        titleLabel.textColor = ShellStyle.tertiaryText

        searchButton.target = self
        searchButton.action = #selector(openSearchPalette)

        let column = NSTableColumn(identifier: .init("task"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 48
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.doubleAction = #selector(jumpOrRestore)

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = ShellStyle.tertiaryText
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        for v in [titleLabel, searchButton, newTaskButton, scroll, emptyLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            listPage.addSubview(v)
        }

        NSLayoutConstraint.activate([
            // 首行 = 品牌行（行高模数 chromeRowHeight = 28，顶距 8）：
            // Lightty 文字落内容左轴 20，右侧 搜索 + 建档 图标按钮；
            // 横向统一 10 的边缘线。
            titleLabel.leadingAnchor.constraint(equalTo: listPage.leadingAnchor, constant: 20),
            titleLabel.centerYAnchor.constraint(equalTo: newTaskButton.centerYAnchor),

            newTaskButton.topAnchor.constraint(equalTo: listPage.topAnchor, constant: 8),
            newTaskButton.trailingAnchor.constraint(equalTo: listPage.trailingAnchor, constant: -10),
            newTaskButton.widthAnchor.constraint(equalToConstant: 28),
            newTaskButton.heightAnchor.constraint(equalToConstant: 28),

            searchButton.trailingAnchor.constraint(equalTo: newTaskButton.leadingAnchor, constant: -4),
            // +1 光学微调：放大镜镜柄在右下，字形视觉重心偏上，几何同心时显高
            searchButton.centerYAnchor.constraint(
                equalTo: newTaskButton.centerYAnchor, constant: 1),
            searchButton.widthAnchor.constraint(equalToConstant: 28),
            searchButton.heightAnchor.constraint(equalToConstant: 28),

            scroll.topAnchor.constraint(equalTo: newTaskButton.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: listPage.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: listPage.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: listPage.bottomAnchor, constant: -8),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor, constant: -24),
        ])
    }

    /// 新建 handoff 任务文档（只建档，不开终端；开终端由任务气泡的目的地承担）。
    @objc private func newTask() {
        NameEditorPopover.present(
            from: newTaskButton, title: L("New task"), confirmLabel: L("Create")
        ) { name in
            do {
                _ = try AppState.shared.taskStore.create(
                    name: name,
                    cwd: FileManager.default.homeDirectoryForCurrentUser.path,
                    tool: nil)
                NotificationCenter.default.post(name: .lighttyTasksDidChange, object: nil)
            } catch {
                NSSound.beep()
                NSLog("task create failed: \(error)")
            }
        }
    }
    @objc private func openSearchPalette() {
        (window?.windowController as? TerminalWindowController)?.toggleSearchPalette()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

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
        subtitle.textColor = ShellStyle.tertiaryText
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
            // 行内衬 10：圆点落在内容左轴 20（滚动区缘 10 + 10）
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

            detailButton.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -7),
            detailButton.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            detailButton.widthAnchor.constraint(equalToConstant: 26),
            detailButton.heightAnchor.constraint(equalToConstant: 26),
        ])
        return cell
    }

    /// 任务行的圆点只表达「有没有 pane 绑着它」，不掺 agent 活动状态：
    /// 这张表是全量 reload 重建的（`lighttyTasksDidChange`），跟不上状态的频率，
    /// 显示一个可能已经过期的状态比不显示更糟。实时状态在 pane 头和工作区侧栏。
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
            let workspace = NSWorkspace.shared
            let defaultApp = workspace.urlForApplication(toOpen: entry.fileURL)
            var seenNames = Set<String>()
            var appItems: [ShellMenuPopover.Item] = []
            for appURL in workspace.urlsForApplications(toOpen: entry.fileURL) {
                let name = FileManager.default.displayName(atPath: appURL.path)
                guard seenNames.insert(name).inserted else { continue }
                appItems.append(.action(name, checked: appURL == defaultApp) {
                    workspace.open(
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
    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < filtered.count else { return }
        presentTaskPopover(for: filtered[row], at: row)
    }

    /// 双击 / Enter 快捷路径：运行中直接跳最近绑定 pane；休眠同单击弹气泡。
    @objc private func jumpOrRestore() {
        guard let entry = selectedEntry else { return }
        if let running = entry.running {
            running.controller.window?.makeKeyAndOrderFront(nil)
            running.controller.reveal(pane: running.pane)
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
