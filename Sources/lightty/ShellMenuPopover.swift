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
        var subtitle: String?
        var destructive = false
        /// 行首色点（重点色菜单用）
        var swatch: NSColor?

        static func action(
            _ title: String,
            checked: Bool = false,
            detail: String? = nil,
            subtitle: String? = nil,
            destructive: Bool = false,
            swatch: NSColor? = nil,
            handler: @escaping () -> Void
        ) -> Item {
            Item(
                kind: .action(handler), title: title, checked: checked,
                detail: detail, subtitle: subtitle, destructive: destructive, swatch: swatch)
        }

        static func header(_ title: String) -> Item {
            Item(kind: .header, title: title)
        }

        static var separator: Item { Item(kind: .separator) }
    }

    private static var window: ShellMenuWindow?

    /// 贴锚点下方、右缘对齐的自绘卡片（ChatGPT 桌面版式，无气泡小三角）。
    /// 空间不够时翻到锚点上方。
    ///
    /// 当初自绘的理由是「NSPopover 的三角关不掉」。这条**已经不成立**：
    /// `NSPopover.hideAnchorArrow()` 能关掉它（见 ShellGlass.swift），搜索条已经这么用了。
    /// 现在仍然自绘，只是因为这套的观感已经够好，不值得为它冒私有属性的风险。
    ///
    /// 换过去的话，10 个调用点一个都不用改——它们只传菜单项数组，只需把这个方法内部
    /// 换成一个 NSPopover，自绘的行原样搬进它的内容视图。什么时候值得换：
    ///   - 需要把这类卡片浮到**终端**上（自绘这套在那儿会变白板，见 blurredBackdrop）
    ///   - 底图不刷新开始露馅（父窗口移动、改大小、明暗切换、底下内容在动）
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

        let size = menu.cardSize
        let anchorRect = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let screen = (parent.screen ?? NSScreen.main)?.visibleFrame ?? anchorRect
        var origin = NSPoint(x: anchorRect.maxX - size.width, y: anchorRect.minY - 6 - size.height)
        if origin.y < screen.minY { origin.y = anchorRect.maxY + 6 }  // 下方放不下 → 上方
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        let cardFrame = NSRect(origin: origin, size: size)
        // 窗口比卡片大一圈：自绘阴影要落在这圈透明边距里
        menu.setFrame(cardFrame.insetBy(dx: -ShellMenuWindow.shadowMargin,
                                        dy: -ShellMenuWindow.shadowMargin), display: false)
        menu.setBackdrop(Self.blurredBackdrop(of: parent, under: cardFrame))

        window = menu
        parent.addChildWindow(menu, ordered: .above)
        menu.makeKeyAndOrderFront(nil)
    }

    /// 卡片底图：父窗口在卡片区域下方的画面 + 小半径高斯模糊。自己截图自己糊，
    /// 半径可控，也不受系统「减少透明度」影响。
    ///
    /// 别指望用 `NSVisualEffectView` 复刻系统气泡那档玻璃——试过，做不到。真气泡运行时
    /// 是 `material 0 / 窗口后模糊 / 跟随窗口活跃态 / 无遮罩`，照这套参数设出来的
    /// 视图长相差一大截；15 种材质、5 种外观、子窗口与独立窗口、`.borderless` 与
    /// `.titled` 都比过，没有一档对得上。那层玻璃是 `NSPopoverFrame` 私有类自己画的，
    /// 要它就只能用 NSPopover 本身。
    ///
    /// 这套截图的硬限制：ghostty 用 IOSurface 画的终端画面截不到，卡片浮到终端上
    /// 只会露出卡片底色（一块白板）。底图也只在打开时截一次，之后不刷新。
    static func blurredBackdrop(of parent: NSWindow, under frame: NSRect) -> NSImage? {
        guard let root = parent.contentView?.superview else { return nil }
        let rootRect = root.convert(parent.convertFromScreen(frame), from: nil)
        guard let rep = root.bitmapImageRepForCachingDisplay(in: rootRect) else { return nil }
        root.cacheDisplay(in: rootRect, to: rep)
        guard let cg = rep.cgImage else { return nil }
        let source = CIImage(cgImage: cg)
        let scale = parent.backingScaleFactor
        let blurred = source.clampedToExtent()
            .applyingGaussianBlur(sigma: 5 * scale)
            .cropped(to: source.extent)
        guard let output = CIContext().createCGImage(blurred, from: blurred.extent) else { return nil }
        return NSImage(cgImage: output, size: rootRect.size)
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

/// 菜单卡片窗口：无边框、透明底。系统给无边框窗口的投影在边界上有一圈很实的暗边
/// （1x 屏上像一道描边），所以关掉，改成卡片四周留透明边距、自绘宽而软的阴影。
/// 成为 key window 以驱动行 hover；失去 key（点了别处）或 Esc 即关闭。
final class ShellMenuWindow: NSWindow {
    /// 阴影可见范围约为半径 ×2.5 再加下沉量，边距必须比它大，否则被窗口边界切平
    static let shadowMargin: CGFloat = 56

    var onDismiss: (() -> Void)?
    /// 回车的默认动作。与 cancelOperation 对称地走响应链，而不是给按钮挂
    /// AppKit 的 keyEquivalent——那是窗口级快捷键，会在 surface 看到事件之前
    /// 截走用户在 Ghostty keybind 表里配的绑定。
    var onDefaultAction: (() -> Void)?
    var dismissesOnResignKey = true
    /// 只为持有：不能设成 contentViewController，那会把它的 view 抢去当窗口根视图
    private let controller: NSViewController
    private let backdrop = NSImageView()
    private let shadowHost = MenuShadowView()

    /// 卡片本体尺寸（不含阴影边距）
    var cardSize: NSSize {
        let size = controller.view.fittingSize
        return NSSize(width: max(size.width, 224), height: size.height)
    }

    func setBackdrop(_ image: NSImage?) {
        backdrop.image = image
    }

    init(content: NSViewController) {
        controller = content
        super.init(
            contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .utilityWindow
        isMovableByWindowBackground = false

        // 根视图透明，卡片内缩 shadowMargin，阴影画在内缩出来的边距里
        let root = NSView()
        shadowHost.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(shadowHost)

        // 卡片 = 底色 → 模糊底图 → 高透抬升面罩 → 内容；圆角由 masksToBounds 裁齐
        let card = MenuCardView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.masksToBounds = true
        // 发丝线：只为在同色底上勾一下轮廓，轮廓感交给阴影
        card.layer?.borderWidth = 0.5
        backdrop.imageScaling = .scaleAxesIndependently
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(backdrop)
        let tint = MenuTintOverlay()
        tint.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(tint)
        content.view.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content.view)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: card.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            tint.topAnchor.constraint(equalTo: card.topAnchor),
            tint.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            tint.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.view.topAnchor.constraint(equalTo: card.topAnchor),
            content.view.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            content.view.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        card.translatesAutoresizingMaskIntoConstraints = false
        shadowHost.addSubview(card)
        let margin = Self.shadowMargin
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: shadowHost.topAnchor),
            card.bottomAnchor.constraint(equalTo: shadowHost.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: shadowHost.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: shadowHost.trailingAnchor),
            shadowHost.topAnchor.constraint(equalTo: root.topAnchor, constant: margin),
            shadowHost.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -margin),
            shadowHost.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            shadowHost.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
        ])
        contentView = root
    }

    override var canBecomeKey: Bool { true }

    /// 透明边距也属于本窗口，落在那里的点击不会传给父窗口；按菜单惯例，
    /// 点在卡片之外即关闭（不转发给底下的控件）。
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown,
           !shadowHost.frame.contains(event.locationInWindow) {
            onDismiss?()
            return
        }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        if dismissesOnResignKey { onDismiss?() }
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }

    override func keyDown(with event: NSEvent) {
        // 36 = Return，76 = 小键盘 Enter；与键盘布局无关。
        guard event.keyCode == 36 || event.keyCode == 76, let action = onDefaultAction else {
            super.keyDown(with: event)
            return
        }
        action()
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
                // 分组标题压在半透明卡片上，10pt + 三级灰几乎看不见。
                // 它是这一组的名字，读不出来就等于没有——用二级灰，字号与字重都提一档。
                let label = NSTextField(labelWithString: item.title)
                label.font = .systemFont(ofSize: 11, weight: .semibold)
                label.textColor = ShellStyle.secondaryText
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
        stack.spacing = 2
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
            constraints.append(button.heightAnchor.constraint(equalToConstant: button.preferredHeight))
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
    var preferredHeight: CGFloat { item.subtitle == nil ? 30 : 48 }
    var onTap: (() -> Void)?
    private let swatch = NSView()

    private let item: ShellMenuPopover.Item
    private let check = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
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
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail

        detailLabel.stringValue = item.detail ?? ""
        detailLabel.font = .systemFont(ofSize: 10.5)
        subtitleLabel.stringValue = item.subtitle ?? ""
        subtitleLabel.font = .systemFont(ofSize: 10.5)
        subtitleLabel.textColor = ShellStyle.secondaryText
        subtitleLabel.lineBreakMode = .byTruncatingTail

        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 6
        swatch.isHidden = item.swatch == nil

        for v in [swatch, check, titleLabel, detailLabel, subtitleLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            swatch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            swatch.centerYAnchor.constraint(equalTo: centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 12),
            swatch.heightAnchor.constraint(equalToConstant: 12),

            titleLabel.leadingAnchor.constraint(
                equalTo: item.swatch == nil ? leadingAnchor : swatch.trailingAnchor,
                constant: item.swatch == nil ? 12 : 10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: item.subtitle == nil ? 0 : -8),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
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
        layer?.backgroundColor = ShellStyle.raisedSurface.withAlphaComponent(0.6)
            .shellResolvedCGColor(for: effectiveAppearance)
    }
}

/// 菜单卡本体：底色与描边随明暗重解析（底图截不到的区域露出底色）。
private final class MenuCardView: NSView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    private func applyColors() {
        layer?.backgroundColor = ShellStyle.raisedSurface.shellResolvedCGColor(for: effectiveAppearance)
        layer?.borderColor = ShellStyle.primaryText.withAlphaComponent(0.08)
            .shellResolvedCGColor(for: effectiveAppearance)
    }
}

/// 卡片阴影载体：宽而软（半径 18、下沉 6、浅色 16% / 深色 45%），无硬边。
private final class MenuShadowView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        applyOpacity()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 14, cornerHeight: 14, transform: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyOpacity()
    }

    private func applyOpacity() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.shadowOpacity = dark ? 0.45 : 0.16
    }
}
