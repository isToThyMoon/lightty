import AppKit

/// 工作区侧栏（docked，默认展开）：承载 工作区›pane 两级树。
/// 与 task 浮层卡片是两套独立面板——工作区↔pane 是严格层级，task↔pane
/// 是绑定关系，UI 上不呈现并列/嵌套感。
/// 右边线中点有透明关闭钮；边线本体可向左拖动关闭。
final class WorkspaceSidebarView: NSView {
    var onCloseRequested: (() -> Void)?

    private let column = WorkspaceColumnView()
    let closeControl = EdgeToggleControl(pointing: .left)
    private let dragStrip = EdgeDragStrip()

    init(topInset: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true

        closeControl.onTap = { [weak self] in self?.onCloseRequested?() }
        dragStrip.onDragClose = { [weak self] in self?.onCloseRequested?() }
        dragStrip.onHoverChange = { [weak self] hovered in
            self?.closeControl.reveal(hovered)
        }

        for v in [column, dragStrip] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        // closeControl 不作为子视图——由 controller 提升到 themeFrame 直属，
        // 解决骑跨 bounds 时 hitTest/cursorRects 被父 bounds 裁断的问题。
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

/// 边缘开关：贴边半片胶囊——与边线齐平无缝（吸附感），只圆外侧两角，
/// 半透明填充、无描边无投影（弱边界）。默认隐形，宿主在鼠标靠近边缘带时
/// reveal。工作区侧栏右缘的关闭钮与窗口左缘的展开钮共用。
final class EdgeToggleControl: NSView {
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
            widthAnchor.constraint(equalToConstant: 14),
            heightAnchor.constraint(equalToConstant: 52),
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            hoverTint.topAnchor.constraint(equalTo: topAnchor),
            hoverTint.bottomAnchor.constraint(equalTo: bottomAnchor),
            hoverTint.leadingAnchor.constraint(equalTo: leadingAnchor),
            hoverTint.trailingAnchor.constraint(equalTo: trailingAnchor),
            // 关闭钮骑缝 chevron 偏侧栏侧；展开钮贴边 chevron 居中
            chevron.centerXAnchor.constraint(
                equalTo: centerXAnchor,
                constant: pointing == .left ? -2 : 0),
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
        let engaged = hovered || revealed
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
        if pointing == .left {
            // 关闭钮：骑线全圆药丸（侧栏/终端分界线上）
            blur.layer?.cornerRadius = 7
            hoverTint.layer?.cornerRadius = 7
        } else {
            // 展开钮：贴窗口左缘半胶囊（左直右圆，吸附感）
            blur.layer?.cornerRadius = 7
            blur.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            hoverTint.layer?.cornerRadius = 7
            hoverTint.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
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
        hovered = true
        reveal(true)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        reveal(revealed)
    }

    /// 命中区比视觉宽：左右各扩 10pt 容错，不影响渲染
    override func hitTest(_ point: NSPoint) -> NSView? {
        let expanded = bounds.insetBy(dx: -10, dy: -6)
        return expanded.contains(convert(point, from: superview)) ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds.insetBy(dx: -10, dy: -6), cursor: .pointingHand)
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
}

/// 侧栏右边线的拖动条：向左拖过阈值即关闭（无实时改宽——侧栏定宽，
/// 拖动语义就是"合上"）；同时是边缘控件的 hover 浮现带。
private final class EdgeDragStrip: NSView {
    var onDragClose: (() -> Void)?
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

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        let origin = event.locationInWindow.x
        while let next = NSApp.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture, inMode: .eventTracking, dequeue: true
        ) {
            switch next.type {
            case .leftMouseDragged:
                if next.locationInWindow.x - origin < -40 {
                    onDragClose?()
                    return
                }
            case .leftMouseUp:
                return
            default:
                continue
            }
        }
    }
}
