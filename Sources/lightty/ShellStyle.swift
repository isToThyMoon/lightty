import AppKit
import LighttyCore

/// lightty 应用壳层的视觉语言。
///
/// 这里有意不读取 Ghostty 的主题：Ghostty config 只负责 terminal surface 与紧贴
/// surface 的 pane chrome；窗口标题栏、任务侧栏和壳层控件使用独立的 Codex 浅色
/// palette。否则深色终端会把整套应用导航染黑，壳层也会随 background-opacity 透出
/// terminal glyph，既不稳定也不符合参考图。
enum ShellStyle {
    // MARK: Geometry

    /// 双面板侧栏体系：工作区侧栏（docked）+ 任务浮层卡片（overlay）
    static let workspaceColumnWidth: CGFloat = 200
    static let taskPanelWidth: CGFloat = 270
    static let panelInset: CGFloat = 10
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
    /// 侧栏开合专用：ease-in-out cubic（实测手感优于 easeOutExpo）
    static let sidebarAnimationDuration: TimeInterval = 0.28

    // MARK: Motion

    /// easeInOutCubic 的 CA 版本：与侧栏动画手写的那条缓动曲线同一条，
    /// 只是这里交给 Core Animation 求值（呼吸动画不需要逐帧重排，没必要上 display link）。
    static var easeInOutCubic: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1)
    }

    /// 「思考中」呼吸的半程时长。刻意慢：这个动画会在 agent 工作的整段时间里
    /// 一直跑，比人眼的「注意」阈值慢一档才不会一直勾着余光。
    static let statusBreathDuration: TimeInterval = 1.5
    /// 「执行工具」呼吸半程：比思考快一点点，表达「更活跃」，但仍在余光阈值以下。
    static let statusToolBreathDuration: TimeInterval = 1.0
    /// `done` 落地时的三拍闪烁——全套状态动效里唯一一处主动抢注意力的，
    /// 而且是一次性的（不循环），看见即止。
    static let statusDonePulseDuration: TimeInterval = 0.9

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

    // MARK: 状态色（pane 活动状态 / 任务绑定态）

    // 圆点配色以前在 5 个地方各写各的（pane 头、工作区侧栏行、任务侧栏、搜索浮层、
    // 灵动岛），加状态色时必须先收敛成一处，否则每加一个态就要改五遍、必漏。

    /// 已绑定任务 / 任务处于活跃状态的强调色。沿用系统绿——收敛不改观感。
    static let boundAccent = NSColor.systemGreen
    /// 未绑定 / 休眠。沿用系统灰。
    static let dormantAccent = NSColor.systemGray

    // 下面五个是 agent 活动状态色。选色的约束有两条：
    // 1. 要同时压在壳层暖灰底和任意 terminal 底色上都读得出来，所以明暗两套都给足彩度；
    // 2. thinking / tool 同属「还在跑」，刻意用同一蓝族只差一档亮度——它们的区别
    //    对用户不重要；真正要一眼分开的是「还在跑 / 要你 / 跑完了」这三类。
    //    腾出来的色相留给后两者，让它们离得足够远。

    /// 无活跃 turn。比 `dormantAccent` 暖一点，表示「hook 接上了，只是没在跑」。
    static let statusIdle = NSColor.shellDynamic(light: 0x8E8A87, dark: 0x817C86)
    /// 思考中：冷静的蓝，能长时间挂在眼角。
    static let statusThinking = NSColor.shellDynamic(light: 0x4E6EF2, dark: 0x7E9BFF)
    /// 执行工具：同蓝族偏青一档，「更活跃」但不换语义。
    static let statusTool = NSColor.shellDynamic(light: 0x1E8FD0, dark: 0x55BAF0)
    /// 需要你介入：系统橙。曾用土琥珀（C97A08/F2A93B），在菜单栏里读成脏黄点；
    /// 系统橙更亮更饱和，也是 macOS 通知/警示的惯用色。跟随系统动态明暗。
    static let statusAttention = NSColor.systemOrange
    /// 跑完未读：品红。刻意跳出整套暖灰/绿/蓝——它的唯一职责就是被看见，
    /// 尤其不能跟「已绑定」的绿撞色，否则从绿变绿等于没变。
    static let statusDone = NSColor.shellDynamic(light: 0xC9227E, dark: 0xFF71B8)

    static func statusColor(for activity: PaneActivity) -> NSColor {
        switch activity {
        case .idle: return statusIdle
        case .thinking: return statusThinking
        case .tool: return statusTool
        case .attention: return statusAttention
        case .done: return statusDone
        }
    }

    /// 所有圆点的唯一取色入口。
    ///
    /// `nil` 与 `.idle` 都回落到绑定态配色，而不是 `statusIdle`：没有 agent 在跑时
    /// 整个应用必须和这个功能上线前长得一模一样，「装了 hook」不该改变静息观感。
    static func dotColor(bound: Bool, activity: PaneActivity?) -> NSColor {
        guard let activity, activity != .idle else {
            return bound ? boundAccent : dormantAccent
        }
        return statusColor(for: activity)
    }
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

