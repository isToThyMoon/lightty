import AppKit

/// 侧栏可拖宽度区间：边线在 [minimum, maximum] 之间实时改宽；
/// 到达最小宽后还要再向左拖 closeOvershoot 才关闭，避免想调窄时误收起。
struct SidebarWidthRange: Equatable {
    var minimum: CGFloat
    var maximum: CGFloat
    var closeOvershoot: CGFloat = 40

    func clamped(_ width: CGFloat) -> CGFloat {
        min(max(width, minimum), maximum)
    }

    func shouldClose(rawWidth: CGFloat) -> Bool {
        rawWidth < minimum - closeOvershoot
    }
}

/// 侧栏宽度偏好：没存过用 fallback，存过的按区间钳制后读回。
struct SidebarWidthPreference {
    let defaultsKey: String
    let range: SidebarWidthRange
    let fallback: CGFloat

    func width(in defaults: PreferenceStorage = FilePreferences.shared) -> CGFloat {
        guard defaults.object(forKey: defaultsKey) != nil else { return fallback }
        let stored = CGFloat(defaults.double(forKey: defaultsKey))
        guard stored.isFinite else { return fallback }
        return range.clamped(stored)
    }

    func setWidth(_ width: CGFloat, in defaults: PreferenceStorage = FilePreferences.shared) {
        defaults.set(Double(range.clamped(width)), forKey: defaultsKey)
    }
}

enum TabSidebarSizing {
    static let range = SidebarWidthRange(
        minimum: ShellStyle.tabColumnWidth, maximum: ShellStyle.tabColumnWidth * 2)
    static var minimumWidth: CGFloat { range.minimum }
    static var maximumWidth: CGFloat { range.maximum }
    static var closeOvershoot: CGFloat { range.closeOvershoot }

    static func clampedWidth(_ width: CGFloat) -> CGFloat { range.clamped(width) }
    static func shouldClose(rawWidth: CGFloat) -> Bool { range.shouldClose(rawWidth: rawWidth) }
}

enum TabSidebarWidthPreference {
    static let defaultsKey = "lightty.workspaceSidebar.width"  // 历史键名，改了会丢已存宽度
    /// 默认收在最小宽。
    static let preference = SidebarWidthPreference(
        defaultsKey: defaultsKey, range: TabSidebarSizing.range, fallback: TabSidebarSizing.minimumWidth)

    static func width(in defaults: PreferenceStorage = FilePreferences.shared) -> CGFloat {
        preference.width(in: defaults)
    }

    static func setWidth(_ width: CGFloat, in defaults: PreferenceStorage = FilePreferences.shared) {
        preference.setWidth(width, in: defaults)
    }
}

/// 标签页侧栏（docked，默认展开）：承载 标签页›pane 两级树。
/// 与 task 浮层卡片是两套独立面板——标签页↔pane 是严格层级，task↔pane
/// 是绑定关系，UI 上不呈现并列/嵌套感。
/// 开关在标题栏侧栏按钮；右边线可调宽，越过最小宽度继续左拖则关闭。
final class TabSidebarView: NSView {
    var onCloseRequested: (() -> Void)?
    var onResizeBegan: (() -> Void)?
    var onWidthChange: ((CGFloat) -> Void)?
    var onResizeEnded: (() -> Void)?

    private let column = TabColumnView()
    private let dragStrip = EdgeDragStrip(range: TabSidebarSizing.range)

    init(topInset: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true

        dragStrip.onDragClose = { [weak self] in self?.onCloseRequested?() }
        dragStrip.onResizeBegan = { [weak self] in self?.onResizeBegan?() }
        dragStrip.onWidthChange = { [weak self] width in self?.onWidthChange?(width) }
        dragStrip.onResizeEnded = { [weak self] in self?.onResizeEnded?() }

        for v in [column, dragStrip] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: topInset),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),

            dragStrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            dragStrip.topAnchor.constraint(equalTo: topAnchor, constant: topInset),
            dragStrip.bottomAnchor.constraint(equalTo: bottomAnchor),
            dragStrip.widthAnchor.constraint(equalToConstant: 14),
        ])
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    func reload() { column.reload() }

    private func applyColors() {
        layer?.backgroundColor =
            ShellStyle.sidebarBackground.shellResolvedCGColor(for: effectiveAppearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }
}

