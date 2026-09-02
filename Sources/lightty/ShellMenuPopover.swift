import AppKit

/// 自绘菜单气泡：替代原生 NSMenu（样式与壳层不符）。用于管理菜单：
/// 圆角卡片、整行 hover 提亮、ShellStyle 明暗动态色。
/// 支持：勾选态、尾注（如「运行中」）、分组标题、分隔线、危险项。
enum ShellMenuPopover {
    struct Item {
        enum Kind {
            case action(() -> Void)
            case header
            case separator
        }

        let kind: Kind
        var title: String = ""
        var checked = false
        var detail: String?
        var destructive = false

        static func action(
            _ title: String,
            checked: Bool = false,
            detail: String? = nil,
            destructive: Bool = false,
            handler: @escaping () -> Void
        ) -> Item {
            Item(
                kind: .action(handler), title: title, checked: checked,
                detail: detail, destructive: destructive)
        }

        static func header(_ title: String) -> Item {
            Item(kind: .header, title: title)
        }

        static var separator: Item { Item(kind: .separator) }
    }

    private static var popover: NSPopover?

    static func present(from anchor: NSView, items: [Item]) {
        popover?.close()
        let content = MenuController(items: items)
        let pop = NSPopover()
        pop.contentViewController = content
        pop.behavior = .transient
        content.onDone = { [weak pop] action in
            pop?.close()
            // 先关再执行：动作可能弹下一个气泡（如重命名输入框）
            DispatchQueue.main.async { action?() }
        }
        popover = pop
        pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }
}

private final class MenuController: NSViewController {
    var onDone: (((() -> Void)?) -> Void)?

    private let items: [ShellMenuPopover.Item]

    init(items: [ShellMenuPopover.Item]) {
        self.items = items
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        var rows: [NSView] = []
        var buttons: [MenuRowButton] = []

        for item in items {
            switch item.kind {
            case .separator:
                let line = ShellBackdropView(fill: ShellStyle.divider)
                line.translatesAutoresizingMaskIntoConstraints = false
                line.heightAnchor.constraint(equalToConstant: 1).isActive = true
                rows.append(line)
            case .header:
                let label = NSTextField(labelWithString: item.title)
                label.font = .systemFont(ofSize: 10, weight: .medium)
                label.textColor = ShellStyle.tertiaryText
                rows.append(label)
            case .action(let handler):
                let row = MenuRowButton(item: item)
                row.onTap = { [weak self] in self?.onDone?(handler) }
                rows.append(row)
                buttons.append(row)
            }
        }

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        var constraints = [
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            root.widthAnchor.constraint(equalToConstant: 224),
        ]
        for row in rows {
            constraints.append(row.widthAnchor.constraint(equalTo: stack.widthAnchor))
        }
        for button in buttons {
            constraints.append(button.heightAnchor.constraint(equalToConstant: 27))
        }
        // 分组标题左对齐带内缩
        for case let label as NSTextField in rows {
            constraints.append(
                label.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 9))
        }
        NSLayoutConstraint.activate(constraints)
        view = root
    }
}

/// 菜单行：勾选区 + 标题 + 尾注，整行 hover 提亮。
private final class MenuRowButton: NSView {
    var onTap: (() -> Void)?

    private let item: ShellMenuPopover.Item
    private let check = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { applyFill() } }

    init(item: ShellMenuPopover.Item) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = ShellStyle.controlCornerRadius

        check.image = NSImage(
            systemSymbolName: "checkmark", accessibilityDescription: nil)
        check.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 9, weight: .semibold)
        check.isHidden = !item.checked

        titleLabel.stringValue = item.title
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.lineBreakMode = .byTruncatingTail

        detailLabel.stringValue = item.detail ?? ""
        detailLabel.font = .systemFont(ofSize: 10.5)

        for v in [check, titleLabel, detailLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 12),

            titleLabel.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 5),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: detailLabel.leadingAnchor, constant: -8),

            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyColors() {
        titleLabel.textColor = item.destructive ? .systemRed : ShellStyle.primaryText
        detailLabel.textColor = ShellStyle.tertiaryText
        check.contentTintColor = ShellStyle.primaryText
        applyFill()
    }

    private func applyFill() {
        let fill: NSColor = hovered ? ShellStyle.selectionFill : .clear
        layer?.backgroundColor = fill.shellResolvedCGColor(for: effectiveAppearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
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
    override func mouseDown(with event: NSEvent) { onTap?() }
}
