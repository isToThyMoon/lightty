import AppKit
import LighttyCore

/// cmd+K 任务面板（HANDOVER 8.2）：运行中 + 休眠任务同列，模糊搜索，
/// 回车跳转（运行中）或进恢复流程（休眠），右侧预览 handoff 摘要。用完即散。
final class TaskPanelController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    static let shared = TaskPanelController()

    enum Item {
        case running(controller: TerminalWindowController, pane: PaneView)
        case dormant(fileURL: URL, task: TaskFile)

        var title: String {
            switch self {
            case .running(_, let pane): return pane.header.title
            case .dormant(_, let task): return task.name
            }
        }

        var subtitle: String {
            switch self {
            case .running: return "运行中"
            case .dormant(_, let task): return "休眠 · \(task.status.rawValue)"
            }
        }
    }

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let previewView = NSTextView()
    private var allItems: [Item] = []
    private var filtered: [Item] = []

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 400),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        super.init(window: panel)

        let content = NSView()
        panel.contentView = content

        searchField.placeholderString = "搜索任务…"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged)

        let column = NSTableColumn(identifier: .init("task"))
        column.width = 320
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 36
        tableView.target = self
        tableView.doubleAction = #selector(activateSelection)

        let tableScroll = NSScrollView()
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true

        previewView.isEditable = false
        previewView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let previewScroll = NSScrollView()
        previewScroll.documentView = previewView
        previewScroll.hasVerticalScroller = true

        for v in [searchField, tableScroll, previewScroll] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),

            tableScroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            tableScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            tableScroll.widthAnchor.constraint(equalToConstant: 330),
            tableScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),

            previewScroll.topAnchor.constraint(equalTo: tableScroll.topAnchor),
            previewScroll.leadingAnchor.constraint(equalTo: tableScroll.trailingAnchor, constant: 8),
            previewScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            previewScroll.bottomAnchor.constraint(equalTo: tableScroll.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func toggle() {
        if window?.isVisible == true {
            window?.orderOut(nil)
        } else {
            reload()
            searchField.stringValue = ""
            applyFilter("")
            window?.center()
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(searchField)
        }
    }

    private func reload() {
        var items: [Item] = []
        var boundURLs = Set<URL>()
        for (controller, pane) in AppState.shared.runningPanes() {
            items.append(.running(controller: controller, pane: pane))
            if let url = pane.taskFileURL { boundURLs.insert(url.standardizedFileURL) }
        }
        // 休眠 = 命名过（有文件）且当前没有 pane 绑着
        let listed = AppState.shared.taskStore.list()
        for entry in listed.tasks where !boundURLs.contains(entry.fileURL.standardizedFileURL) {
            items.append(.dormant(fileURL: entry.fileURL, task: entry.task))
        }
        allItems = items
    }

    // MARK: - 过滤（LighttyCore.FuzzyMatch 贪心子序列评分）

    @objc private func searchChanged() {
        applyFilter(searchField.stringValue)
    }

    private func applyFilter(_ query: String) {
        if query.isEmpty {
            filtered = allItems
        } else {
            filtered = allItems
                .compactMap { item -> (Item, Int)? in
                    guard let score = FuzzyMatch.score(pattern: query, in: item.title) else { return nil }
                    return (item, score)
                }
                .sorted { $0.1 > $1.1 }
                .map { $0.0 }
        }
        tableView.reloadData()
        if !filtered.isEmpty {
            tableView.selectRowIndexes([0], byExtendingSelection: false)
        }
        updatePreview()
    }

    // MARK: - 表格

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = filtered[row]
        let cell = NSStackView()
        cell.orientation = .vertical
        cell.alignment = .leading
        cell.spacing = 1
        cell.edgeInsets = .init(top: 3, left: 4, bottom: 3, right: 4)
        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        let subtitle = NSTextField(labelWithString: item.subtitle)
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = .secondaryLabelColor
        cell.addArrangedSubview(title)
        cell.addArrangedSubview(subtitle)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updatePreview()
    }

    private func updatePreview() {
        guard tableView.selectedRow >= 0, tableView.selectedRow < filtered.count else {
            previewView.string = ""
            return
        }
        switch filtered[tableView.selectedRow] {
        case .running(_, let pane):
            if let url = pane.taskFileURL, let task = try? AppState.shared.taskStore.load(at: url) {
                previewView.string = task.body
            } else {
                previewView.string = "（未命名任务，尚无 handoff 文件）"
            }
        case .dormant(_, let task):
            previewView.string = task.body
        }
    }

    // MARK: - 激活

    /// 回车/双击：运行中 → 跳转；休眠 → 恢复流程
    @objc func activateSelection() {
        guard tableView.selectedRow >= 0, tableView.selectedRow < filtered.count else { return }
        let item = filtered[tableView.selectedRow]
        window?.orderOut(nil)
        switch item {
        case .running(let controller, let pane):
            controller.window?.makeKeyAndOrderFront(nil)
            pane.focusTerminal()
        case .dormant(let fileURL, let task):
            RestoreFlow.begin(fileURL: fileURL, task: task)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            activateSelection()
            return true
        case #selector(NSResponder.moveDown(_:)):
            tableView.selectRowIndexes([min(tableView.selectedRow + 1, filtered.count - 1)], byExtendingSelection: false)
            return true
        case #selector(NSResponder.moveUp(_:)):
            tableView.selectRowIndexes([max(tableView.selectedRow - 1, 0)], byExtendingSelection: false)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            window?.orderOut(nil)
            return true
        default:
            return false
        }
    }
}
