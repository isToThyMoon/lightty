import AppKit
import LighttyCore

/// 恢复流程（2026-08-29 改版）：休眠任务 → 任务行旁的气泡（NSPopover）→ 三种
/// 目的地：当前 tab 新 pane / 新 tab / 新窗口。
/// **不自动注入/预填任何命令**——多行命令预填在 shell 里易碎，且 pane header 已有
/// 「注入」按钮：用户自己起 agent 后点「注入」让它读 handoff 继续，职责不重叠。
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

    /// 摘要 = 正文「下一步」「当前状态」两节（进展/卡点/下一步的最短可读集）
    static func summarize(_ body: String) -> String {
        let interesting = ["## 下一步", "## 当前状态", "## 卡点与风险"]
        var lines: [String] = []
        var keeping = false
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                keeping = interesting.contains(where: { line.hasPrefix($0) })
            }
            if keeping { lines.append(String(line)) }
            if lines.count > 14 { break }
        }
        let result = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "（handoff 正文为空）" : result
    }
}

/// 气泡内容：任务名 + handoff 摘要 + 三个恢复目的地按钮。
private final class RestorePopoverController: NSViewController {
    var onDone: (() -> Void)?

    private let fileURL: URL
    private let task: TaskFile
    private weak var controller: TerminalWindowController?

    init(fileURL: URL, task: TaskFile, controller: TerminalWindowController) {
        self.fileURL = fileURL
        self.task = task
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()

        let title = NSTextField(labelWithString: "任务：\(task.name)")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = ShellStyle.primaryText

        let summary = NSTextField(wrappingLabelWithString: RestoreFlow.summarize(task.body))
        summary.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        summary.textColor = ShellStyle.secondaryText
        summary.maximumNumberOfLines = 10
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let hint = NSTextField(
            labelWithString: "恢复后启动 claude/codex，点 header「注入」让它接手")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = ShellStyle.tertiaryText

        var rows: [NSView] = [title, summary, hint]
        var buttonRows: [NSButton] = []

        // 已打开：每个绑定该任务的运行中 pane 一行，点击直接跳转。
        let bound = AppState.shared.runningPanes().filter {
            $0.pane.taskFileURL?.standardizedFileURL == fileURL.standardizedFileURL
        }
        if !bound.isEmpty {
            rows.append(Self.sectionLabel("已打开"))
            for (index, entry) in bound.enumerated() {
                // 层级序：工作区（容器）› pane（叶子）
                let workspace = entry.controller.workspaceName(of: entry.pane)
                let label = workspace.map { "\($0) › \(entry.pane.header.title)" }
                    ?? entry.pane.header.title
                let row = RestoreRowButton(
                    "跳转 · \(label)", target: self, action: #selector(jumpToPane(_:)))
                row.tag = index
                jumpTargets = bound
                rows.append(row)
                buttonRows.append(row)
            }
        }

        rows.append(Self.sectionLabel(bound.isEmpty ? "打开到" : "再开一个"))
        let paneButton = RestoreRowButton(
            "当前 Tab 分屏", target: self, action: #selector(restoreInPane))
        let tabButton = RestoreRowButton(
            "新 Tab", target: self, action: #selector(restoreInTab))
        let windowButton = RestoreRowButton(
            "新窗口", target: self, action: #selector(restoreInWindow))
        rows.append(contentsOf: [paneButton, tabButton, windowButton])
        buttonRows.append(contentsOf: [paneButton, tabButton, windowButton])

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
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

    private var jumpTargets: [(controller: TerminalWindowController, pane: PaneView)] = []

    private static func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = ShellStyle.tertiaryText
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
        pane.bind(to: fileURL, name: task.name, status: task.status)
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

/// 恢复气泡里的目的地行：整行等宽、文字左对齐、浅底 + hover 提亮，无选中态。
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
