import AppKit
import LighttyCore

/// cmd+shift+K 悬浮侧边栏：列表 ↔ 详情两页；详情有脏编辑时钉住（不被列表刷新覆盖）。
final class SidebarController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    static let shared = SidebarController()

    private let listPage = NSView()
    private let detailPage = NSView()

    private let tableView = NSTableView()
    private var entries: [(fileURL: URL, task: TaskFile)] = []

    private let detailTitle = NSTextField(labelWithString: "")
    private let statusPopup = NSPopUpButton()
    private let bodyView = NSTextView()
    private var detailURL: URL?
    private var detailTask: TaskFile?
    private var dirty = false {
        didSet { saveButton.isEnabled = dirty }
    }
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false)
        panel.title = "任务"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        buildListPage()
        buildDetailPage()
        showList()
    }

    required init?(coder: NSCoder) { fatalError() }

    func toggle() {
        if window?.isVisible == true {
            window?.orderOut(nil)
        } else {
            if !dirty { reload() }
            window?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - 列表页

    private func buildListPage() {
        let column = NSTableColumn(identifier: .init("task"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 32
        tableView.target = self
        tableView.doubleAction = #selector(openDetail)

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        listPage.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: listPage.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: listPage.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: listPage.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: listPage.trailingAnchor),
        ])
    }

    private func reload() {
        entries = AppState.shared.taskStore.list().tasks
            .sorted { $0.task.updated > $1.task.updated }
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let label = NSTextField(labelWithString: "\(entry.task.name)  ·  \(entry.task.status.rawValue)")
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    // MARK: - 详情页

    private func buildDetailPage() {
        let backButton = NSButton(title: "‹ 列表", target: self, action: #selector(backToList))
        backButton.bezelStyle = .inline

        detailTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        detailTitle.lineBreakMode = .byTruncatingTail

        statusPopup.addItems(withTitles: TaskStatus.allCases.map(\.rawValue))
        statusPopup.target = self
        statusPopup.action = #selector(markDirty)

        bodyView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        bodyView.isRichText = false
        bodyView.delegate = self
        let bodyScroll = NSScrollView()
        bodyScroll.documentView = bodyView
        bodyScroll.hasVerticalScroller = true

        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.isEnabled = false

        for v in [backButton, detailTitle, statusPopup, bodyScroll, saveButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            detailPage.addSubview(v)
        }
        NSLayoutConstraint.activate([
            backButton.topAnchor.constraint(equalTo: detailPage.topAnchor, constant: 8),
            backButton.leadingAnchor.constraint(equalTo: detailPage.leadingAnchor, constant: 8),

            detailTitle.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            detailTitle.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 8),
            detailTitle.trailingAnchor.constraint(lessThanOrEqualTo: statusPopup.leadingAnchor, constant: -8),

            statusPopup.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            statusPopup.trailingAnchor.constraint(equalTo: detailPage.trailingAnchor, constant: -8),

            bodyScroll.topAnchor.constraint(equalTo: backButton.bottomAnchor, constant: 8),
            bodyScroll.leadingAnchor.constraint(equalTo: detailPage.leadingAnchor, constant: 8),
            bodyScroll.trailingAnchor.constraint(equalTo: detailPage.trailingAnchor, constant: -8),
            bodyScroll.bottomAnchor.constraint(equalTo: saveButton.topAnchor, constant: -8),

            saveButton.trailingAnchor.constraint(equalTo: detailPage.trailingAnchor, constant: -8),
            saveButton.bottomAnchor.constraint(equalTo: detailPage.bottomAnchor, constant: -8),
        ])
    }

    @objc private func openDetail() {
        guard tableView.selectedRow >= 0, tableView.selectedRow < entries.count else { return }
        let entry = entries[tableView.selectedRow]
        detailURL = entry.fileURL
        detailTask = entry.task
        detailTitle.stringValue = entry.task.name
        statusPopup.selectItem(withTitle: entry.task.status.rawValue)
        bodyView.string = entry.task.body
        dirty = false
        showDetail()
    }

    @objc private func backToList() {
        // 脏编辑钉住：有未保存修改时不离开详情页
        guard !dirty else { NSSound.beep(); return }
        reload()
        showList()
    }

    @objc private func markDirty() { dirty = true }

    func textDidChange(_ notification: Notification) { dirty = true }

    @objc private func save() {
        guard let url = detailURL, var task = detailTask else { return }
        if let status = TaskStatus(rawValue: statusPopup.titleOfSelectedItem ?? "") {
            task.status = status
        }
        task.body = bodyView.string
        do {
            try AppState.shared.taskStore.update(at: url, task: task)
            detailTask = task
            dirty = false
        } catch {
            NSSound.beep()
            NSLog("task save failed: \(error)")
        }
    }

    private func showList() { setPage(listPage) }
    private func showDetail() { setPage(detailPage) }

    private func setPage(_ page: NSView) {
        guard let content = window?.contentView else { return }
        content.subviews.forEach { $0.removeFromSuperview() }
        page.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: content.topAnchor),
            page.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
    }
}
