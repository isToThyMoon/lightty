import AppKit
import LighttyCore

/// 一次启动要决定的事只有四件：**挂不挂任务、用哪个 Agent、在哪个目录、开到哪里**。
///
/// 三个入口以前是三套界面，各自砍掉了不同的部分：Sessions 新建会话选不了目录，
/// Handoff 新建任务只写文件不启动、也没处写正文。它们其实是同一件事的三组初值，
/// 所以现在共用 `LaunchComposerController`，只在这里分岔。
enum LaunchSubject {
    /// 只开一段 Agent 会话，不挂任务（Sessions 模式的「新建」）。
    case session
    /// 已有任务：显示摘要与已打开的终端（任务的「开始处理」）。
    case task(fileURL: URL, task: TaskFile)
    /// 新建任务：名字与初始正文在浮层里填，可以建完就启动，也可以只建不启动。
    case newTask
}

/// 启动浮层：把上面四件事摆在一屏里，点启动才创建终端。
enum LaunchComposer {
    private static var popover: NSPopover?
    static func dismiss() { popover?.close(); popover = nil }

    static func begin(
        _ subject: LaunchSubject,
        from anchor: NSView,
        in controller: TerminalWindowController,
        preferredEdge: NSRectEdge = .maxX
    ) {
        popover?.close()
        let content = LaunchComposerController(subject: resolved(subject), controller: controller)
        let pop = NSPopover()
        pop.contentViewController = content
        pop.behavior = .transient
        content.onDone = { [weak pop] in pop?.close() }
        content.directory.onPickerVisibilityChange = { [weak pop] choosing in
            pop?.behavior = choosing ? .applicationDefined : .transient
        }
        popover = pop
        pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: preferredEdge)
        content.focusFirstField()
    }

    /// 打开时重读磁盘：调用方传来的 task 是列表缓存的快照，agent 直接写文件不触发
    /// 内部通知，快照可能停在写入前（正文为空 → 摘要空白）。浮层是「看一眼现状」的
    /// 动作，以磁盘为准；读不了再用快照兜底。
    private static func resolved(_ subject: LaunchSubject) -> LaunchSubject {
        guard case .task(let fileURL, let task) = subject else { return subject }
        return .task(fileURL: fileURL, task: (try? AppState.shared.taskStore.load(at: fileURL)) ?? task)
    }

    /// 摘要 = 正文的 Next steps 一节。
    ///
    /// 只认这一个节头，是因为下面这段**不是只识别**：它把认出来的节拼起来再截
    /// 14 行。多认一个节头等于让最重要的那节被前面的节挤出上限——认得越多，
    /// 摘要越可能停在「当前状态」上，看不到下一步。
    ///
    /// 实测（2026-09-09，`~/.lightty/tasks/` 里 8 个真实任务文件）：没有一个以
    /// `## Next steps` 开头，6 个开头是 Current state / 当前状态；但其中 6 个在
    /// 正文靠后有 `## Next steps`。收窄之后这 6 个的摘要变成下一步本身；余下 2 个
    /// （一个无节头、一个用 `## 仓库与环境`）本来就走下面「显示正文开头」的兜底，
    /// 不受影响。所以是 6 个变好、2 个不变，没有变差的。
    ///
    /// 中文 `## 下一步` 留着：那是 2026-08-30 协议迁英文前的旧格式，既有文件还在用。
    ///
    /// 收窄的代价说准一点：**对上面那 8 个文件**没有变差的。有一种形状会变差——
    /// 有 `## Current state` 之类、没有 `## Next steps`、且那一节不在正文前 12 行内：
    /// 旧代码摘要是当前状态本身，新代码退回显示前 12 行的无关前言。样本里没有这种
    /// 文件，但它不是臆想。
    ///
    /// 节头匹配用 `hasPrefix` 而不是 `==`，是为了容忍 `## Next steps（2026-09-04）`
    /// 这种带括号补充的写法（用户的既有文件里就有）；大小写不敏感是因为收窄后这里
    /// 成了单点，写成 `## Next Steps` 就会整段掉进兜底，而旧代码有 6 个候选还能互相兜。
    static func summarize(_ body: String) -> String {
        let interesting = ["## next steps", "## 下一步"]
        var lines: [String] = []
        var keeping = false
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                let lowered = line.lowercased()
                keeping = interesting.contains(where: { lowered.hasPrefix($0) })
            }
            if keeping { lines.append(String(line)) }
            if lines.count > 14 { break }
        }
        // 「认出了节头、节里却什么都没有」产出的不是空串，是那行标题本身——直接返回
        // 会让气泡里只显示 `## Next steps` 五个字。节头之外没有内容就当没认出来。
        let hasContent = lines.contains {
            !$0.hasPrefix("## ") && !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let result = hasContent
            ? lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        if !result.isEmpty { return result }
        // 兜底：agent 写的节头不在协议集合里时，展示正文开头——有内容
        // 就不该显示「暂无摘要」
        let head = body.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(12)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return head.isEmpty ? L("No handoff summary yet") : head
    }

    /// 新终端默认落在当前终端所在的目录，没有就用家目录。
    /// 三个入口都用这一个默认值，除非任务自己记了目录。
    static func defaultDirectory(in controller: TerminalWindowController?) -> String {
        controller?.activePane?.terminal.currentWorkingDirectory ?? NSHomeDirectory()
    }
}

