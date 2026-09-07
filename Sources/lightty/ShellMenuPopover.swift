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
        /// 行首色点（重点色菜单用）
        var swatch: NSColor?

        static func action(
            _ title: String,
            checked: Bool = false,
            detail: String? = nil,
            destructive: Bool = false,
            swatch: NSColor? = nil,
            handler: @escaping () -> Void
        ) -> Item {
            Item(
                kind: .action(handler), title: title, checked: checked,
                detail: detail, destructive: destructive, swatch: swatch)
        }

        static func header(_ title: String) -> Item {
            Item(kind: .header, title: title)
        }

        static var separator: Item { Item(kind: .separator) }
    }

    private static var window: ShellMenuWindow?

    /// 贴锚点下方、右缘对齐的自绘卡片（ChatGPT 桌面版式，无气泡小三角）。
    /// 不用 NSPopover：它的三角是固有外观关不掉。空间不够时翻到锚点上方。
    static func present(from anchor: NSView, items: [Item]) {
        dismiss()
        guard let parent = anchor.window else { return }
        let content = MenuController(items: items)
        let menu = ShellMenuWindow(content: content)
        content.onDone = { action in
            dismiss()
            // 先关再执行：动作可能弹下一个气泡（如重命名输入框）
            DispatchQueue.main.async { action?() }
        }
        menu.onDismiss = { dismiss() }

        let size = menu.contentView?.fittingSize ?? NSSize(width: 224, height: 100)
        let anchorRect = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let screen = (parent.screen ?? NSScreen.main)?.visibleFrame ?? anchorRect
        var origin = NSPoint(x: anchorRect.maxX - size.width, y: anchorRect.minY - 6 - size.height)
        if origin.y < screen.minY { origin.y = anchorRect.maxY + 6 }  // 下方放不下 → 上方
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        menu.setFrame(NSRect(origin: origin, size: size), display: false)

        window = menu
        parent.addChildWindow(menu, ordered: .above)
        menu.makeKeyAndOrderFront(nil)
    }

    static func dismiss() {
        guard let menu = window else { return }
        window = nil
        let parent = menu.parent
        parent?.removeChildWindow(menu)
        menu.orderOut(nil)
        parent?.makeKey()
    }
}

/// 菜单卡片窗口：无边框、透明底，内容是圆角磨砂卡（材质 + 细描边 + 系统投影）。
/// 成为 key window 以驱动行 hover；失去 key（点了别处）或 Esc 即关闭。
private final class ShellMenuWindow: NSWindow {
    var onDismiss: (() -> Void)?
    /// 只为持有：不能设成 contentViewController，那会把它的 view 抢去当窗口根视图
    private let controller: NSViewController

    init(content: NSViewController) {
        controller = content
        super.init(
            contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow
        isMovableByWindowBackground = false

        let card = NSVisualEffectView()
        // 系统菜单同款材质：比 popover 更亮更透。磨砂由窗口服务器合成，圆角必须走
        // maskImage——layer.cornerRadius 只裁得到自己的子图层，裁不到磨砂，四角会露方。
        card.material = .menu
        card.blendingMode = .behindWindow
        card.state = .active
        card.maskImage = Self.roundedMask(radius: 12)
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1
        card.layer?.borderColor = ShellStyle.divider.shellResolvedCGColor(for: card.effectiveAppearance)
        // 磨砂之上再罩一层高透的抬升面色：系统材质自带的灰调偏脏，ChatGPT 那种
        // 「亮白玻璃」是浅色下近白、深色下近黑的半透明罩 + 底下的模糊。
        let tint = MenuTintOverlay()
        tint.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(tint)
        content.view.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content.view)
        NSLayoutConstraint.activate([
            tint.topAnchor.constraint(equalTo: card.topAnchor),
            tint.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            tint.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.view.topAnchor.constraint(equalTo: card.topAnchor),
            content.view.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            content.view.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        contentView = card
    }

    /// 可拉伸的圆角遮罩：四角固定、中间平铺
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        onDismiss?()
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
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

/// 菜单行：（色点 +）标题 + 尾注 + 尾部勾选，整行 hover 提亮（ChatGPT 桌面版式）。
private final class MenuRowButton: NSView {
    var onTap: (() -> Void)?
    private let swatch = NSView()

    private let item: ShellMenuPopover.Item
    private let check = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { applyFill() } }

    init(item: ShellMenuPopover.Item) {
        self.item = item
        super.init(frame: .zero)
        HoverCursor.installPointingHand(on: self)
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

        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 5
        swatch.isHidden = item.swatch == nil

        for v in [swatch, check, titleLabel, detailLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            swatch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            swatch.centerYAnchor.constraint(equalTo: centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 10),
            swatch.heightAnchor.constraint(equalToConstant: 10),

            titleLabel.leadingAnchor.constraint(
                equalTo: item.swatch == nil ? leadingAnchor : swatch.trailingAnchor,
                constant: item.swatch == nil ? 10 : 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: detailLabel.leadingAnchor, constant: -8),

            // 尾注与勾在行尾；未勾选时勾不占位
            detailLabel.trailingAnchor.constraint(
                equalTo: check.leadingAnchor, constant: item.checked ? -6 : 0),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: item.checked ? 12 : 0),
        ])
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyColors() {
        titleLabel.textColor = item.destructive ? .systemRed : ShellStyle.primaryText
        detailLabel.textColor = ShellStyle.tertiaryText
        check.contentTintColor = ShellStyle.primaryText
        if let color = item.swatch {
            swatch.layer?.backgroundColor = color.shellResolvedCGColor(for: effectiveAppearance)
            // 浅色点在浅底上要有一圈边才看得见
            swatch.layer?.borderWidth = 1
            swatch.layer?.borderColor = ShellStyle.divider.shellResolvedCGColor(for: effectiveAppearance)
        }
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

/// 菜单卡的半透明罩：抬升面色 × 高透明度，随明暗重解析。
private final class MenuTintOverlay: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        applyColor()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColor()
    }

    private func applyColor() {
        layer?.backgroundColor = ShellStyle.raisedSurface.withAlphaComponent(0.72)
            .shellResolvedCGColor(for: effectiveAppearance)
    }
}
