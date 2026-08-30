import AppKit
import LighttyCore

/// 搜索图标只负责绘制，点击穿透给下方容器，保证整块搜索区域都能聚焦。
private final class TaskSearchIconView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class TaskSearchContainerView: NSView {
    weak var searchField: NSSearchField?

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(searchField)
    }
}

/// 标题栏入口控制的任务抽屉；不注册任何键盘快捷键。
///
/// 视觉与交互借鉴 Codex 桌面端：低对比表面、圆角选中态、大点击区域、明确的
/// 列表→详情层级。hover 是覆盖 terminal 的临时预览；click 钉住后切换为真正
/// 占位的 docked 侧栏。钉住后点击 terminal 不收起，避免抢占 Ghostty 鼠标交互。
final class TaskSidebar: NSView, NSTableViewDataSource, NSTableViewDelegate,
                         NSTextViewDelegate, NSSearchFieldDelegate {
    static let width = ShellStyle.sidebarWidth

    private struct Entry {
        let fileURL: URL
        let task: TaskFile
        /// 有 pane 绑着 = 活跃（派生态，仅存在于 UI 层，不落盘）
        let running: (controller: TerminalWindowController, pane: PaneView)?
    }

    // MARK: - 列表页

    private let listPage = NSView()
    private let titleLabel = NSTextField(labelWithString: "任务")
    private let countLabel = NSTextField(labelWithString: "")
    private let searchContainer = TaskSearchContainerView()
    private let searchIcon = TaskSearchIconView()
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "没有匹配的任务")
    private let newTaskButton = ShellIconButton(
        symbol: "doc.badge.plus", accessibilityLabel: "新建任务", target: nil, action: nil)
    private var allEntries: [Entry] = []
    private var filtered: [Entry] = []

    private var hoverTrackingArea: NSTrackingArea?

    /// 详情页已移除（handoff 编辑交给系统编辑器），侧栏不再有需要钉住的编辑态。
    var isDirty: Bool { false }

    var onRequestClose: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?

    /// 内容避开顶部标题栏区域的高度（抽屉背景本体延伸到窗口最顶端）
    private let topInset: CGFloat

    init(topInset: CGFloat) {
        self.topInset = topInset
        super.init(frame: .zero)

        clipsToBounds = false
        wantsLayer = true
        // 不 pin Aqua：壳层 palette 是明暗动态色，随系统外观切换。

        // 不画右缘边线：侧栏与标题栏同色拼成一体 chrome，terminal 自身底色
        // 已提供足够的视觉分界（Notion 式无边框）。
        buildListPage()
        listPage.translatesAutoresizingMaskIntoConstraints = false
        addSubview(listPage)
        NSLayoutConstraint.activate([
            listPage.topAnchor.constraint(equalTo: topAnchor, constant: topInset),
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
            ShellStyle.sidebarBackground.shellResolvedCGColor(for: appearance)
        searchContainer.layer?.backgroundColor =
            ShellStyle.controlFill.shellResolvedCGColor(for: appearance)
        searchContainer.layer?.borderColor =
            ShellStyle.divider.shellResolvedCGColor(for: appearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

    /// 呼出时把焦点交给搜索框。
    func focusSearch() {
        window?.makeFirstResponder(searchField)
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
        applyFilter(searchField.stringValue)
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

        let runningCount = allEntries.filter { $0.running != nil }.count
        countLabel.stringValue = runningCount > 0
            ? "\(runningCount) 个活跃 · 共 \(allEntries.count) 个"
            : "\(allEntries.count) 个任务"
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
        titleLabel.stringValue = "Lightty"
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = ShellStyle.primaryText

        countLabel.font = .systemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = ShellStyle.tertiaryText

        newTaskButton.target = self
        newTaskButton.action = #selector(newTask)

        searchContainer.wantsLayer = true
        searchContainer.layer?.backgroundColor = ShellStyle.controlFill.cgColor
        searchContainer.layer?.cornerRadius = 9
        searchContainer.layer?.borderColor = ShellStyle.divider.cgColor
        searchContainer.layer?.borderWidth = 0.5

        searchIcon.image = NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        searchIcon.contentTintColor = ShellStyle.tertiaryText
        searchIcon.imageScaling = .scaleProportionallyDown

        searchField.placeholderString = "搜索任务"
        searchField.controlSize = .regular
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 12)
        searchField.textColor = ShellStyle.primaryText
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged)
        // Borderless NSSearchFieldCell 在聚焦态会让原生 searchButtonRect 与
        // searchTextRect 发生重叠。图标由相邻 NSImageView 绘制，cell 只管文字
        // 与原生 cancel button，避免 placeholder 与放大镜共享起点。
        (searchField.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        searchContainer.searchField = searchField

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

        for v in [titleLabel, countLabel, newTaskButton, searchContainer, scroll, emptyLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            listPage.addSubview(v)
        }
        for view in [searchIcon, searchField] {
            view.translatesAutoresizingMaskIntoConstraints = false
            searchContainer.addSubview(view)
        }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: listPage.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: listPage.leadingAnchor, constant: 16),

            countLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            countLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),

            newTaskButton.trailingAnchor.constraint(equalTo: listPage.trailingAnchor, constant: -12),
            newTaskButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            newTaskButton.widthAnchor.constraint(equalToConstant: 28),
            newTaskButton.heightAnchor.constraint(equalToConstant: 28),

            searchContainer.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 16),
            searchContainer.leadingAnchor.constraint(
                equalTo: listPage.leadingAnchor, constant: ShellStyle.sidebarHorizontalInset),
            searchContainer.trailingAnchor.constraint(
                equalTo: listPage.trailingAnchor, constant: -ShellStyle.sidebarHorizontalInset),
            searchContainer.heightAnchor.constraint(equalToConstant: 34),

            searchIcon.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 10),
            // SF Symbol 的可见笔画在 13pt image frame 内约下沉 2pt；用 optical
            // offset 对齐 12pt 输入文字，而不是让两个 frame 的几何中心硬重合。
            searchIcon.centerYAnchor.constraint(
                equalTo: searchContainer.centerYAnchor, constant: -2),
            searchIcon.widthAnchor.constraint(equalToConstant: 13),
            searchIcon.heightAnchor.constraint(equalToConstant: 13),

            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 6),
            searchField.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: -7),
            searchField.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
            searchField.heightAnchor.constraint(equalToConstant: 22),

            scroll.topAnchor.constraint(equalTo: searchContainer.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: listPage.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: listPage.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: listPage.bottomAnchor, constant: -8),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor, constant: -24),
        ])
    }

    /// 新建 handoff 任务文档（只建档，不开终端；开终端由任务气泡的目的地承担）。
    @objc private func newTask() {
        NameEditorPopover.present(
            from: newTaskButton, title: "新建任务", confirmLabel: "创建"
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
    @objc private func searchChanged() { applyFilter(searchField.stringValue) }

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
        let activity = entry.running != nil ? "活跃" : "休眠"
        let subtitle = NSTextField(
            labelWithString: "\(activity)  ·  \(relativeTime(entry.task.updated))")
        subtitle.font = .systemFont(ofSize: 10.5)
        subtitle.textColor = ShellStyle.tertiaryText
        subtitle.lineBreakMode = .byTruncatingTail

        // 更多操作（⋯）：与行本体的"跳转/打开"语义分开——管理动作都在这个菜单里。
        let detailButton = ShellIconButton(
            symbol: "ellipsis", accessibilityLabel: "更多操作", target: self,
            action: #selector(showRowMenu(_:)))
        detailButton.tag = row

        let cell = NSView()
        for v in [dot, title, subtitle, detailButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
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

    private func dotColor(for entry: Entry) -> NSColor {
        entry.running != nil ? .systemGreen : .systemGray
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = max(0, -date.timeIntervalSinceNow)
        if seconds < 60 { return "刚刚" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600)) 小时前" }
        if seconds < 604_800 { return "\(Int(seconds / 86_400)) 天前" }
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {}

    // MARK: - 行「⋯」菜单（自绘气泡；纯管理动作，跳转走单击气泡/双击）

    @objc private func showRowMenu(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < filtered.count else { return }
        let entry = filtered[sender.tag]

        var items: [ShellMenuPopover.Item] = [
            .action("重命名任务…") { [weak self, weak sender] in
                guard let anchor = sender ?? self else { return }
                NameEditorPopover.present(
                    from: anchor, title: "重命名任务",
                    initial: entry.task.name, confirmLabel: "重命名"
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
        items.append(.action("打开 handoff 文档") {
            NSWorkspace.shared.open(entry.fileURL)
        })
        items.append(.action("用其他应用打开…") { [weak self, weak sender] in
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
        items.append(.action("在 Finder 中显示") {
            NSWorkspace.shared.activateFileViewerSelecting([entry.fileURL])
        })
        items.append(.separator)
        items.append(.action("归档任务") {
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
        items.append(.action("删除任务（移到废纸篓）", destructive: true) {
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

    // 搜索框：回车 = 跳转/恢复，上下键移动选择，Esc 收起抽屉
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            jumpOrRestore()
            return true
        case #selector(NSResponder.moveDown(_:)):
            guard !filtered.isEmpty else { return true }
            tableView.selectRowIndexes(
                [min(max(tableView.selectedRow, -1) + 1, filtered.count - 1)],
                byExtendingSelection: false)
            return true
        case #selector(NSResponder.moveUp(_:)):
            guard !filtered.isEmpty else { return true }
            tableView.selectRowIndexes([max(tableView.selectedRow - 1, 0)], byExtendingSelection: false)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onRequestClose?()
            return true
        default:
            return false
        }
    }

}