/// 启动浮层的内容。四段固定顺序：主体 → Agent → 工作目录 → 去处 → 启动。
/// 哪几段出现由 `subject` 决定，摆法与间距三种情况完全一致。
final class LaunchComposerController: NSViewController, NSTextFieldDelegate {
    var onDone: (() -> Void)?

    let subject: LaunchSubject
    private let embedded: Bool
    private weak var controller: TerminalWindowController?
    private var jumpTargets: [(controller: TerminalWindowController, pane: PaneView)] = []
    private var selectedAgent = AgentLaunchPreference.selected()
    let agentPicker: ShellDropdown
    private let launchButton = ShellAccentButton()
    private var createOnlyButton: ShellTextButton?
    private var destinationButtons: [NSButton] = []
    private var selectedDestination = 1
    private let contextHint = NSTextField(wrappingLabelWithString: "")
    private weak var contentStack: NSStackView?
    private static let panelWidth: CGFloat = 340
    private static let verticalInset: CGFloat = 14
    private static let horizontalInset: CGFloat = 16

    /// 仅新建任务时出现。
    let nameField = NSTextField()
    let bodyEditor = ShellTextArea()
    private let nameError = NSTextField(wrappingLabelWithString: "")

    let directory: WorkingDirectoryEditor
    private var defaultDirectory: String
    let saveDirectory = RestoreSelectionButton(L("Set as default directory on launch"), checkbox: true, target: nil, action: nil)
    private let directoryError = NSTextField(wrappingLabelWithString: "")

    private var taskFileURL: URL? {
        if case .task(let fileURL, _) = subject { return fileURL }
        return nil
    }
    /// 启动之后终端会挂一个任务吗？已有任务和新建任务都算，纯会话不算。
    private var carriesTask: Bool {
        if case .session = subject { return false }
        return true
    }

    init(subject: LaunchSubject, controller: TerminalWindowController?, embedded: Bool = false) {
        self.embedded = embedded
        self.subject = subject
        switch subject {
        case .task(_, let task): defaultDirectory = task.workdir
        case .session, .newTask: defaultDirectory = LaunchComposer.defaultDirectory(in: controller)
        }
        directory = WorkingDirectoryEditor(path: defaultDirectory)
        agentPicker = ShellDropdown(
            options: LaunchAgent.allCases.map { .init(id: $0.rawValue, title: $0.title) },
            selectedID: selectedAgent.rawValue)
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
        directory.onPathChange = { [weak self] in self?.updateDirectoryPresentation() }
        directory.onCommit = { [weak self] in self?.launch() }
        agentPicker.onChange = { [weak self] id in self?.agentChanged(to: id) }
        agentPicker.trailingAction = (L("Agent settings…"), { [weak self] in
            self?.onDone?()
            self?.controller?.showSettings(page: .general)
        })
        agentPicker.setAccessibilityLabel("Agent")
    }

    required init?(coder: NSCoder) { fatalError() }

    private var headingText: String {
        switch subject {
        case .session: return L("New session")
        case .task: return L("Start working")
        case .newTask: return L("New task")
        }
    }

