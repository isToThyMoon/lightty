import AppKit

enum WorkingDirectory {
    static func validated(_ input: String) -> String? {
        let path = (input.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard path.hasPrefix("/"), !path.contains("\n"), !path.contains("\r") else { return nil }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

final class WorkingDirectoryEditor: NSStackView, NSTextFieldDelegate {
    let field = NSTextField()
    var onPickerVisibilityChange: ((Bool) -> Void)?
    var onPathChange: (() -> Void)?
    /// 在目录框里按回车的动作。由字段的 doCommandBy 分发，不挂窗口级 keyEquivalent。
    var onCommit: (() -> Void)?
    var path: String {
        get { field.stringValue }
        set { field.stringValue = newValue; onPathChange?() }
    }

    init(path: String) {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        field.stringValue = path
        field.delegate = self
        field.font = .systemFont(ofSize: 11)
        field.focusRingType = .none
        if let cell = field.cell as? NSTextFieldCell {
            cell.usesSingleLineMode = true
            cell.wraps = false
            cell.isScrollable = true
            cell.lineBreakMode = .byTruncatingHead
        }
        field.setAccessibilityLabel(L("Working directory"))
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let choose = ShellIconButton(symbol: "folder", accessibilityLabel: L("Choose folder…"), target: self, action: #selector(chooseFolder))
        addArrangedSubview(field)
        addArrangedSubview(choose)
        choose.widthAnchor.constraint(equalToConstant: 28).isActive = true
        choose.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func controlTextDidChange(_ notification: Notification) { onPathChange?() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)), let onCommit else { return false }
        onCommit()
        return true
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Choose folder…")
        if let valid = WorkingDirectory.validated(path) { panel.directoryURL = URL(fileURLWithPath: valid) }
        onPickerVisibilityChange?(true)
        defer { onPickerVisibilityChange?(false) }
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}

enum NewHandoffPopover {
    private static var popover: NSPopover?
    static func present(from anchor: NSView) {
        popover?.close()
        let content = NewHandoffController()
        let pop = NSPopover()
        pop.contentViewController = content
        pop.behavior = .transient
        content.onDone = { [weak pop] in pop?.close() }
        content.directory.onPickerVisibilityChange = { [weak pop] choosing in
            pop?.behavior = choosing ? .applicationDefined : .transient
        }
        popover = pop
        pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        content.view.window?.makeFirstResponder(content.nameField)
    }
}

final class NewHandoffController: NSViewController, NSTextFieldDelegate {
    let nameField = NSTextField()
    let directory = WorkingDirectoryEditor(path: FileManager.default.homeDirectoryForCurrentUser.path)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    var onDone: (() -> Void)?

    override func loadView() {
        let root = NSView()
        let heading = NSTextField(labelWithString: L("New task"))
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        nameField.placeholderString = L("Task name")
        nameField.setAccessibilityLabel(L("Task name"))
        nameField.delegate = self
        directory.onCommit = { [weak self] in self?.commit() }
        nameField.focusRingType = .none
        if let cell = nameField.cell as? NSTextFieldCell {
            cell.usesSingleLineMode = true
            cell.wraps = false
            cell.isScrollable = true
        }
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        let create = ShellAccentButton()
        create.title = L("Create")
        create.target = self
        create.action = #selector(commit)
        let actions = NSView()
        create.translatesAutoresizingMaskIntoConstraints = false
        actions.addSubview(create)
        let stack = NSStackView(views: [heading, nameField, NSTextField(labelWithString: L("Working directory")), directory, errorLabel, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 340),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            nameField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            directory.widthAnchor.constraint(equalTo: stack.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.heightAnchor.constraint(equalToConstant: 32),
            create.trailingAnchor.constraint(equalTo: actions.trailingAnchor),
            create.topAnchor.constraint(equalTo: actions.topAnchor),
            create.bottomAnchor.constraint(equalTo: actions.bottomAnchor),
            create.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
        view = root
    }

    /// 回车提交只在编辑文本时生效，走字段的 doCommandBy；不给按钮挂 keyEquivalent，
    /// 那是窗口级快捷键，会抢在 surface 之前吃掉用户配的 Ghostty 绑定。
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        commit()
        return true
    }

    @objc func commit() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { errorLabel.stringValue = L("Enter a task name."); return }
        guard let path = WorkingDirectory.validated(directory.path) else {
            errorLabel.stringValue = L("Choose an existing folder."); return
        }
        do {
            try AppState.shared.taskStore.create(name: name, workdir: path)
            NotificationCenter.default.post(name: .lighttyTasksDidChange, object: nil)
            onDone?()
        } catch { errorLabel.stringValue = error.localizedDescription }
    }
}
