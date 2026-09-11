import AppKit

/// 通用命名气泡：标题 + 输入框 + 确认，锚定在触发控件上。
/// 新建任务 / 重命名任务 / 重命名标签页共用，替代割裂的 NSAlert。
enum NameEditorPopover {
    private static var popover: NSPopover?

    static func present(
        from anchor: NSView,
        title: String,
        initial: String = "",
        confirmLabel: String = L("OK"),
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
        content.onCancel = { [weak pop] in pop?.close() }
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
        field.delegate = self
        (field.cell as? NSTextFieldCell)?.usesSingleLineMode = true

        // 原来这里是 ShellFieldBox 的一份手抄件，还抄歪了：圆角 8（别处 7）、
        // 高 26（别处 28），底色也是一次性刷上去的，明暗切换不跟。换成本尊。
        let fieldWrap = ShellFieldBox(field)

        // 无确认按钮：回车提交、Esc/点外部取消（多一步确认是冗余操作）
        let hint = NSTextField(labelWithString: L("Press Return to confirm"))
        hint.font = .systemFont(ofSize: 9.5)
        hint.textColor = ShellStyle.tertiaryText

        let stack = NSStackView(views: [title, fieldWrap, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            root.widthAnchor.constraint(equalToConstant: 240),
            fieldWrap.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = root
    }

    func focusField() {
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    var onCancel: (() -> Void)?

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            commit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }

    @objc private func commit() {
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { NSSound.beep(); return }
        onCommit?(name)
    }
}
