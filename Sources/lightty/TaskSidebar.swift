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
        /// 有 pane 绑着 = 运行中
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
        symbol: "plus", accessibilityLabel: "新任务", target: nil, action: nil)
    private var allEntries: [Entry] = []
    private var filtered: [Entry] = []

    // MARK: - 详情页

    private let detailPage = NSView()
    private let detailTitle = NSTextField(labelWithString: "")
    private let statusPopup = NSPopUpButton()
    private let pathLabel = NSTextField(labelWithString: "")
    private let bodyView = NSTextView()
    private let saveButton = ShellTextButton("保存", emphasis: .primary, target: nil, action: nil)
    private var detailURL: URL?
    private var detailTask: TaskFile?

    private weak var currentPage: NSView?
    private var hoverTrackingArea: NSTrackingArea?

    /// 脏编辑钉住：外部据此拒绝收起
    private(set) var isDirty = false {
        didSet { saveButton.isEnabled = isDirty }
    }

    var onRequestClose: (() -> Void)?
    var onRequestNewTask: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?

    /// 内容避开顶部标题栏区域的高度（抽屉背景本体延伸到窗口最顶端）
    private let topInset: CGFloat

    init(topInset: CGFloat) {
        self.topInset = topInset
        super.init(frame: .zero)

        clipsToBounds = false
        wantsLayer = true
        layer?.backgroundColor = ShellStyle.sidebarBackground.cgColor
        appearance = NSAppearance(named: .aqua)

        let edge = NSView()
        edge.wantsLayer = true
        edge.layer?.backgroundColor = ShellStyle.divider.cgColor
        edge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(edge)
        NSLayoutConstraint.activate([
            edge.trailingAnchor.constraint(equalTo: trailingAnchor),
            edge.topAnchor.constraint(equalTo: topAnchor),
            edge.bottomAnchor.constraint(equalTo: bottomAnchor),
            edge.widthAnchor.constraint(equalToConstant: 1),
        ])

        buildListPage()
        buildDetailPage()
        showList(animated: false)
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

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

    /// 呼出时把焦点交给搜索框；若停留在详情页则保留编辑上下文。
    func focusSearch() {
        guard currentPage === listPage else { return }
        window?.makeFirstResponder(searchField)
    }

    override func cancelOperation(_ sender: Any?) {
        onRequestClose?()
    }

    // MARK: - 数据

    func reload() {
        guard !isDirty else { return } // 脏编辑钉住
        let running = AppState.shared.runningPanes()
        allEntries = AppState.shared.taskStore.list().tasks
            .map { entry in
                let bound = running.first {
                    $0.pane.taskFileURL?.standardizedFileURL == entry.fileURL.standardizedFileURL
                }
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

        let runningCount = allEntries.filter { $0.running != nil }.count
        countLabel.stringValue = runningCount > 0
            ? "\(runningCount) 个运行中 · 共 \(allEntries.count) 个"
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

    @objc private func newTask() { onRequestNewTask?() }
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

        let state = entry.running != nil ? "运行中" : statusTitle(entry.task.status)
        let subtitle = NSTextField(labelWithString: "\(state)  ·  \(relativeTime(entry.task.updated))")
        subtitle.font = .systemFont(ofSize: 10.5)
        subtitle.textColor = ShellStyle.tertiaryText
        subtitle.lineBreakMode = .byTruncatingTail

        let detailButton = ShellIconButton(
            symbol: "chevron.right", accessibilityLabel: "任务详情", target: self,
            action: #selector(openDetailFromRow(_:)))
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
        if entry.running != nil { return .systemGreen }
        switch entry.task.status {
        case .active: return .systemGray
        case .stuck: return .systemOrange
        case .done: return .systemGray.withAlphaComponent(0.45)
        }
    }

    private func statusTitle(_ status: TaskStatus) -> String {
        switch status {
        case .active: return "休眠"
        case .stuck: return "卡住"
        case .done: return "已完成"
        }
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

    @objc private func openDetailFromRow(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < filtered.count else { return }
        tableView.selectRowIndexes([sender.tag], byExtendingSelection: false)
        openDetail()
    }

    /// 双击 / Enter：运行中 → 聚焦对应 pane；休眠 → 恢复流程
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

    // MARK: - 详情页

    private func buildDetailPage() {
        let backButton = ShellIconButton(
            symbol: "chevron.left", accessibilityLabel: "返回任务列表", target: self,
            action: #selector(backToList))

        detailTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        detailTitle.textColor = ShellStyle.primaryText
        detailTitle.lineBreakMode = .byTruncatingTail

        statusPopup.addItems(withTitles: TaskStatus.allCases.map(statusTitle))
        statusPopup.controlSize = .small
        statusPopup.bezelStyle = .inline
        statusPopup.font = .systemFont(ofSize: 10.5, weight: .medium)
        statusPopup.contentTintColor = ShellStyle.secondaryText
        statusPopup.target = self
        statusPopup.action = #selector(markDirty)

        let pathIcon = NSImageView(image: NSImage(
            systemSymbolName: "folder", accessibilityDescription: "任务目录") ?? NSImage())
        pathIcon.contentTintColor = ShellStyle.tertiaryText
        pathIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)

        pathLabel.font = .systemFont(ofSize: 10.5)
        pathLabel.textColor = ShellStyle.tertiaryText
        pathLabel.lineBreakMode = .byTruncatingMiddle

        bodyView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        bodyView.isRichText = false
        bodyView.drawsBackground = false
        bodyView.textColor = ShellStyle.primaryText
        bodyView.insertionPointColor = ShellStyle.primaryText
        bodyView.textContainerInset = NSSize(width: 9, height: 9)
        bodyView.delegate = self

        let bodyScroll = NSScrollView()
        bodyScroll.documentView = bodyView
        bodyScroll.hasVerticalScroller = true
        bodyScroll.autohidesScrollers = true
        bodyScroll.drawsBackground = false
        bodyScroll.scrollerStyle = .overlay
        bodyScroll.wantsLayer = true
        bodyScroll.layer?.backgroundColor = ShellStyle.controlFill.cgColor
        bodyScroll.layer?.cornerRadius = 10
        bodyScroll.layer?.borderColor = ShellStyle.divider.cgColor
        bodyScroll.layer?.borderWidth = 0.5
        bodyScroll.clipsToBounds = true

        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.isEnabled = false

        let pathRow = NSStackView(views: [pathIcon, pathLabel])
        pathRow.orientation = .horizontal
        pathRow.spacing = 6
        pathRow.alignment = .centerY

        for v in [backButton, detailTitle, statusPopup, pathRow, bodyScroll, saveButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            detailPage.addSubview(v)
        }
        NSLayoutConstraint.activate([
            backButton.topAnchor.constraint(equalTo: detailPage.topAnchor, constant: 14),
            backButton.leadingAnchor.constraint(equalTo: detailPage.leadingAnchor, constant: 10),
            backButton.widthAnchor.constraint(equalToConstant: 28),
            backButton.heightAnchor.constraint(equalToConstant: 28),

            detailTitle.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            detailTitle.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 6),
            detailTitle.trailingAnchor.constraint(lessThanOrEqualTo: statusPopup.leadingAnchor, constant: -8),

            statusPopup.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            statusPopup.trailingAnchor.constraint(equalTo: detailPage.trailingAnchor, constant: -12),

            pathRow.topAnchor.constraint(equalTo: backButton.bottomAnchor, constant: 13),
            pathRow.leadingAnchor.constraint(equalTo: detailPage.leadingAnchor, constant: 16),
            pathRow.trailingAnchor.constraint(equalTo: detailPage.trailingAnchor, constant: -16),

            bodyScroll.topAnchor.constraint(equalTo: pathRow.bottomAnchor, constant: 12),
            bodyScroll.leadingAnchor.constraint(equalTo: detailPage.leadingAnchor, constant: 12),
            bodyScroll.trailingAnchor.constraint(equalTo: detailPage.trailingAnchor, constant: -12),
            bodyScroll.bottomAnchor.constraint(equalTo: saveButton.topAnchor, constant: -12),

            saveButton.trailingAnchor.constraint(equalTo: detailPage.trailingAnchor, constant: -12),
            saveButton.bottomAnchor.constraint(equalTo: detailPage.bottomAnchor, constant: -12),
            saveButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
            saveButton.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    @objc private func openDetail() {
        guard let entry = selectedEntry else { return }
        detailURL = entry.fileURL
        detailTask = entry.task
        detailTitle.stringValue = entry.task.name
        statusPopup.selectItem(at: TaskStatus.allCases.firstIndex(of: entry.task.status) ?? 0)
        pathLabel.stringValue = entry.task.cwd
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
        let index = max(statusPopup.indexOfSelectedItem, 0)
        if index < TaskStatus.allCases.count { task.status = TaskStatus.allCases[index] }
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

    private func showList(animated: Bool = true) { setPage(listPage, animated: animated) }
    private func showDetail() { setPage(detailPage, animated: true) }

    private func setPage(_ page: NSView, animated: Bool) {
        guard currentPage !== page else { return }
        let old = currentPage
        page.translatesAutoresizingMaskIntoConstraints = false
        page.alphaValue = animated ? 0 : 1
        addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: topAnchor, constant: topInset),
            page.bottomAnchor.constraint(equalTo: bottomAnchor),
            page.leadingAnchor.constraint(equalTo: leadingAnchor),
            page.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        layoutSubtreeIfNeeded()
        currentPage = page

        guard animated, let old else {
            old?.removeFromSuperview()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            old.animator().alphaValue = 0
            page.animator().alphaValue = 1
        } completionHandler: {
            old.removeFromSuperview()
        }
    }
}