/// 悬停光标。cursor rects（addCursorRect）在本工程 layer-backed + autolayout +
/// 动态重建行的组合下系统性失效（实测全 app 无手型），改用 .cursorUpdate
/// tracking area：owner 收事件设光标，.inVisibleRect 让命中区自动跟随布局，
/// 行重建后无需手动 invalidate。视图持有 tracking area，owner 为共享单例。
final class HoverCursor: NSResponder {
    private let cursor: NSCursor
    private init(_ cursor: NSCursor) {
        self.cursor = cursor
        super.init()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func cursorUpdate(with event: NSEvent) { cursor.set() }

    private static let pointingHand = HoverCursor(.pointingHand)
    private static let resizeLeftRight = HoverCursor(.resizeLeftRight)
    private static let arrow = HoverCursor(.arrow)

    static func installPointingHand(on view: NSView) { install(pointingHand, on: view) }
    static func installResizeLeftRight(on view: NSView) { install(resizeLeftRight, on: view) }
    /// 覆盖在 terminal（整片 I-beam）之上的浮层用：夺回箭头
    static func installArrow(on view: NSView) { install(arrow, on: view) }

    private static func install(_ owner: HoverCursor, on view: NSView) {
        view.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: owner))
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
        HoverCursor.installPointingHand(on: self)
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

/// 无系统强调色的应用 chrome 文字按钮。
final class ShellTextButton: NSButton {
    enum Emphasis { case quiet, primary }

    private let emphasis: Emphasis
    /// 改文字必须走这里，**不要设 `title`**：上色是通过 `attributedTitle` 做的，
    /// 而设 `title` 会把 attributedTitle 连同前景色一起清掉，按钮退回系统默认黑字
    /// （深底上就读不出来了）。
    var label: String { didSet { updateAppearance() } }
    private var tracking: NSTrackingArea?
    private var isHovered = false { didSet { updateAppearance() } }

    /// 软置灰：呈禁用观感但保留点击（用于"点击给出引导提示"的按钮）。
    /// 与 isEnabled 不同——后者会吞掉点击。
    var looksDisabled = false { didSet { updateAppearance() } }

    override var isEnabled: Bool { didSet { updateAppearance() } }

    init(
        _ title: String,
        emphasis: Emphasis = .quiet,
        target: AnyObject?,
        action: Selector?
    ) {
        self.emphasis = emphasis
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
        if emphasis == .primary {
            fill = isHovered ? ShellStyle.actionHoverFill : ShellStyle.actionFill
            enabledText = ShellStyle.actionText
        } else {
            fill = isHovered ? ShellStyle.hoverFill : .clear
            enabledText = ShellStyle.secondaryText
        }
        let dimmed = !isEnabled || looksDisabled
        layer?.backgroundColor = (dimmed ? .clear : fill)
            .shellResolvedCGColor(for: effectiveAppearance)
        alphaValue = isEnabled ? 1 : 0.62
        let color = dimmed ? ShellStyle.tertiaryText : enabledText
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
