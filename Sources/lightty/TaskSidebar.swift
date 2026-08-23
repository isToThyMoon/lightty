import AppKit
import LighttyCore

/// cmd+K 任务侧边栏：窗口内**悬浮左侧**卡片，任务管理的唯一入口
/// （独立居中面板已否决：视觉转换成本高）。
/// 列表页 = 全部任务（运行中/休眠、模糊搜索、双击跳转或恢复）；
/// 详情页 = 单个任务的 md 正文与状态编辑。脏编辑钉住：未保存时不被收起/刷新。
final class TaskSidebar: NSView, NSTableViewDataSource, NSTableViewDelegate,
                         NSTextViewDelegate, NSSearchFieldDelegate {
    static let width: CGFloat = 320
    static let inset: CGFloat = 12

    private struct Entry {
        let fileURL: URL
        let task: TaskFile
        /// 有 pane 绑着 = 运行中
        let running: (controller: TerminalWindowController, pane: PaneView)?
    }

    // 列表页
    private let listPage = NSView()
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let openButton = NSButton(title: "详情", target: nil, action: nil)
    private let jumpButton = NSButton(title: "跳转", target: nil, action: nil)
    private var allEntries: [Entry] = []
    private var filtered: [Entry] = []

    // 详情页
    private let detailPage = NSView()
    private let detailTitle = NSTextField(labelWithString: "")
    private let statusPopup = NSPopUpButton()
    private let pathLabel = NSTextField(labelWithString: "")
    private let bodyView = NSTextView()
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)
    private var detailURL: URL?
    private var detailTask: TaskFile?

    /// 脏编辑钉住：外部据此拒绝收起
    private(set) var isDirty = false {
        didSet { saveButton.isEnabled = isDirty }
    }

    var onRequestClose: (() -> Void)?

    init() {
        super.init(frame: .zero)

        // 悬浮卡片：圆角 + 边框 + 投影；颜色一律来自 ghostty config（视觉铁律）
        wantsLayer = true
        let cfg = GhosttyRuntime.shared.configValues
        layer?.backgroundColor = cfg.backgroundColor
            .withAlphaComponent(max(cfg.backgroundOpacity, 0.92)).cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = cfg.splitDividerColor.cgColor
        shadow = NSShadow()
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -4)

        buildListPage()
        buildDetailPage()
        showList()
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 呼出时把焦点交给搜索框
    func focusSearch() {
        window?.makeFirstResponder(searchField)
    }

    // MARK: - 数据

    func reload() {
        guard !isDirty else { return } // 脏编辑钉住
        let running = AppState.shared.runningPanes()
        allEntries = AppState.shared.taskStore.list().tasks
            .map { entry in
                let bound = running.first { $0.pane.taskFileURL?.standardizedFileURL == entry.fileURL.standardizedFileURL }
                return Entry(fileURL: entry.fileURL, task: entry.task, running: bound)
            }
            .sorted {
                // 运行中置顶，其余按最近更新
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
        tableView.reloadData()
        if !filtered.isEmpty {
            tableView.selectRowIndexes([0], byExtendingSelection: false)
        }
        updateListButtons()
    }

    private var selectedEntry: Entry? {
        guard tableView.selectedRow >= 0, tableView.selectedRow < filtered.count else { return nil }
        return filtered[tableView.selectedRow]
    }

    // MARK: - 列表页

    private func buildListPage() {
        let cfg = GhosttyRuntime.shared.configValues

        searchField.placeholderString = "搜索任务…"
        searchField.controlSize = .small
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged)

        let column = NSTableColumn(identifier: .init("task"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 40
        tableView.backgroundColor = .clear
        tableView.target = self
        tableView.doubleAction = #selector(jumpOrRestore)

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        for (button, action) in [(openButton, #selector(openDetail)),
                                 (jumpButton, #selector(jumpOrRestore))] {
            button.bezelStyle = .inline
            button.controlSize = .small
            button.target = self
            button.action = action
        }

        let hint = NSTextField(labelWithString: "双击 = 跳转 / 恢复")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = cfg.foregroundColor.withAlphaComponent(0.4)

        for v in [searchField, scroll, hint, openButton, jumpButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            listPage.addSubview(v)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: listPage.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: listPage.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: listPage.trailingAnchor, constant: -12),

            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: listPage.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: listPage.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: openButton.topAnchor, constant: -8),

            hint.leadingAnchor.constraint(equalTo: listPage.leadingAnchor, constant: 12),
            hint.centerYAnchor.constraint(equalTo: openButton.centerYAnchor),

            jumpButton.trailingAnchor.constraint(equalTo: listPage.trailingAnchor, constant: -12),
            jumpButton.bottomAnchor.constraint(equalTo: listPage.bottomAnchor, constant: -12),
            openButton.trailingAnchor.constraint(equalTo: jumpButton.leadingAnchor, constant: -6),
            openButton.bottomAnchor.constraint(equalTo: jumpButton.bottomAnchor),
        ])
    }

    @objc private func searchChanged() {
        applyFilter(searchField.stringValue)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = filtered[row]
        let cfg = GhosttyRuntime.shared.configValues

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = (entry.running != nil
            ? NSColor.systemGreen
            : (entry.task.status == .stuck ? .systemOrange : .systemGray)).cgColor

        let title = NSTextField(labelWithString: entry.task.name)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = cfg.foregroundColor
        title.lineBreakMode = .byTruncatingTail

        let subtitle = NSTextField(labelWithString:
            "\(entry.running != nil ? "运行中" : "休眠") · \(entry.task.status.rawValue)")
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = cfg.foregroundColor.withAlphaComponent(0.5)

        let cell = NSView()
        for v in [dot, title, subtitle] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            dot.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            title.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateListButtons()
    }

    private func updateListButtons() {
        let entry = selectedEntry
        openButton.isEnabled = entry != nil
        jumpButton.isEnabled = entry != nil
        jumpButton.title = entry?.running != nil ? "跳转" : "恢复"
    }

    /// 双击 / 「跳转·恢复」：运行中 → 聚焦对应 pane；休眠 → 恢复流程
    @objc private func jumpOrRestore() {
        guard let entry = selectedEntry else { return }
        if let running = entry.running {
            running.controller.window?.makeKeyAndOrderFront(nil)
            running.pane.focusTerminal()
            onRequestClose?()
        } else {
            onRequestClose?()
            RestoreFlow.begin(fileURL: entry.fileURL, task: entry.task)
        }
    }

    // 搜索框：回车 = 跳转/恢复，上下键移动选择，Esc 收起侧边栏
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            jumpOrRestore()
            return true
        case #selector(NSResponder.moveDown(_:)):
            tableView.selectRowIndexes([min(tableView.selectedRow + 1, filtered.count - 1)], byExtendingSelection: false)
            return true
        case #selector(NSResponder.moveUp(_:)):
            tableView.selectRowIndexes([max(tableView.selectedRow - 1, 0)], byExtendingSelection: false)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onRequestClose?()
            return true
        default:
            return false
        }
    }

    // MARK: - 详情页

    private func buildDetailPage() {
        let cfg = GhosttyRuntime.shared.configValues

        let backButton = NSButton(title: "‹ 列表", target: self, action: #selector(backToList))
        backButton.bezelStyle = .inline
        backButton.controlSize = .small

        detailTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        detailTitle.textColor = cfg.foregroundColor
        detailTitle.lineBreakMode = .byTruncatingTail

        statusPopup.addItems(withTitles: TaskStatus.allCases.map(\.rawValue))
        statusPopup.controlSize = .small
        statusPopup.target = self
        statusPopup.action = #selector(markDirty)

        pathLabel.font = .systemFont(ofSize: 10)
        pathLabel.textColor = cfg.foregroundColor.withAlphaComponent(0.5)
        pathLabel.lineBreakMode = .byTruncatingMiddle

        bodyView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        bodyView.isRichText = false
        bodyView.drawsBackground = false
        bodyView.textColor = cfg.foregroundColor
        bodyView.insertionPointColor = cfg.foregroundColor
        bodyView.delegate = self
        let bodyScroll = NSScrollView()
        bodyScroll.documentView = bodyView
        bodyScroll.hasVerticalScroller = true
        bodyScroll.drawsBackground = false

        saveButton.bezelStyle = .inline
        saveButton.controlSize = .small
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.isEnabled = false

        for v in [backButton, detailTitle, statusPopup, pathLabel, bodyScroll, saveButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            detailPage.addSubview(v)
        }
        NSLayoutConstraint.activate([
            backButton.topAnchor.constraint(equalTo: detailPage.topAnchor, constant: 10),
            backButton.leadingAnchor.constraint(equalTo: detailPage.leadingAnchor, constant: 12),

            detailTitle.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            detailTitle.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 8),
            detailTitle.trailingAnchor.constraint(lessThanOrEqualTo: statusPopup.leadingAnchor, constant: -8),

            statusPopup.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            statusPopup.trailingAnchor.constraint(equalTo: detailPage.trailingAnchor, constant: -12),

            pathLabel.topAnchor.constraint(equalTo: backButton.bottomAnchor, constant: 4),
            pathLabel.leadingAnchor.constraint(equalTo: detailPage.leadingAnchor, constant: 12),
            pathLabel.trailingAnchor.constraint(equalTo: detailPage.trailingAnchor, constant: -12),

            bodyScroll.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 8),
            bodyScroll.leadingAnchor.constraint(equalTo: detailPage.leadingAnchor, constant: 12),
            bodyScroll.trailingAnchor.constraint(equalTo: detailPage.trailingAnchor, constant: -12),
            bodyScroll.bottomAnchor.constraint(equalTo: saveButton.topAnchor, constant: -8),

            saveButton.trailingAnchor.constraint(equalTo: detailPage.trailingAnchor, constant: -12),
            saveButton.bottomAnchor.constraint(equalTo: detailPage.bottomAnchor, constant: -12),
        ])
    }

    @objc private func openDetail() {
        guard let entry = selectedEntry else { return }
        detailURL = entry.fileURL
        detailTask = entry.task
        detailTitle.stringValue = entry.task.name
        statusPopup.selectItem(withTitle: entry.task.status.rawValue)
        pathLabel.stringValue = entry.fileURL.path
        bodyView.string = entry.task.body
        isDirty = false
        showDetail()
    }

    @objc private func backToList() {
        guard !isDirty else { NSSound.beep(); return } // 脏编辑钉住
        showList()
        reload()
    }

    @objc private func markDirty() { isDirty = true }

    func textDidChange(_ notification: Notification) { isDirty = true }

    @objc private func save() {
        guard let url = detailURL, var task = detailTask else { return }
        if let status = TaskStatus(rawValue: statusPopup.titleOfSelectedItem ?? "") {
            task.status = status
        }
        task.body = bodyView.string
        do {
            try AppState.shared.taskStore.update(at: url, task: task)
            detailTask = task
            isDirty = false
        } catch {
            NSSound.beep()
            NSLog("task save failed: \(error)")
        }
    }

    // MARK: - 翻页

    private func showList() { setPage(listPage) }
    private func showDetail() { setPage(detailPage) }

    private func setPage(_ page: NSView) {
        listPage.removeFromSuperview()
        detailPage.removeFromSuperview()
        page.translatesAutoresizingMaskIntoConstraints = false
        addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: topAnchor),
            page.bottomAnchor.constraint(equalTo: bottomAnchor),
            page.leadingAnchor.constraint(equalTo: leadingAnchor),
            page.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
}
