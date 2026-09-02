import AppKit
import LighttyCore

/// 任务打开流程：任务行旁的气泡展示 handoff 摘要、已打开的 pane，
/// 以及当前工作区新 pane / 新工作区 / 新窗口三种目的地。
enum RestoreFlow {
    private static var popover: NSPopover?

    static func begin(
        fileURL: URL,
        task: TaskFile,
        from anchor: NSView,
        in controller: TerminalWindowController
    ) {
        popover?.close()
        let content = RestorePopoverController(
            fileURL: fileURL, task: task, controller: controller)
        let pop = NSPopover()
        pop.contentViewController = content
        pop.behavior = .transient
        content.onDone = { [weak pop] in pop?.close() }
        popover = pop
        pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
    }

    /// 摘要 = 正文 Next steps / Current state / Blockers 三节（分诊最短可读集）。
    /// 中文节头是 2026-08-30 协议迁英文前的旧格式，为既有任务文件保留解析。
    static func summarize(_ body: String) -> String {
        let interesting = [
            "## Next steps", "## Current state", "## Blockers & risks",
            "## 下一步", "## 当前状态", "## 卡点与风险",
        ]
        var lines: [String] = []
        var keeping = false
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                keeping = interesting.contains(where: { line.hasPrefix($0) })
            }
            if keeping { lines.append(String(line)) }
            if lines.count > 14 { break }
        }
        let result = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? L("No handoff summary yet") : result
    }
}

/// 任务气泡：任务名 + handoff 摘要 + 已打开 pane + 三个打开目的地。
private final class RestorePopoverController: NSViewController {
    var onDone: (() -> Void)?

    private let fileURL: URL
    private let task: TaskFile
    private weak var controller: TerminalWindowController?
    private var jumpTargets: [(controller: TerminalWindowController, pane: PaneView)] = []

    init(fileURL: URL, task: TaskFile, controller: TerminalWindowController) {
        self.fileURL = fileURL
        self.task = task
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()

        let title = NSTextField(labelWithString: L("Task: %@", task.name))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = ShellStyle.primaryText

        let summary = NSTextField(wrappingLabelWithString: RestoreFlow.summarize(task.body))
        summary.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        summary.textColor = ShellStyle.secondaryText
        summary.maximumNumberOfLines = 10
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var rows: [NSView] = [title, summary]
        var buttonRows: [NSButton] = []
        var sectionLabels: [NSView] = []

        // 已打开：每个绑定该任务的运行中 pane 一行，点击直接跳转。
        let bound = AppState.shared.runningPanes().filter {
            $0.pane.taskFileURL?.standardizedFileURL == fileURL.standardizedFileURL
        }
        if !bound.isEmpty {
            let opened = Self.sectionLabel(L("Already open"))
            rows.append(opened)
            sectionLabels.append(opened)
            for (index, entry) in bound.enumerated() {
                let workspace = entry.controller.workspaceName(of: entry.pane)
                let label = workspace.map { "\($0) › \(entry.pane.header.title)" }
                    ?? entry.pane.header.title
                let row = RestoreRowButton(
                    L("Jump · %@", label), target: self,
                    action: #selector(jumpToPane(_:)))
                row.tag = index
                jumpTargets = bound
                rows.append(row)
                buttonRows.append(row)
            }
        }

        let destinations = Self.sectionLabel(bound.isEmpty ? L("Open in") : L("Open another"))
        rows.append(destinations)
        sectionLabels.append(destinations)
        let paneButton = RestoreRowButton(
            L("Split in current workspace"), target: self,
            action: #selector(restoreInPane))
        let tabButton = RestoreRowButton(
            L("New workspace"), target: self,
            action: #selector(restoreInTab))
        let windowButton = RestoreRowButton(
            L("New window"), target: self,
            action: #selector(restoreInWindow))
        rows.append(contentsOf: [paneButton, tabButton, windowButton])
        buttonRows.append(contentsOf: [paneButton, tabButton, windowButton])

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        for label in sectionLabels {
            if let index = rows.firstIndex(where: { $0 === label }), index > 0 {
                stack.setCustomSpacing(14, after: rows[index - 1])
            }
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        var constraints = [
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            root.widthAnchor.constraint(equalToConstant: 320),
        ]
        for button in buttonRows {
            constraints.append(button.heightAnchor.constraint(equalToConstant: 30))
            constraints.append(button.widthAnchor.constraint(equalTo: stack.widthAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        view = root
    }

    private static func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = ShellStyle.secondaryText
        return label
    }

    @objc private func jumpToPane(_ sender: NSButton) {
        guard jumpTargets.indices.contains(sender.tag) else { return }
        let target = jumpTargets[sender.tag]
        target.controller.window?.makeKeyAndOrderFront(nil)
        target.controller.reveal(pane: target.pane)
        onDone?()
    }

    private func makeBoundPane() -> PaneView {
        let pane = PaneView()
        pane.bind(to: fileURL, name: task.name)
        return pane
    }

    @objc private func restoreInPane() {
        controller?.addPaneToActiveTab(makeBoundPane())
        onDone?()
    }

    @objc private func restoreInTab() {
        controller?.addTab(initialPane: makeBoundPane())
        onDone?()
    }

    @objc private func restoreInWindow() {
        AppState.shared.newWindow(initialPane: makeBoundPane())
        onDone?()
    }
}

/// 任务气泡里的操作行：整行等宽、文字左对齐、浅底 + hover 提亮，无选中态。
private final class RestoreRowButton: NSButton {
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { applyFill() } }

    init(_ label: String, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        focusRingType = .none
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = ShellStyle.controlCornerRadius

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.firstLineHeadIndent = 10
        attributedTitle = NSAttributedString(
            string: label,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: ShellStyle.primaryText,
                .paragraphStyle: paragraph,
            ])
        applyFill()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFill()
    }

    private func applyFill() {
        let fill = hovered ? ShellStyle.selectionFill : ShellStyle.controlFill
        layer?.backgroundColor = fill.shellResolvedCGColor(for: effectiveAppearance)
    }
}
