import AppKit
import LighttyCore

/// 任务启动流程：展示摘要与已打开的 pane，选择 Agent 和位置后再创建终端。
enum RestoreFlow {
    private static var popover: NSPopover?
    static func dismiss() { popover?.close(); popover = nil }

    static func begin(
        fileURL: URL,
        task: TaskFile,
        from anchor: NSView,
        in controller: TerminalWindowController
    ) {
        popover?.close()
        // 打开时重读磁盘：调用方传来的 task 是列表缓存的快照，agent 直接写
        // 文件不触发内部通知，快照可能停在写入前（正文为空 → 摘要空白）。
        // 气泡是「看一眼现状」的动作，以磁盘为准；读不了再用快照兜底。
        let freshTask = (try? AppState.shared.taskStore.load(at: fileURL)) ?? task
        let content = RestorePopoverController(
            fileURL: fileURL, task: freshTask, controller: controller)
        let pop = NSPopover()
        pop.contentViewController = content
        pop.behavior = .transient
        content.onDone = { [weak pop] in pop?.close() }
        content.directory.onPickerVisibilityChange = { [weak pop] choosing in
            pop?.behavior = choosing ? .applicationDefined : .transient
        }
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
        if !result.isEmpty { return result }
        // 兜底：agent 写的节头不在协议集合里时，展示正文开头——有内容
        // 就不该显示「暂无摘要」
        let head = body.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(12)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return head.isEmpty ? L("No handoff summary yet") : head
    }
}

/// 任务气泡：Agent 快速切换与位置选择相互独立，点击启动才创建终端。
final class RestorePopoverController: NSViewController {
    var onDone: (() -> Void)?

    private let fileURL: URL
    private let task: TaskFile
    private let embedded: Bool
    private weak var controller: TerminalWindowController?
    private var jumpTargets: [(controller: TerminalWindowController, pane: PaneView)] = []
    private var selectedAgent = AgentLaunchPreference.selected()
    private let agentPicker = NSPopUpButton()
    private let launchButton = ShellAccentButton()
    private var destinationButtons: [NSButton] = []
    private var selectedDestination = 1
    private let contextHint = NSTextField(wrappingLabelWithString: "")
    let directory: WorkingDirectoryEditor
    private var defaultDirectory: String
    let saveDirectory = RestoreSelectionButton(L("Set as default directory on launch"), checkbox: true, target: nil, action: nil)
    private let directoryError = NSTextField(wrappingLabelWithString: "")

