import AppKit

/// 通用命名气泡：标题 + 输入框 + 确认，锚定在触发控件上。
/// 新建任务 / 重命名任务 / 重命名工作区共用，替代割裂的 NSAlert。
enum NameEditorPopover {
    private static var popover: NSPopover?

    static func present(
        from anchor: NSView,
        title: String,
        initial: String = "",
        confirmLabel: String = "确认",
        onCommit: @escaping (String) -> Void
    ) {
        popover?.close()
        let content = NameEditorController(
            heading: title, initial: initial, confirmLabel: confirmLabel)
        let pop = NSPopover()
        pop.contentViewController = content
        pop.behavior = .transient
        content.onCommit = { [weak pop] name in
            pop?.close()
            onCommit(name)
        }
        popover = pop
        pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        content.focusField()
    }
}

private final class NameEditorController: NSViewController, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?

    private let heading: String
    private let initial: String
    private let confirmLabel: String
    private let field = NSTextField()

    init(heading: String, initial: String, confirmLabel: String) {
        self.heading = heading
        self.initial = initial
        self.confirmLabel = confirmLabel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()

        let title = NSTextField(labelWithString: heading)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = ShellStyle.primaryText

        field.stringValue = initial
        field.font = .systemFont(ofSize: 12)
        field.focusRingType = .none
        field.isBordered = false
        field.drawsBackground = false
        field.delegate = self
        field.wantsLayer = true
        (field.cell as? NSTextFieldCell)?.usesSingleLineMode = true

        let fieldWrap = NSView()
        fieldWrap.wantsLayer = true
        fieldWrap.layer?.cornerRadius = ShellStyle.controlCornerRadius
        fieldWrap.addSubview(field)
        field.translatesAutoresizingMaskIntoConstraints = false

        let confirm = ShellTextButton(
            confirmLabel, emphasis: .primary, target: self, action: #selector(commit))

        let stack = NSStackView(views: [title, fieldWrap, confirm])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            root.widthAnchor.constraint(equalToConstant: 240),
            fieldWrap.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fieldWrap.heightAnchor.constraint(equalToConstant: 26),
            field.leadingAnchor.constraint(equalTo: fieldWrap.leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: fieldWrap.trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: fieldWrap.centerYAnchor),
            confirm.heightAnchor.constraint(equalToConstant: 24),
        ])
        applyColors(to: fieldWrap)
        view = root
    }

    func focusField() {
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func applyColors(to wrap: NSView) {
        wrap.layer?.backgroundColor =
            ShellStyle.controlFill.shellResolvedCGColor(for: view.effectiveAppearance)
        field.textColor = ShellStyle.primaryText
    }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commit()
            return true
        }
        return false
    }

    @objc private func commit() {
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { NSSound.beep(); return }
        onCommit?(name)
    }
}