/// 边缘开关：贴边半片胶囊——与边线齐平无缝（吸附感），只圆离边那一侧两角，
/// 半透明填充、无描边无投影（弱边界）。默认低存在感，宿主在鼠标靠近边缘带时
/// reveal。task 卡片的两个开关：窗口左缘的展开钮（左平右圆）与卡片右缘的
/// 关闭钮（右平左圆），同一形状的镜像。
final class EdgeToggleControl: NSView, HoverResyncing {
    enum Pointing { case left, right }

    var onTap: (() -> Void)?

    private let pointing: Pointing
    private let blur = NSVisualEffectView()
    private let hoverTint = NSView()
    private let chevron = NSImageView()
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { applyLook() } }
    private var revealed = false

    init(pointing: Pointing) {
        self.pointing = pointing
        super.init(frame: .zero)
        HoverCursor.installPointingHand(on: self)
        alphaValue = 0.65  // 静息常驻低存在感：可发现但不打扰

        // 系统磨砂材质：精致半透明的正解（平涂低透明度灰块会显得廉价）
        blur.material = .popover
        blur.blendingMode = .withinWindow
        blur.state = .active

        hoverTint.wantsLayer = true

        chevron.image = NSImage(
            systemSymbolName: pointing == .left ? "chevron.left" : "chevron.right",
            accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))

        for v in [blur, hoverTint, chevron] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 12),
            heightAnchor.constraint(equalToConstant: 52),
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            hoverTint.topAnchor.constraint(equalTo: topAnchor),
            hoverTint.bottomAnchor.constraint(equalTo: bottomAnchor),
            hoverTint.leadingAnchor.constraint(equalTo: leadingAnchor),
            hoverTint.trailingAnchor.constraint(equalTo: trailingAnchor),
            // chevron 视觉居中。SF Symbol 的画布不对称：实测 8pt bold 下
            // chevron.right 的墨迹中心比画布中心偏右 1pt、chevron.left 偏左 1pt——
            // 按画布居中肉眼就是歪的，常量里把这 1pt 补回来。
            chevron.centerXAnchor.constraint(
                equalTo: centerXAnchor, constant: pointing == .left ? 1 : -1),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 宿主的边缘带 hover 驱动增强/回落（自身 hover 时也保持增强）。
    /// 静息态不隐藏——常驻低存在感，让用户确定"这里可关/可开"。
    func reveal(_ shown: Bool) {
        revealed = shown
        applyLook()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = (shown || hovered) ? 1 : 0.65
        }
    }

    private func applyLook() {
        // 只看 hovered：revealed 驱动的是整体 alpha（在 reveal 里做动画），
        // 这里的 tint/chevron 刻意只对指针真正压上来时才加深。
        chevron.contentTintColor = hovered
            ? ShellStyle.primaryText
            : ShellStyle.secondaryText
        // 磨砂之上叠轻 tint：静息几乎无色、靠近增强（浅色底上纯磨砂会失踪）
        // 静息 tint 要在浅色终端上也可辨（3% 太弱会让底体消失只剩 icon）
        hoverTint.layer?.backgroundColor = ShellStyle.primaryText
            .withAlphaComponent(hovered ? 0.12 : 0.07)
            .shellResolvedCGColor(for: effectiveAppearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLook()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // layer 配置延迟到挂窗后（backing layer 重建会吃掉 init 期配置）。
        blur.wantsLayer = true
        blur.layer?.masksToBounds = true
        // 半胶囊：贴边那一侧平、离边那一侧圆。展开钮贴窗口左缘 → 圆右侧；
        // 关闭钮贴卡片右缘 → 圆左侧。
        let rounded: CACornerMask = pointing == .right
            ? [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            : [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        for layer in [blur.layer, hoverTint.layer] {
            layer?.cornerRadius = 7
            layer?.maskedCorners = rounded
        }
        applyLook()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // 感应区与命中区同步扩大
        let area = NSTrackingArea(
            rect: bounds.insetBy(dx: -10, dy: -6),
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard !ShellHoverGate.suppressed else { return }
        hovered = true
        reveal(true)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        reveal(revealed)
    }

    func resyncHover() {
        updateTrackingAreas()
        // 感应区比 bounds 大（见 updateTrackingAreas），用同一放大矩形判定
        let inside: Bool = {
            guard let window, window.isKeyWindow else { return false }
            let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            return bounds.insetBy(dx: -10, dy: -6).contains(local)
        }()
        guard hovered != inside else { return }
        hovered = inside
        reveal(inside || revealed)
    }

    /// 命中区比视觉宽：左右各扩 10pt 容错，不影响渲染
    override func hitTest(_ point: NSPoint) -> NSView? {
        let expanded = bounds.insetBy(dx: -10, dy: -6)
        return expanded.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { onTap?() }
}

/// 纯 hover 浮现带（窗口左缘展开钮用：无拖动语义、默认光标）。
final class EdgeRevealStrip: NSView {
    var onHoverChange: ((Bool) -> Void)?

    private var tracking: NSTrackingArea?

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

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

    /// 只感应、不命中：它压在标签页栏最左一带上，吞点击会让行的左缘点不到。
    /// tracking area 不依赖 hitTest，hover 照常。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 侧栏右边线的拖动条：最小宽到最大宽之间实时改宽；到达最小宽后继续
/// 向左拖过阈值即关闭。同时保留边缘 hover 感应。两侧栏共用，区间由宿主给。
final class EdgeDragStrip: NSView {
    var range: SidebarWidthRange

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // The scroller lives at the edge too. Only its knob keeps pointer priority:
        // a scrollable list's overlay scroller spans the whole rail, and yielding all
        // of it would leave nowhere to grab the edge.
        for sibling in superview?.subviews ?? [] where sibling !== self {
            for scroll in Self.scrollViews(under: sibling) {
                if let scroller = scroll.verticalScroller, !scroller.isHiddenOrHasHiddenAncestor,
                   scroller.rect(for: .knob).contains(scroller.convert(point, from: superview)) { return nil }
            }
        }
        return hit
    }

    /// 只找到滚动容器为止，不钻进列表行。
    private static func scrollViews(under view: NSView) -> [NSScrollView] {
        if let scroll = view as? NSScrollView { return [scroll] }
        return view.subviews.flatMap { scrollViews(under: $0) }
    }

    init(range: SidebarWidthRange) {
        self.range = range
        super.init(frame: .zero)
        HoverCursor.installResizeLeftRight(on: self)
    }

    required init?(coder: NSCoder) { fatalError() }

    var onDragClose: (() -> Void)?
    var onResizeBegan: (() -> Void)?
    var onWidthChange: ((CGFloat) -> Void)?
    var onResizeEnded: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?

    private var tracking: NSTrackingArea?

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

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

    override func mouseDown(with event: NSEvent) {
        let initialWidth = superview?.bounds.width ?? range.minimum
        let origin = event.locationInWindow.x
        onResizeBegan?()
        while let next = NSApp.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture, inMode: .eventTracking, dequeue: true
        ) {
            let rawWidth = initialWidth + next.locationInWindow.x - origin
            switch next.type {
            case .leftMouseDragged:
                if range.shouldClose(rawWidth: rawWidth) {
                    onWidthChange?(range.minimum)
                    onResizeEnded?()
                    onDragClose?()
                    return
                }
                onWidthChange?(range.clamped(rawWidth))
            case .leftMouseUp:
                onWidthChange?(range.clamped(rawWidth))
                onResizeEnded?()
                return
            default:
                continue
            }
        }
    }
}
