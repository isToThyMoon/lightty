import AppKit

/// lightty 应用壳层的视觉语言。
///
/// 这里有意不读取 Ghostty 的主题：Ghostty config 只负责 terminal surface 与紧贴
/// surface 的 pane chrome；窗口标题栏、任务侧栏和壳层控件使用独立的 Codex 浅色
/// palette。否则深色终端会把整套应用导航染黑，壳层也会随 background-opacity 透出
/// terminal glyph，既不稳定也不符合参考图。
enum ShellStyle {
    // MARK: Geometry

    static let sidebarWidth: CGFloat = 300
    static let sidebarHorizontalInset: CGFloat = 10
    static let rowCornerRadius: CGFloat = 9
    static let controlCornerRadius: CGFloat = 8
    static let animationDuration: TimeInterval = 0.22

    // MARK: Codex reference palette

    /// 参考图主标题栏近似 #FFFEFF；保持完全不透明，不继承 terminal opacity。
    static let titlebarBackground = NSColor.shellRGB(0xFFFEFF)
    /// 参考图侧栏的暖灰白综合色；抽屉覆盖 terminal，必须完全不透明。
    static let sidebarBackground = NSColor.shellRGB(0xF6F3F2)
    static let controlFill = NSColor.shellRGB(0xEFEBE9)
    static let hoverFill = NSColor.shellRGB(0xF0ECEA)
    static let selectionFill = NSColor.shellRGB(0xE9E5E3)
    static let pressedFill = NSColor.shellRGB(0xE2DDDA)
    static let divider = NSColor.shellRGB(0xE5E1DF)
    static let primaryText = NSColor.shellRGB(0x302E2D)
    static let secondaryText = NSColor.shellRGB(0x6F6B68)
    static let tertiaryText = NSColor.shellRGB(0x9A9693)
    static let actionFill = NSColor.shellRGB(0x353331)
    static let actionHoverFill = NSColor.shellRGB(0x242321)
    static let actionText = NSColor.white
}

private extension NSColor {
    static func shellRGB(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1)
    }
}

/// Codex 风格的无边框图标按钮：默认安静，hover/按下时才出现圆角底。
final class ShellIconButton: NSButton {
    private var tracking: NSTrackingArea?
    private var isHovered = false { didSet { updateAppearance() } }

    var isActive = false { didSet { updateAppearance() } }
    var onHoverChange: ((Bool) -> Void)?

    init(symbol: String, accessibilityLabel: String, target: AnyObject?, action: Selector?) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityLabel)
        super.init(frame: .zero)
        self.image = image
        self.target = target
        self.action = action
        isBordered = false
        imagePosition = .imageOnly
        focusRingType = .none
        toolTip = accessibilityLabel
        wantsLayer = true
        layer?.cornerRadius = ShellStyle.controlCornerRadius
        contentTintColor = ShellStyle.secondaryText
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .medium)
        setButtonType(.momentaryChange)
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

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

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        onHoverChange?(false)
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = ShellStyle.pressedFill.cgColor
        super.mouseDown(with: event)
        updateAppearance()
    }

    private func updateAppearance() {
        let fill: NSColor = isHovered
            ? ShellStyle.pressedFill
            : (isActive ? ShellStyle.selectionFill : .clear)
        layer?.backgroundColor = fill.cgColor
        contentTintColor = (isHovered || isActive) ? ShellStyle.primaryText : ShellStyle.secondaryText
    }
}

/// 无系统强调色的文字按钮；应用 chrome 与 terminal pane 可选择各自 palette。
final class ShellTextButton: NSButton {
    enum Emphasis { case quiet, primary }
    enum Palette { case shell, terminal }

    private let emphasis: Emphasis
    private let palette: Palette
    private let label: String
    private var tracking: NSTrackingArea?
    private var isHovered = false { didSet { updateAppearance() } }

    override var isEnabled: Bool { didSet { updateAppearance() } }

    init(
        _ title: String,
        emphasis: Emphasis = .quiet,
        palette: Palette = .shell,
        target: AnyObject?,
        action: Selector?
    ) {
        self.emphasis = emphasis
        self.palette = palette
        self.label = title
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        focusRingType = .none
        font = .systemFont(ofSize: 11, weight: emphasis == .primary ? .semibold : .medium)
        wantsLayer = true
        layer?.cornerRadius = ShellStyle.controlCornerRadius
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

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

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    private func updateAppearance() {
        let fill: NSColor
        let enabledText: NSColor
        let disabledText: NSColor
        switch palette {
        case .shell:
            if emphasis == .primary {
                fill = isHovered ? ShellStyle.actionHoverFill : ShellStyle.actionFill
                enabledText = ShellStyle.actionText
            } else {
                fill = isHovered ? ShellStyle.hoverFill : .clear
                enabledText = ShellStyle.secondaryText
            }
            disabledText = ShellStyle.tertiaryText
        case .terminal:
            let foreground = GhosttyRuntime.shared.configValues.foregroundColor
            fill = isHovered ? foreground.withAlphaComponent(0.12) : .clear
            enabledText = foreground.withAlphaComponent(0.72)
            disabledText = foreground.withAlphaComponent(0.32)
        }
        layer?.backgroundColor = fill.cgColor
        alphaValue = isEnabled ? 1 : 0.62
        let color = isEnabled ? enabledText : disabledText
        attributedTitle = NSAttributedString(
            string: label,
            attributes: [.font: font ?? NSFont.systemFont(ofSize: 11), .foregroundColor: color])
    }
}

/// 任务行的圆角 hover / selection 背景，替换 NSTableView 默认的蓝色高亮。
final class ShellTableRowView: NSTableRowView {
    private var tracking: NSTrackingArea?
    private var isHovered = false { didSet { needsDisplay = true } }

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

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func drawBackground(in dirtyRect: NSRect) {
        guard isHovered, !isSelected else { return }
        ShellStyle.hoverFill.setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 2, dy: 2),
            xRadius: ShellStyle.rowCornerRadius,
            yRadius: ShellStyle.rowCornerRadius).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        ShellStyle.selectionFill.setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 2, dy: 2),
            xRadius: ShellStyle.rowCornerRadius,
            yRadius: ShellStyle.rowCornerRadius).fill()
    }
}

/// 铺满某区域但只让自己的子控件接收事件的容器：空白处 hitTest 穿透，
/// 不遮挡下层控件（标题栏 chrome 用它避免吞掉红黄绿三键的点击）。
final class ShellPassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        return view === self ? nil : view
    }
}

/// hover 临时展开侧边栏时，右侧终端区域只负责“点击收起”。点击钉住后不安装此层，
/// 终端保持可交互，空白点击也不会关闭侧栏。
final class SidebarDismissView: NSView {
    var onDismiss: (() -> Void)?

    override func mouseDown(with event: NSEvent) { onDismiss?() }
    override func rightMouseDown(with event: NSEvent) { onDismiss?() }
}