    override func loadView() {
        let root = NSView()

        let heading = NSTextField(labelWithString: headingText)
        heading.font = .systemFont(ofSize: 20, weight: .bold)
        heading.textColor = ShellStyle.primaryText

        var rows: [NSView] = embedded ? [] : [heading]
        var fullWidth: [NSView] = embedded ? [] : [heading]
        var buttonRows: [NSButton] = []
        var sectionLabels: [NSView] = []
        var sectionDivider: NSView?

        switch subject {
        case .session:
            break
        case .task(let fileURL, let task):
            if !embedded {
                let taskName = NSTextField(wrappingLabelWithString: task.name)
                taskName.font = .systemFont(ofSize: 13, weight: .semibold)
                taskName.textColor = ShellStyle.primaryText
                taskName.isSelectable = false

                let summary = NSTextField(wrappingLabelWithString: LaunchComposer.summarize(task.body))
                summary.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
                summary.textColor = ShellStyle.secondaryText
                summary.maximumNumberOfLines = 10
                // wrappingLabel 默认可选择，点击会创建不受 maximumNumberOfLines 限制的
                // field editor，完整正文随之盖住下面的启动控件。此处只展示静态摘要。
                summary.isSelectable = false
                summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                rows += [taskName, summary]
                fullWidth += [taskName, summary]
            }
            rows += openedRows(for: fileURL, sectionLabels: &sectionLabels,
                               buttonRows: &buttonRows, divider: &sectionDivider)
        case .newTask:
            rows.append(newTaskFields())
            fullWidth.append(rows[rows.count - 1])
        }

        let agentRow = NSStackView(views: [Self.sectionLabel("Agent"), agentPicker])
        agentRow.spacing = 12
        rows.append(agentRow)
        sectionLabels.append(agentRow)

        saveDirectory.font = .systemFont(ofSize: 11)
        saveDirectory.controlSize = .small
        saveDirectory.isHidden = taskFileURL == nil
        directoryError.font = .systemFont(ofSize: 10.5)
        directoryError.textColor = .systemRed
        let directoryGroup = NSStackView(views: [
            Self.sectionLabel(L("Working directory")), directory, saveDirectory, directoryError,
        ])
        directoryGroup.orientation = .vertical
        directoryGroup.alignment = .leading
        directoryGroup.spacing = 6
        rows.append(directoryGroup)
        fullWidth += [directoryGroup, directory, directoryError]

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
        fullWidth.append(destinations)

        contextHint.font = .systemFont(ofSize: 10.5)
        contextHint.textColor = ShellStyle.secondaryText
        rows.append(contextHint)
        fullWidth.append(contextHint)

        launchButton.target = self
        launchButton.action = #selector(launch)
        rows.append(launchButton)
        buttonRows.append(launchButton)

        if case .newTask = subject {
            // 「只建一笔、现在不开终端」仍然要能做到——它是原来新建任务的全部行为。
            let onlyCreate = ShellTextButton(L("Create only"), target: self, action: #selector(createOnly))
            createOnlyButton = onlyCreate
            rows.append(onlyCreate)
            buttonRows.append(onlyCreate)
        }
        updateAgentPresentation()

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(12, after: agentRow)
        stack.setCustomSpacing(14, after: directoryGroup)
        stack.setCustomSpacing(12, after: destinations)
        stack.setCustomSpacing(8, after: contextHint)
        if !embedded { stack.setCustomSpacing(10, after: heading) }
        if case .task = subject, !embedded, rows.count > 2 {
            stack.setCustomSpacing(10, after: rows[1])
        }
        for label in sectionLabels {
            if let index = rows.firstIndex(where: { $0 === label }), index > 0 {
                stack.setCustomSpacing(14, after: rows[index - 1])
            }
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        contentStack = stack
        var constraints = [
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.verticalInset),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.horizontalInset),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.horizontalInset),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.verticalInset),
        ]
        if !embedded {
            constraints.append(root.widthAnchor.constraint(equalToConstant: Self.panelWidth))
        }
        for view in fullWidth {
            constraints.append(view.widthAnchor.constraint(equalTo: stack.widthAnchor))
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

    /// 已打开：每个绑定该任务的运行中 pane 一行，点击直接跳转。
    private func openedRows(for fileURL: URL, sectionLabels: inout [NSView],
                            buttonRows: inout [NSButton], divider: inout NSView?) -> [NSView] {
        let bound = AppState.shared.runningPanes().filter {
            $0.pane.taskFileURL?.standardizedFileURL == fileURL.standardizedFileURL
        }
        guard !bound.isEmpty else { return [] }
        var rows: [NSView] = []
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
            rows.append(row)
            buttonRows.append(row)
        }
        jumpTargets = bound
        let line = ShellBackdropView(fill: ShellStyle.divider)
        rows.append(line)
        divider = line
        sectionLabels.append(line)
        let newTerminal = NSTextField(labelWithString: L("Start a new terminal"))
        newTerminal.font = .systemFont(ofSize: 13, weight: .semibold)
        newTerminal.textColor = ShellStyle.primaryText
        rows.append(newTerminal)
        sectionLabels.append(newTerminal)
        return rows
    }

    /// 新建任务的名字与初始正文。正文可留空——它只是 Agent 启动时读到的第一段交接内容。
    private func newTaskFields() -> NSView {
        nameField.placeholderString = L("Task name")
        nameField.setAccessibilityLabel(L("Task name"))
        nameField.delegate = self
        nameField.font = .systemFont(ofSize: 12.5)
        nameError.font = .systemFont(ofSize: 10.5)
        nameError.textColor = .systemRed
        nameError.isHidden = true

        bodyEditor.placeholder = L("Goal, background, next steps. The Agent reads this on launch.")
        bodyEditor.textView.setAccessibilityLabel(L("Initial handoff notes"))

        let nameBox = ShellFieldBox(nameField)
        let group = NSStackView(views: [
            nameBox, nameError,
            Self.sectionLabel(L("Initial handoff notes")), bodyEditor,
        ])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 6
        group.setCustomSpacing(12, after: nameError)
        NSLayoutConstraint.activate([
            nameBox.widthAnchor.constraint(equalTo: group.widthAnchor),
            nameError.widthAnchor.constraint(equalTo: group.widthAnchor),
            // 高度不写死：正文框自己按内容长，长到两倍为止（见 ShellTextArea）。
            bodyEditor.widthAnchor.constraint(equalTo: group.widthAnchor),
        ])
        return group
    }

    func focusFirstField() {
        guard case .newTask = subject else { return }
        view.window?.makeFirstResponder(nameField)
    }

    /// 正文框会跟着内容长高、也会缩回去，气泡得跟着改大小。
    ///
    /// `NSPopover` 只在展示时量一次内容：长高时约束把窗口顶大了，看着「能长」；
    /// 缩回去时窗口尺寸不动，多出来的高度被竖栈分摊成各段之间的空白——正文框缩了，
    /// 气泡还是那么高，中间空一大块。
    ///
    /// 量的是**里面那个竖栈**，不是根视图：根视图被气泡（或窗口）按住了尺寸，
    /// 它的 `fittingSize` 会跟着那个尺寸走，只涨不落。实测同一时刻根视图报 564、
    /// 竖栈报 471——后者才是内容真正要的高度。
    override func viewDidLayout() {
        super.viewDidLayout()
        guard !embedded, let contentStack else { return }
        let height = contentStack.fittingSize.height + Self.verticalInset * 2
        guard height > 0, abs(preferredContentSize.height - height) > 0.5 else { return }
        preferredContentSize = NSSize(width: Self.panelWidth, height: height)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // A launch preview is not an edit form. Do not let AppKit select the
        // first text field automatically; embedded previews keep search focus.
        if case .newTask = subject { return }
        if !embedded { view.window?.makeFirstResponder(nil) }
    }

    private func updateDirectoryPresentation() {
        let path = WorkingDirectory.validated(directory.path)
        let changed = (path ?? directory.path) != (WorkingDirectory.validated(defaultDirectory) ?? defaultDirectory)
        saveDirectory.isHidden = taskFileURL == nil || !changed
        saveDirectory.isEnabled = path != nil
        if saveDirectory.isHidden || path == nil { saveDirectory.state = .off }
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

    /// 走到这里说明用户已经点了启动。三种情况在这里合流：会话直接建终端，
    /// 已有任务重读后按选中的目录启动，新建任务先落盘再按同一条路启动。
    func makePane() -> PaneView? {
        guard let path = WorkingDirectory.validated(directory.path) else {
            show(directoryError, L("Choose an existing folder."))
            return nil
        }
        directoryError.isHidden = true
        switch subject {
        case .session:
            // 删除某段会话的过程中不开同一家的新会话：那条路会去问「谁占着这个文件」，
            // 中途冒出一个新进程只会让它更难判断。窗口很短，说一句就够。
            if selectedAgent != .terminal,
               SessionDeletion.busyAgents.contains(selectedAgent == .codex ? .codex : .claude) {
                show(directoryError, L("A session is being deleted. Try again in a moment."))
                return nil
            }
            return PaneView(surfaceConfiguration: SessionResumeFlow.newSessionConfiguration(
                agent: selectedAgent, workingDirectory: path))
        case .task(let fileURL, _):
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
                return PaneView.restoring(task: launchTask, fileURL: fileURL,
                                          command: .start(selectedAgent))
            } catch {
                show(directoryError, error.localizedDescription)
                return nil
            }
        case .newTask:
            guard let created = createTask(at: path) else { return nil }
            return PaneView.restoring(task: created.task, fileURL: created.fileURL,
                                      command: .start(selectedAgent))
        }
    }

    private func createTask(at path: String) -> (fileURL: URL, task: TaskFile)? {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            show(nameError, L("Enter a task name."))
            return nil
        }
        nameError.isHidden = true
        do {
            let created = try AppState.shared.taskStore.create(
                name: name, workdir: path, body: bodyEditor.string)
            NotificationCenter.default.post(name: .lighttyTasksDidChange, object: nil)
            return created
        } catch {
            show(nameError, error.localizedDescription)
            return nil
        }
    }

    private func show(_ label: NSTextField, _ message: String) {
        label.stringValue = message
        label.isHidden = false
    }

    @objc func createOnly() {
        guard case .newTask = subject else { return }
        guard let path = WorkingDirectory.validated(directory.path) else {
            show(directoryError, L("Choose an existing folder."))
            return
        }
        directoryError.isHidden = true
        guard createTask(at: path) != nil else { return }
        onDone?()
    }

    private func agentChanged(to id: String) {
        guard let agent = LaunchAgent(rawValue: id) else { return }
        selectedAgent = agent
        AgentLaunchPreference.select(agent)
        updateAgentPresentation()
    }

    private func updateAgentPresentation() {
        if case .newTask = subject {
            launchButton.title = selectedAgent == .terminal
                ? L("Create and open terminal")
                : L("Create and launch %@", selectedAgent.title)
        } else {
            launchButton.title = selectedAgent.launchTitle
        }
        guard selectedAgent != .terminal else {
            contextHint.stringValue = carriesTask
                ? L("Open a terminal with this task, without starting an Agent.")
                : L("Open a terminal without starting an Agent.")
            contextHint.isHidden = false
            return
        }
        let report = HookInstaller.report(for: selectedAgent == .claudeCode ? .claudeCode : .codex)
        if !report.isAgentPresent {
            contextHint.stringValue = L("%@ was not detected. Install it, then check the launch options in Agent settings.", selectedAgent.title)
        } else if !carriesTask {
            // 没有任务就没有「任务上下文会传进去」这回事，一切正常时不必说话。
            contextHint.stringValue = ""
        } else if report.state != .installed {
            contextHint.stringValue = L("Agent hooks share task context automatically. Configure them in Settings > General.")
        } else {
            contextHint.stringValue = L("Task context will be shared with the Agent automatically.")
        }
        contextHint.isHidden = contextHint.stringValue.isEmpty
    }

    @objc private func destinationChanged(_ sender: NSButton) {
        selectedDestination = sender.tag
        for button in destinationButtons { button.state = button === sender ? .on : .off }
    }

    /// 回车提交只在编辑文本时生效，走字段的 doCommandBy；不给按钮挂 keyEquivalent，
    /// 那是窗口级快捷键，会抢在 surface 之前吃掉用户配的 Ghostty 绑定。
    /// 正文框不接这一支：那里回车就是换行。
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        launch()
        return true
    }

    @objc func launch() {
        switch selectedDestination {
        case 0: launchInPane()
        case 1: launchInTab()
        default: launchInWindow()
        }
    }

    func performDefaultAction() {
        if !jumpTargets.isEmpty {
            let sender = NSButton()
            sender.tag = 0
            jumpToPane(sender)
        } else { launch() }
    }

    // 先确认有地方放，再 makePane()：新建任务那一支在 makePane() 里就落盘了，
    // 顺序反过来会留下一个「文件建好了、终端没开」的半截结果。
    @objc private func launchInPane() {
        guard let controller else { return }
        guard let pane = makePane() else { return }
        controller.addPaneToActiveTab(pane)
        onDone?()
    }

    @objc private func launchInTab() {
        guard let controller else { return }
        guard let pane = makePane() else { return }
        controller.addTab(initialPane: pane)
        onDone?()
    }

    @objc private func launchInWindow() {
        guard let pane = makePane() else { return }
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
