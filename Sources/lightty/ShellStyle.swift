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
    /// 统一行高系统：所有 chrome 行（tab 栏、pane header、侧栏标题带、搜索框）
    /// 共用 28pt——与 macOS 标题栏同高，这是系统给定的模数基准。行间距统一 12。
    static let chromeRowHeight: CGFloat = 28
    static let chromeGap: CGFloat = 12

    // 搜索浮层（⇧⇧）：尺寸/定位相对窗口，Notion 式左右居中、偏上
    static let paletteWidthRatio: CGFloat = 0.62
    static let paletteMaxWidth: CGFloat = 760
    static let paletteHeightRatio: CGFloat = 0.56
    static let paletteMaxHeight: CGFloat = 600
    static let paletteTopRatio: CGFloat = 0.10
    static let paletteRowGap: CGFloat = 6
    static let rowCornerRadius: CGFloat = 9
    static let controlCornerRadius: CGFloat = 8
    static let animationDuration: TimeInterval = 0.22

    // MARK: Palette（明暗动态色：浅色为 Codex 参考，深色为配套暖灰紫）

    /// 与侧栏同色，拼成一体的应用 chrome；保持完全不透明，不继承 terminal opacity。
    static let titlebarBackground = NSColor.shellDynamic(light: 0xF6F3F2, dark: 0x26242B)
    /// 侧栏底色；抽屉覆盖 terminal，必须完全不透明。
    static let sidebarBackground = NSColor.shellDynamic(light: 0xF6F3F2, dark: 0x26242B)
    static let controlFill = NSColor.shellDynamic(light: 0xEFEBE9, dark: 0x323037)
    /// 抬升面：浮在 chrome 之上的卡片（搜索浮层预览等），浅色纯白、深色亮一档
    static let raisedSurface = NSColor.shellDynamic(light: 0xFFFFFF, dark: 0x2E2C33)
    static let hoverFill = NSColor.shellDynamic(light: 0xF0ECEA, dark: 0x312F36)
    static let selectionFill = NSColor.shellDynamic(light: 0xE9E5E3, dark: 0x3B3841)
    static let pressedFill = NSColor.shellDynamic(light: 0xE2DDDA, dark: 0x44414A)
    static let divider = NSColor.shellDynamic(light: 0xE5E1DF, dark: 0x3B3841)
    static let primaryText = NSColor.shellDynamic(light: 0x302E2D, dark: 0xE9E7EC)
    static let secondaryText = NSColor.shellDynamic(light: 0x6F6B68, dark: 0xA39FAA)
    static let tertiaryText = NSColor.shellDynamic(light: 0x9A9693, dark: 0x757079)
    /// 主按钮在两种外观下都取反色强调。
    static let actionFill = NSColor.shellDynamic(light: 0x353331, dark: 0xE9E7EC)
    static let actionHoverFill = NSColor.shellDynamic(light: 0x242321, dark: 0xF8F6FA)
    static let actionText = NSColor.shellDynamic(light: 0xFFFFFF, dark: 0x26242B)
}

extension NSColor {
    static func shellRGB(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1)
    }

    /// 明暗自适应色。文本/draw 路径自动解析；layer.cgColor 是快照，
    /// 持有方必须在 viewDidChangeEffectiveAppearance 里重设（见 shellResolvedCGColor）。
    static func shellDynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return .shellRGB(isDark ? dark : light)
        }
    }

    /// 按给定外观解析出 CGColor 快照（供 layer 背景/边框用）。
    func shellResolvedCGColor(for appearance: NSAppearance) -> CGColor {
        var resolved = cgColor
        appearance.performAsCurrentDrawingAppearance { resolved = self.cgColor }
        return resolved
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
        layer?.backgroundColor = ShellStyle.pressedFill.shellResolvedCGColor(for: effectiveAppearance)
        super.mouseDown(with: event)
        updateAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        let fill: NSColor = isHovered
            ? ShellStyle.pressedFill
            : (isActive ? ShellStyle.selectionFill : .clear)
        layer?.backgroundColor = fill.shellResolvedCGColor(for: effectiveAppearance)
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

    /// terminal palette 的前景色来源；core 报告 COLOR_CHANGE（主题切换/OSC）后
    /// 由 pane header 注入当前值，未设置时回退启动期全局 config。
    var terminalForeground: NSColor? { didSet { updateAppearance() } }
    /// 软置灰：呈禁用观感但保留点击（用于"点击给出引导提示"的按钮）。
    /// 与 isEnabled 不同——后者会吞掉点击。
    var looksDisabled = false { didSet { updateAppearance() } }

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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

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
            let foreground = terminalForeground
                ?? GhosttyRuntime.shared.configValues.foregroundColor
            fill = isHovered ? foreground.withAlphaComponent(0.12) : .clear
            enabledText = foreground.withAlphaComponent(0.72)
            disabledText = foreground.withAlphaComponent(0.32)
        }
        let dimmed = !isEnabled || looksDisabled
        layer?.backgroundColor = (dimmed ? .clear : fill)
            .shellResolvedCGColor(for: effectiveAppearance)
        alphaValue = isEnabled ? 1 : 0.62
        let color = dimmed ? disabledText : enabledText
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

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

/// 纯色背景块：外观切换时自动按当前明暗重解析 layer 颜色。
/// layer.backgroundColor 是 CGColor 快照，普通 NSView 不会自己更新。
final class ShellBackdropView: NSView {
    var fill: NSColor = .clear { didSet { applyFill() } }

    init(fill: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        self.fill = fill
        applyFill()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFill()
    }

    private func applyFill() {
        layer?.backgroundColor = fill.shellResolvedCGColor(for: effectiveAppearance)
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