    init(fileURL: URL, task: TaskFile, controller: TerminalWindowController, embedded: Bool = false) {
        self.embedded = embedded
        self.fileURL = fileURL
        self.task = task
        defaultDirectory = task.workdir
        directory = WorkingDirectoryEditor(path: task.workdir)
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
        directory.onPathChange = { [weak self] in self?.updateDirectoryPresentation() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()

        let title = NSTextField(labelWithString: L("Start working"))
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.textColor = ShellStyle.primaryText
        let taskName = NSTextField(wrappingLabelWithString: task.name)
        taskName.font = .systemFont(ofSize: 13, weight: .semibold)
        taskName.textColor = ShellStyle.primaryText
        taskName.isSelectable = false

        let summary = NSTextField(wrappingLabelWithString: RestoreFlow.summarize(task.body))
        summary.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        summary.textColor = ShellStyle.secondaryText
        summary.maximumNumberOfLines = 10
        // wrappingLabel 默认可选择，点击会创建不受 maximumNumberOfLines 限制的
        // field editor，完整正文随之盖住下面的启动控件。此处只展示静态摘要。
        summary.isSelectable = false
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var rows: [NSView] = embedded ? [] : [title, taskName, summary]
        var buttonRows: [NSButton] = []
        var sectionLabels: [NSView] = []
        var sectionDivider: NSView?

        // 已打开：每个绑定该任务的运行中 pane 一行，点击直接跳转。
        let bound = AppState.shared.runningPanes().filter {
            $0.pane.taskFileURL?.standardizedFileURL == fileURL.standardizedFileURL
        }
        if !bound.isEmpty {
            let opened = NSTextField(labelWithString: L("Already open"))
            opened.font = .systemFont(ofSize: 13, weight: .semibold)
            opened.textColor = ShellStyle.primaryText
            rows.append(opened)
            sectionLabels.append(opened)
            for (index, entry) in bound.enumerated() {
                let tab = entry.controller.tabName(of: entry.pane)
                let row = RestoreRowButton(
                    terminalName: entry.pane.header.title, location: tab, target: self,
                    action: #selector(jumpToPane(_:)))
                row.tag = index
                jumpTargets = bound
                rows.append(row)
                buttonRows.append(row)
            }
            let divider = ShellBackdropView(fill: ShellStyle.divider)
            rows.append(divider)
            sectionDivider = divider
            sectionLabels.append(divider)
            let newTerminal = NSTextField(labelWithString: L("Start a new terminal"))
            newTerminal.font = .systemFont(ofSize: 13, weight: .semibold)
            newTerminal.textColor = ShellStyle.primaryText
            rows.append(newTerminal)
            sectionLabels.append(newTerminal)
        }

        agentPicker.addItems(withTitles: LaunchAgent.allCases.map(\.title))
        agentPicker.menu?.addItem(.separator())
        agentPicker.menu?.addItem(withTitle: L("Agent settings…"), action: nil, keyEquivalent: "")
        agentPicker.selectItem(at: LaunchAgent.allCases.firstIndex(of: selectedAgent) ?? 0)
        agentPicker.target = self
        agentPicker.action = #selector(agentChanged)
        agentPicker.font = .systemFont(ofSize: 12)
        let agentRow = NSStackView(views: [Self.sectionLabel("Agent"), agentPicker])
        agentRow.spacing = 12
        rows.append(agentRow)
        sectionLabels.append(agentRow)

        saveDirectory.font = .systemFont(ofSize: 11)
        saveDirectory.controlSize = .small
        directoryError.font = .systemFont(ofSize: 10.5)
        directoryError.textColor = .systemRed
        let directoryGroup = NSStackView(views: [
            Self.sectionLabel(L("Working directory")), directory, saveDirectory, directoryError,
        ])
        directoryGroup.orientation = .vertical
        directoryGroup.alignment = .leading
        directoryGroup.spacing = 6
        rows.append(directoryGroup)

        let destinations = NSStackView()
        destinations.orientation = .vertical
        destinations.alignment = .leading
        destinations.spacing = 6
        for (index, label) in [L("Split in current tab"), L("New tab"), L("New window")].enumerated() {
            let button = RestoreSelectionButton(label, target: self,
                                                  action: #selector(destinationChanged(_:)))
            button.tag = index
            button.state = index == selectedDestination ? .on : .off
            destinationButtons.append(button)
            destinations.addArrangedSubview(button)
        }
        rows.append(destinations)
        contextHint.font = .systemFont(ofSize: 10.5)
        contextHint.textColor = ShellStyle.secondaryText
        rows.append(contextHint)
        launchButton.target = self
        launchButton.action = #selector(launch)
        rows.append(launchButton)
        buttonRows.append(launchButton)
        updateAgentPresentation()

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(12, after: agentRow)
        stack.setCustomSpacing(14, after: directoryGroup)
        stack.setCustomSpacing(12, after: destinations)
        stack.setCustomSpacing(8, after: contextHint)
        if !embedded {
            stack.setCustomSpacing(10, after: title)
            stack.setCustomSpacing(10, after: taskName)
        }
        for label in sectionLabels {
            if let index = rows.firstIndex(where: { $0 === label }), index > 0 {
                stack.setCustomSpacing(14, after: rows[index - 1])
            }
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        directory.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        directoryGroup.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        destinations.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        directoryError.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        var constraints = [
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            contextHint.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ]
        if !embedded {
            constraints += [root.widthAnchor.constraint(equalToConstant: 340),
                summary.widthAnchor.constraint(equalTo: stack.widthAnchor),
                title.widthAnchor.constraint(equalTo: stack.widthAnchor),
                taskName.widthAnchor.constraint(equalTo: stack.widthAnchor)]
        }
        for button in buttonRows {
            constraints.append(button.heightAnchor.constraint(
                equalToConstant: button is RestoreRowButton ? 40 : 30))
            constraints.append(button.widthAnchor.constraint(equalTo: stack.widthAnchor))
        }
        if let sectionDivider {
            constraints.append(sectionDivider.heightAnchor.constraint(equalToConstant: 1))
            constraints.append(sectionDivider.widthAnchor.constraint(equalTo: stack.widthAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        view = root
        updateDirectoryPresentation()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // A launch preview is not an edit form. Do not let AppKit select the
        // first text field automatically; embedded previews keep search focus.
        if !embedded { view.window?.makeFirstResponder(nil) }
    }

    private func updateDirectoryPresentation() {
        let path = WorkingDirectory.validated(directory.path)
        let changed = (path ?? directory.path) != (WorkingDirectory.validated(defaultDirectory) ?? defaultDirectory)
        saveDirectory.isHidden = !changed
        saveDirectory.isEnabled = path != nil
        if !changed || path == nil { saveDirectory.state = .off }
        directoryError.stringValue = ""
        directoryError.isHidden = true
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

    func makeBoundPane() -> PaneView? {
        guard let path = WorkingDirectory.validated(directory.path) else {
            directoryError.stringValue = L("Choose an existing folder.")
            directoryError.isHidden = false
            return nil
        }
        do {
            // Reload before editing so a fresh Agent handoff is not replaced by the preview snapshot.
            var launchTask = try AppState.shared.taskStore.load(at: fileURL)
            launchTask.workdir = path
            if !saveDirectory.isHidden && saveDirectory.state == .on {
                try AppState.shared.taskStore.update(at: fileURL, task: launchTask)
                defaultDirectory = path
                updateDirectoryPresentation()
                NotificationCenter.default.post(name: .lighttyTasksDidChange, object: nil)
            }
            directoryError.stringValue = ""
            directoryError.isHidden = true
            return PaneView.restoring(task: launchTask, fileURL: fileURL,
                initialInput: AgentLaunchPreference.initialInput(for: selectedAgent))
        } catch {
            directoryError.stringValue = error.localizedDescription
            directoryError.isHidden = false
            return nil
        }
    }

    @objc private func agentChanged() {
        let index = agentPicker.indexOfSelectedItem
        guard LaunchAgent.allCases.indices.contains(index) else {
            agentPicker.selectItem(at: LaunchAgent.allCases.firstIndex(of: selectedAgent) ?? 0)
            onDone?()
            controller?.showSettings(page: .general)
            return
        }
        selectedAgent = LaunchAgent.allCases[index]
        AgentLaunchPreference.select(selectedAgent)
        updateAgentPresentation()
    }

    private func updateAgentPresentation() {
        launchButton.title = selectedAgent.launchTitle
        guard selectedAgent != .terminal else {
            contextHint.stringValue = L("Open a terminal with this task, without starting an Agent.")
            return
        }
        let report = HookInstaller.report(for: selectedAgent == .claudeCode ? .claudeCode : .codex)
        if !report.isAgentPresent,
           AgentLaunchPreference.command(for: selectedAgent) == selectedAgent.defaultCommand {
            contextHint.stringValue = L("%@ was not detected. Install it or set a launch command in Agent settings.", selectedAgent.title)
        } else if report.state != .installed {
            contextHint.stringValue = L("Agent hooks share task context automatically. Configure them in Settings > General.")
        } else {
            contextHint.stringValue = L("Task context will be shared with the Agent automatically.")
        }
    }

    @objc private func destinationChanged(_ sender: NSButton) {
        selectedDestination = sender.tag
        for button in destinationButtons { button.state = button === sender ? .on : .off }
    }

    @objc private func launch() {
        switch selectedDestination {
        case 0: restoreInPane()
        case 1: restoreInTab()
        default: restoreInWindow()
        }
    }

    func performDefaultAction() {
        if !jumpTargets.isEmpty {
            let sender = NSButton()
            sender.tag = 0
            jumpToPane(sender)
        } else { launch() }
    }

    @objc private func restoreInPane() {
        guard let controller, let pane = makeBoundPane() else { return }
        controller.addPaneToActiveTab(pane)
        onDone?()
    }

    @objc private func restoreInTab() {
        guard let controller, let pane = makeBoundPane() else { return }
        controller.addTab(initialPane: pane)
        onDone?()
    }

    @objc private func restoreInWindow() {
        guard let pane = makeBoundPane() else { return }
        AppState.shared.newWindow(initialPane: pane)
        onDone?()
    }
}

/// 原生选择行为与辅助功能语义，选中背景统一跟随应用重点色。
final class RestoreSelectionButton: NSButton {
    private let checkbox: Bool
    init(_ label: String, checkbox: Bool = false, target: AnyObject?, action: Selector?) {
        self.checkbox = checkbox
        super.init(frame: .zero)
        setButtonType(checkbox ? .switch : .radio)
        title = label
        font = .systemFont(ofSize: 12)
        self.target = target
        self.action = action
        focusRingType = .exterior
        HoverCursor.installPointingHand(on: self)
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: .lighttyPreferencesDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func preferencesChanged() { needsDisplay = true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        let label = NSAttributedString(string: title, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: 12),
        ])
        return NSSize(width: ceil(label.size().width) + 23, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSRect(x: 0, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let fill = state == .on ? ShellStyle.accent : ShellStyle.pressedFill
        (NSColor(cgColor: fill.shellResolvedCGColor(for: effectiveAppearance)) ?? fill).setFill()
        (checkbox ? NSBezierPath(roundedRect: circle, xRadius: 4, yRadius: 4)
                  : NSBezierPath(ovalIn: circle)).fill()
        if state == .on {
            if checkbox {
                NSColor.white.setStroke()
                let check = NSBezierPath()
                check.move(to: NSPoint(x: 4, y: circle.midY))
                check.line(to: NSPoint(x: 7, y: circle.midY + (isFlipped ? 4 : -4)))
                check.line(to: NSPoint(x: 12, y: circle.midY + (isFlipped ? -4 : 4)))
                check.lineWidth = 2
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                check.stroke()
            } else {
                NSColor.white.setFill()
                NSBezierPath(ovalIn: circle.insetBy(dx: 5, dy: 5)).fill()
            }
        }
        let label = NSAttributedString(string: title, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: 12),
            .foregroundColor: ShellStyle.primaryText,
        ])
        label.draw(at: NSPoint(x: 23, y: (bounds.height - label.size().height) / 2))
    }
}

/// 主操作使用全局重点色，白色文字保持独立于系统原生按钮配色。
final class ShellAccentButton: NSButton {
    init() {
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .exterior
        HoverCursor.installPointingHand(on: self)
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: .lighttyPreferencesDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func preferencesChanged() { needsDisplay = true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor(cgColor: ShellStyle.accent.shellResolvedCGColor(for: effectiveAppearance))
            ?? ShellStyle.accent
        (isHighlighted ? accent.blended(withFraction: 0.12, of: .black) ?? accent : accent).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: ShellStyle.controlCornerRadius,
                     yRadius: ShellStyle.controlCornerRadius).fill()
        let label = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let size = label.size()
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                               y: (bounds.height - size.height) / 2))
    }
}

/// 已打开终端：左侧横向「标签页 › 终端」层级，右侧强调色导航动作；整行可点。
private final class RestoreRowButton: NSButton {
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { applyFill() } }

    init(terminalName: String, location: String?, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        HoverCursor.installPointingHand(on: self)
        self.target = target
        self.action = action
        isBordered = false
        focusRingType = .exterior
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = ShellStyle.controlCornerRadius

        title = ""
        let nameLabel = NSTextField(labelWithString: terminalName)
        nameLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        nameLabel.textColor = ShellStyle.primaryText
        let locationLabel = NSTextField(labelWithString: location ?? "")
        locationLabel.font = .systemFont(ofSize: 12, weight: .medium)
        locationLabel.textColor = ShellStyle.secondaryText
        locationLabel.isHidden = location == nil
        let chevron = NSTextField(labelWithString: "›")
        chevron.font = .systemFont(ofSize: 15, weight: .medium)
        chevron.textColor = ShellStyle.tertiaryText
        chevron.isHidden = location == nil
        chevron.setAccessibilityElement(false)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        let goLabel = NSTextField(labelWithString: L("Go ↗"))
        goLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        goLabel.textColor = ShellStyle.navigationAccent
        for label in [nameLabel, locationLabel, goLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setAccessibilityElement(false)
        }
        let identity = NSStackView(views: [locationLabel, chevron, nameLabel])
        identity.orientation = .horizontal
        identity.alignment = .centerY
        identity.spacing = 7
        for child in [identity, goLabel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            identity.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            identity.centerYAnchor.constraint(equalTo: centerYAnchor),
            identity.trailingAnchor.constraint(lessThanOrEqualTo: goLabel.leadingAnchor, constant: -16),
            locationLabel.widthAnchor.constraint(lessThanOrEqualTo: identity.widthAnchor, multiplier: 0.5),
            goLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            goLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        nameLabel.setContentCompressionResistancePriority(.init(251), for: .horizontal)
        locationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        goLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        goLabel.setContentHuggingPriority(.required, for: .horizontal)
        let destination = [location, terminalName].compactMap { $0 }.joined(separator: " › ")
        setAccessibilityLabel(L("Go to %@", destination))
        toolTip = destination
        applyFill()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

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
