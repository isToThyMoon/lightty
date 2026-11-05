import AppKit
import GhosttyKit
import LighttyCore

/// 身份胶囊与灵动岛第一行共用的排布。
///
/// 两处必须逐像素同构：展开时胶囊瞬间隐身、面板第一行顶上，收起时反过来。差一个
/// 像素，交接那一帧就能看见文字跳。数只留这一份——之前胶囊加了 agent 图标而岛体
/// 没跟上，文字就往回缩了 14pt。
enum PaneIdentityMetrics {
    static let dotLeading: CGFloat = 6
    static let dotSize: CGFloat = 7
    /// 状态点尾 → 图标
    static let iconLeading: CGFloat = 6
    static let iconSize: CGFloat = 10
    /// 图标尾 → 名字
    static let iconGap: CGFloat = 4
}

/// 胶囊右侧的任务区：未绑定显示「+ 任务」，已绑定显示任务名和箭头，窄时只剩图标。
/// 点击落点由 `PaneHeaderView.mouseDown` 判定（header 的 hitTest 把点击都收给自己，
/// 拖动才能从胶囊任意位置开始）；这里只管外观与 hover。
final class PaneTaskChip: NSView {
    static let compactWidth: CGFloat = 18
    private static let textInset: CGFloat = 7
    private static let iconSlot: CGFloat = 12
    private static let chevronSlot: CGFloat = 11
    /// NSTextField 单行文字两侧的固有内边距，量文字时要算上，否则刚好放不下。
    private static let labelPadding: CGFloat = 5

    let label = NSTextField(labelWithString: "")
    private let divider = NSView()
    private let icon = NSImageView()
    private let chevron = NSImageView()
    private var labelLeading: NSLayoutConstraint!
    private var chevronWidth: NSLayoutConstraint!
    private var taskName: String?
    private var compact = false
    private var foreground = NSColor.white
    private var hovered = false { didSet { applyFill() } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = ShellStyle.capsuleCornerRadius
        divider.wantsLayer = true
        label.font = ShellStyle.Font.caption
        label.lineBreakMode = .byTruncatingTail
        // 低于 pane 名（249）：长任务名不能撑大 pane 的最小宽度，宽度由 taskChipWidth 决定。
        label.setContentCompressionResistancePriority(.init(rawValue: 248), for: .horizontal)
        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 7, weight: .semibold))
        for view in [divider, icon, label, chevron] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        labelLeading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.textInset)
        chevronWidth = chevron.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.centerYAnchor.constraint(equalTo: centerYAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 10),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.textInset - 1),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelLeading,
            chevronWidth,
            label.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        render()
    }

    required init?(coder: NSCoder) { fatalError() }

    var fullWidth: CGFloat {
        let text = ceil((displayText as NSString).size(withAttributes: [.font: label.font as Any]).width)
        return Self.textInset + (taskName == nil ? Self.iconSlot : Self.chevronSlot) + text + Self.labelPadding
    }

    private var displayText: String { taskName ?? L("Task") }

    func apply(taskName: String?, compact: Bool) {
        guard self.taskName != taskName || self.compact != compact else { return }
        self.taskName = taskName
        self.compact = compact
        render()
    }

    func apply(foreground: NSColor) {
        self.foreground = foreground
        render()
    }

    private func render() {
        label.stringValue = compact ? "" : displayText
        label.isHidden = compact
        label.textColor = foreground.withAlphaComponent(taskName == nil ? 0.55 : 0.7)
        chevron.isHidden = compact || taskName == nil
        chevronWidth.constant = chevron.isHidden ? 0 : Self.chevronSlot
        chevron.contentTintColor = foreground.withAlphaComponent(0.5)
        icon.isHidden = !compact && taskName != nil
        icon.image = NSImage(systemSymbolName: taskName == nil ? "plus" : "checklist",
                             accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        icon.contentTintColor = foreground.withAlphaComponent(0.55)
        labelLeading.constant = Self.textInset + (taskName == nil ? Self.iconSlot : 0)
        divider.layer?.backgroundColor = foreground.withAlphaComponent(0.18).cgColor
        toolTip = (taskName.map { $0 + "\n" } ?? "") + L("Choose or create a task (default shortcut ⇧⌘P)")
        setAccessibilityLabel(taskName ?? L("Choose task"))
        applyFill()
    }

    private func applyFill() {
        layer?.backgroundColor = hovered ? foreground.withAlphaComponent(0.1).cgColor : NSColor.clear.cgColor
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    /// 灵动岛展开时胶囊瞬间隐身，这张位图留在原位淡出，任务区不会突然消失。
    func snapshot() -> NSImage? {
        guard bounds.width > 0, let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}

/// 每 pane 一条 chromeRowHeight 高的 header：身份胶囊（状态点 + pane 名 + 任务区）。
/// 胶囊是唯一常驻身份对象（灵动岛式），分两块可点区域：点 pane 名向下展开
/// PaneIdentityPanel（改名、看 handoff 详情）；点任务区直接打开任务选择器。
/// 任务区不随宽度消失，窄时收成图标，否则入口又藏起来了。
/// 它紧贴 terminal surface，底色/文字仍取 Ghostty config 的
/// background/foreground + background-opacity；应用标题栏/侧栏则使用独立 ShellStyle。
/// ⚠️ 必须 clipsToBounds：layer 化后自绘内容会落在超出 bounds 的 ContentLayer 上，
/// 半透明底色会整张盖住终端（docs/libghostty-embedding.md 透明排查实录）。
final class PaneHeaderView: NSView, NSDraggingSource {
    static let height: CGFloat = ShellStyle.chromeRowHeight
    /// 身份胶囊占 pane 宽度的上限。标题是 agent 写的，长度不可信；没有这条上限
    /// 它会既撑爆视觉，又把 pane 的最小宽度钉死在标题长度上。
    static let capsuleWidthRatio: CGFloat = 0.8

    enum Dot: Equatable {
        case unnamed        // 灰：未绑定任务
        case active         // 绿：已绑定任务文件

        var color: NSColor {
            ShellStyle.dotColor(bound: self == .active, activity: nil)
        }
    }

    /// 单击/开始拖动 header 时把该 pane 设为 active。
    var onSelect: (() -> Void)?
    /// 点击身份胶囊：展开/收起 PaneIdentityPanel。
    var onIdentityTapped: (() -> Void)?
    /// 点击胶囊右侧任务区：直接打开任务选择器。
    var onTaskChipTapped: (() -> Void)?
    var onDragEnded: (() -> Void)?
    /// Ghostty SurfaceDragSource 的轻量 AppKit 对应：UUID 只用于进程内定位现有 pane。
    var dragIdentifier: UUID?
    var dragPreviewProvider: (() -> NSImage?)?

    private var isDraggingPane = false

    private let capsule = NSView()
    private let dotView = NSView()
    /// hover 时替换圆点位置出现的关闭键（Safari tab 式：同插槽零位移，
    /// 不改变胶囊布局——胶囊与灵动岛首行逐像素对齐是 morph 的硬约束）。
    private let closeButton = NSButton()
    var onCloseRequested: (() -> Void)?
    private let nameLabel = NSTextField(labelWithString: "")
    private let agentIcon = NSImageView()
    private var agentIconWidth: NSLayoutConstraint!
    private var agentIconGap: NSLayoutConstraint!
    var sessionAgent: SessionAgent? {
        didSet {
            guard oldValue != sessionAgent else { return }
            agentIcon.image = sessionAgent.flatMap { AgentSessionIcon.image(for: $0) }
            agentIconWidth.constant = sessionAgent == nil ? 0 : PaneIdentityMetrics.iconSize
            agentIconGap.constant = sessionAgent == nil ? 0 : PaneIdentityMetrics.iconGap
        }
    }
    private let taskChip = PaneTaskChip()
    private var taskChipWidth: NSLayoutConstraint!
    private var taskChipGap: NSLayoutConstraint!
    private var capsuleTracking: NSTrackingArea?
    private var headerTracking: NSTrackingArea?
    private var capsuleHovered = false {
        didSet {
            applyCapsuleFill()
            dotView.isHidden = capsuleHovered
            closeButton.isHidden = !capsuleHovered
            // ✕ 占的就是圆点那个插槽，hover 期间状态色会整个消失。
            // 解法是让 ✕ 自己染上状态色，而不是抑制这次替换：
            // ✕ 是 header 里唯一的关 pane 入口，为了显示状态把它藏掉是本末倒置，
            // 而且用户此刻的注意力本来就在圆点位置，染色足够被看到。
            // `.attention` 另有胶囊外圈的呼吸环，不在这个插槽里，hover 天然不影响。
            applyCloseButtonTint()
            updateAmbientAnimations()  // 圆点藏起来时没必要继续烧一条呼吸动画
        }
    }
    private var capsuleIsHidden = false

    var title: String {
        get { nameLabel.stringValue }
        set { nameLabel.stringValue = newValue }
    }

    /// 胶囊在 header 坐标系中的 frame（面板形变动画的起点/终点）。
    var capsuleFrame: NSRect { capsule.frame }
    /// 名字相对状态点的横向偏移。灵动岛第一行必须给出同一个数，否则交接会跳。
    var titleOffsetFromDot: CGFloat { nameLabel.frame.minX - dotView.frame.maxX }

    /// 面板展开期间胶囊隐身。瞬时切换、不淡出：面板第一行与胶囊逐像素同构，
    /// 交接瞬间标题原地不动（灵动岛的"岛体扩展、内容不动"）。
    func setCapsuleHidden(_ hidden: Bool) {
        capsule.alphaValue = hidden ? 0 : 1
        capsuleIsHidden = hidden
        // 这一句被调用时面板刚挂上窗口（PaneView 的展开顺序：refresh → addSubview →
        // setCapsuleHidden），正好是把状态色补给灵动岛的时机——PaneView 的
        // refresh(panel:) 传的是静态绑定色，不知道状态。
    }

    var dot: Dot = .unnamed {
        didSet { applyDotColor() }
    }

    /// `.attention` 的轻量注意力环：胶囊外圈细描边缓慢呼吸。
    private var attentionRing: NSView?
    private static let ringBreatheKey = "breathe"

    private func beginCapsuleAttention() {
        guard attentionRing == nil else {
            syncAttentionRingFrame()
            return
        }
        let ring = NSView(frame: capsule.frame.insetBy(dx: -4, dy: -4))
        ring.wantsLayer = true
        ring.layer?.cornerRadius = 10
        ring.layer?.borderWidth = 1.5
        ring.layer?.borderColor = terminalForeground.withAlphaComponent(0.5).cgColor
        addSubview(ring)
        attentionRing = ring
        updateAmbientAnimations()
    }

    private func endCapsuleAttention() {
        guard let ring = attentionRing else { return }
        attentionRing = nil
        // 先摘掉无限循环的呼吸，否则它会一直改写 opacity，把这段淡出盖掉
        ring.layer?.removeAnimation(forKey: Self.ringBreatheKey)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            ring.animator().alphaValue = 0
        }, completionHandler: { ring.removeFromSuperview() })
    }

    /// 环是 frame 布局（不在约束链上，避免影响胶囊尺寸），胶囊被重排后要跟上。
    private func syncAttentionRingFrame() {
        attentionRing?.frame = capsule.frame.insetBy(dx: -4, dy: -4)
    }

    /// 绑定任务名；nil = 未绑定。
    func setTaskName(_ name: String?) {
        boundTaskName = name
        taskChip.apply(taskName: name, compact: false)
        needsLayout = true
    }

    private var boundTaskName: String?
    var titleOfBoundTask: String? { boundTaskName }

    /// core 通过 CONFIG_CHANGE / COLOR_CHANGE 报告的当前 terminal 颜色；
    /// 启动值来自全局 config。背景色对外暴露给聚光灯纱取色：
    /// 纱必须跟 pane 当前实际主题走（明暗切换、per-surface 条件主题）。
    private(set) var terminalBackground: NSColor
    private(set) var terminalForeground: NSColor

    init() {
        let cfg = GhosttyRuntime.shared.configValues
        terminalBackground = cfg.backgroundColor
        terminalForeground = cfg.foregroundColor
        super.init(frame: .zero)
        clipsToBounds = true
        wantsLayer = true

        capsule.wantsLayer = true
        capsule.layer?.cornerRadius = ShellStyle.capsuleCornerRadius

        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = PaneIdentityMetrics.dotSize / 2
        applyDotColor()

        nameLabel.font = ShellStyle.Font.compactTitle
        nameLabel.lineBreakMode = .byTruncatingTail
        // 标题由 agent 写，长度不可信。抗压缩优先级必须**低于** NSSplitView 的
        // holding priority（默认就是 250），否则"标题宽度 + 内边距"会变成整个 pane
        // 的最小宽度：同 tab 的兄弟 pane 被挤扁，分割线连拖都拖不动。
        // 正好等于 250 是平手，AppKit 两边都可能赢，所以要显式低一档。
        // 低一档而不是更低：宽度富余时没有别的力量推它，标题照样取固有宽度。
        nameLabel.setContentCompressionResistancePriority(
            .init(rawValue: NSLayoutConstraint.Priority.defaultLow.rawValue - 1),
            for: .horizontal)

        closeButton.image = NSImage(
            systemSymbolName: ShellSymbol.close, accessibilityDescription: L("Close pane"))?
            .withSymbolConfiguration(.init(pointSize: ShellStyle.closeIconSize, weight: .bold))
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.focusRingType = .none
        closeButton.isHidden = true
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.toolTip = L("Close pane")

        applyTerminalColors()

        let capsuleArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        capsule.addTrackingArea(capsuleArea)
        capsuleTracking = capsuleArea

        addSubview(capsule)
        for v in [dotView, closeButton, agentIcon, nameLabel, taskChip] {
            v.translatesAutoresizingMaskIntoConstraints = false
            capsule.addSubview(v)
        }
        capsule.translatesAutoresizingMaskIntoConstraints = false
        agentIconWidth = agentIcon.widthAnchor.constraint(equalToConstant: 0)
        agentIconGap = nameLabel.leadingAnchor.constraint(equalTo: agentIcon.trailingAnchor)
        taskChipWidth = taskChip.widthAnchor.constraint(equalToConstant: 0)
        taskChipGap = taskChip.leadingAnchor.constraint(
            equalTo: nameLabel.trailingAnchor, constant: Self.taskChipLeadingGap)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),

            // full-size terminal 会延伸到原生标题栏下；标签页侧栏收起时，左贴的
            // 身份胶囊会被红黄绿与侧栏开关盖住。按各 pane 自身居中后不再依赖
            // 窗口左侧安全区，多分屏也各自保持一致的视觉轴。
            capsule.centerXAnchor.constraint(equalTo: centerXAnchor),
            capsule.centerYAnchor.constraint(equalTo: centerYAnchor),
            capsule.heightAnchor.constraint(equalToConstant: 20),
        ])
        // 胶囊最多占 pane 的 capsuleWidthRatio、两侧各留 4pt：居中摆放两侧各留一段
        // 气口，长标题下它仍然读作一枚 chip 而不是横幅。优先级 999 而不是必需：
        // 仍远高于标题的抗压缩（249），正常宽度下照样截标题；但 pane 刚创建时宽度
        // 是 0，胶囊里点、图标、边距加起来的最小宽度塞不进去，必需约束就无解，
        // 布局引擎会挑一条断掉且之后不再恢复——实测断的是图标宽度，图标撑回 SVG
        // 的 24pt 固有宽度，点和名字之间多出 14pt 空隙（展开的岛体没有这条上限，不受影响）。
        let widthLimits = [
            capsule.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
            capsule.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -4),
            capsule.widthAnchor.constraint(
                lessThanOrEqualTo: widthAnchor, multiplier: Self.capsuleWidthRatio),
        ]
        for limit in widthLimits { limit.priority = .init(999) }
        NSLayoutConstraint.activate(widthLimits + [

            dotView.leadingAnchor.constraint(
                equalTo: capsule.leadingAnchor, constant: PaneIdentityMetrics.dotLeading),
            dotView.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: PaneIdentityMetrics.dotSize),
            dotView.heightAnchor.constraint(equalToConstant: PaneIdentityMetrics.dotSize),

            // 与圆点同心、命中区放大到 16pt；不参与水平链，布局零位移
            closeButton.centerXAnchor.constraint(equalTo: dotView.centerXAnchor),
            closeButton.centerYAnchor.constraint(equalTo: dotView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),

            agentIcon.leadingAnchor.constraint(
                equalTo: dotView.trailingAnchor, constant: PaneIdentityMetrics.iconLeading),
            agentIcon.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            agentIcon.heightAnchor.constraint(equalToConstant: PaneIdentityMetrics.iconSize),
            agentIconWidth,
            agentIconGap,
            nameLabel.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),

            taskChipGap,
            taskChipWidth,
            taskChip.topAnchor.constraint(equalTo: capsule.topAnchor),
            taskChip.bottomAnchor.constraint(equalTo: capsule.bottomAnchor),
            taskChip.trailingAnchor.constraint(
                equalTo: capsule.trailingAnchor, constant: -Self.capsuleTrailingInset),
            taskChip.label.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),
        ])

        // 状态动画的开关条件（key / 遮挡）都是窗口级事件。object 传 nil 收全部窗口的，
        // 再统一重算 canAnimate——比为每次换窗口重挂一遍观察者省事，代价只是几次空跑。
        for name: NSNotification.Name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowVisibilityChanged),
                name: name, object: nil)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func windowVisibilityChanged() { updateAmbientAnimations() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 新建 pane / 跨窗口拖动落地：presenter 不知道这一刻，自己向 store 取
        updateAmbientAnimations()
    }

    // tab 切换是 container.isHidden，这两个回调会一路发到子树上
    override func viewDidHide() {
        super.viewDidHide()
        updateAmbientAnimations()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateAmbientAnimations()
    }

    // MARK: - 胶囊内容与 hover

    private static let taskChipLeadingGap: CGFloat = 7
    private static let capsuleTrailingInset: CGFloat = 7
    /// 名字和任务名都要截断时，名字至少留这么宽才值得保留文字任务区，否则任务区收成图标。
    private static let minimumNameWidth: CGFloat = 72
    private static let minimumChipTextWidth: CGFloat = 86

    /// 宽度仲裁放在 `super.layout()` 之前，本轮布局就用上新约束。
    override func layout() {
        if bounds.width > 0 { arbitrateTaskChipWidth() }
        super.layout()
        guard bounds.width > 0 else { return }
        syncAttentionRingFrame()
        // 胶囊宽度随文案变，手型矩形要跟着重算
        window?.invalidateCursorRects(for: self)
    }

    /// 预算按胶囊自己的上限算，不是整条 header：长标题下它仍然读作一枚 chip 而不是横幅。
    private func arbitrateTaskChipWidth() {
        let chrome = PaneIdentityMetrics.dotLeading + PaneIdentityMetrics.dotSize
            + PaneIdentityMetrics.iconLeading + agentIconWidth.constant
            + agentIconGap.constant + Self.taskChipLeadingGap + Self.capsuleTrailingInset
        let budget = min(bounds.width - 8, floor(bounds.width * Self.capsuleWidthRatio))
        let room = max(0, budget - chrome)
        let title = ceil(nameLabel.intrinsicContentSize.width)
        let full = taskChip.fullWidth
        let width: CGFloat
        if title + full <= room {
            width = full
        } else {
            // 放不下时两边都让：任务区最多占四成，名字拿其余；再窄就收成图标。
            let shared = max(min(full, Self.minimumChipTextWidth), min(full, floor(room * 0.4)))
            width = room - shared >= Self.minimumNameWidth ? shared : PaneTaskChip.compactWidth
        }
        taskChip.apply(taskName: boundTaskName, compact: width == PaneTaskChip.compactWidth)
        if taskChipWidth.constant != width { taskChipWidth.constant = width }
    }

    private func applyCapsuleFill() {
        capsule.layer?.backgroundColor = terminalForeground
            .withAlphaComponent(capsuleHovered ? 0.10 : 0.05).cgColor
    }

    /// 手型只给胶囊（含其中的关闭钮）：它是"可点开面板"的东西；header 其余
    /// 空白只是选中/拖动区，保持箭头。
    /// 这里不用 HoverCursor：header 与 terminal 的 I-beam 光标区相邻，跨界时
    /// cursor rect 的「离开还原箭头」晚于 tracking area 的设置，手型会被盖掉
    /// （探针实测）。加入同一套 cursor rect 机制后，交接由窗口原子完成。
    override func resetCursorRects() {
        addCursorRect(convert(capsule.frame, from: capsule.superview), cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // 胶囊的 hover 区挂在胶囊自己身上（init 里装一次，.inVisibleRect 跟随胶囊）。
        // 以前在这里按 capsule.frame 算死矩形：这个回调只在 header 自身尺寸变时才来，
        // 胶囊随标题变宽却不会触发——短标题「Terminal」时记下的中间一小块一直不更新，
        // 换成长标题后移到左侧圆点就算离开胶囊，关闭键随之消失，pane 关不掉。

        if let headerTracking { removeTrackingArea(headerTracking) }
        // .activeAlways：app 未激活时第一下点击也可能直接是拖 pane
        let header = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self)
        addTrackingArea(header)
        headerTracking = header
    }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea === headerTracking {
            window?.isMovable = false
        } else {
            capsuleHovered = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea === headerTracking {
            // 按住鼠标期间（pane 拖拽进行中）绝不放闸：实测服务器会在手势
            // 中途读到 true 立刻接管成窗口拖动。恢复交给 draggingSession 结束。
            if NSEvent.pressedMouseButtons == 0 { window?.isMovable = true }
        } else {
            capsuleHovered = false
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // pane 在 hover 期间被关闭/移走时 mouseExited 不再送达，闸必须在此归位
        if newWindow !== window { window?.isMovable = true }
        super.viewWillMove(toWindow: newWindow)
    }

    // MARK: - 颜色

    private func applyTerminalColors() {
        let opacity = GhosttyRuntime.shared.configValues.backgroundOpacity
        layer?.backgroundColor = terminalBackground
            .withAlphaComponent(opacity).cgColor
        nameLabel.textColor = terminalForeground
        agentIcon.contentTintColor = terminalForeground
        taskChip.apply(foreground: terminalForeground)
        applyCloseButtonTint()
        applyCapsuleFill()
        attentionRing?.layer?.borderColor = terminalForeground
            .withAlphaComponent(0.5).cgColor
    }

    /// 状态色是 `shellDynamic`，CGColor 只是快照——外观切换必须重解析，
    /// 否则明暗切换后圆点还是旧那套（ShellStyle 里 shellResolvedCGColor 的注释）。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyDotColor()
        applyCloseButtonTint()
    }

    /// per-surface CONFIG_CHANGE（条件主题解析结果）：一次拿到整套前景/背景。
    func applyTerminalTheme(background: NSColor, foreground: NSColor) {
        terminalBackground = background
        terminalForeground = foreground
        applyTerminalColors()
    }

    /// core 报告 per-surface 颜色变化（GHOSTTY_ACTION_COLOR_CHANGE）后由
    /// runtime 转发；header 随 terminal 主题重新着色。
    func noteTerminalColorChange(kind: ghostty_action_color_kind_e, color: NSColor) {
        switch kind {
        case GHOSTTY_ACTION_COLOR_KIND_BACKGROUND: terminalBackground = color
        case GHOSTTY_ACTION_COLOR_KIND_FOREGROUND: terminalForeground = color
        default: return
        }
        applyTerminalColors()
    }

    // MARK: - agent 活动状态

    private static let dotPulseKey = "statusPulse"

    private var status: PaneStatus?
    private var isUnread = false
    /// `.done` 落地时如果 pane 不可见，闪烁就白放了——记下来，等可见了补上。
    private var pendingDonePulse = false

    /// PaneView renders the application session model's activity snapshot.
    ///
    /// 终端头**真正显示出来**的三样东西：圆点跟状态走，tooltip 用 tool 与 detail。
    ///
    /// 比较它，而不是比较原始状态里的字段：以后往这里加显示项，就必须加进这个值，
    /// 守卫自动跟着走。别照抄侧栏行那边的字段表——那边显示 `cwd`，这里不显示；
    /// 这里显示 `detail`，那边不显示。**各自比自己显示的东西**（见
    /// `TabColumnView` 里 `PaneRowView.Rendered`）。
    private struct Rendered: Equatable {
        var state: PaneActivity?
        var tool: String?
        var detail: String?
        /// 纯函数，不另存缓存——理由同 `PaneRowView.Rendered`。
        init(of status: PaneStatus?) {
            state = status?.state
            tool = status?.tool
            detail = status?.detail
        }
    }

    func apply(_ status: PaneStatus?, isUnread: Bool = true) {
        // 高频入口：PreToolUse/PostToolUse 一次工具调用就来两发，先挡住无变化的。
        guard Rendered(of: self.status) != Rendered(of: status) || self.isUnread != isUnread else { return }
        let enteredDone = status?.state == .done && self.status?.state != .done
        self.status = status
        self.isUnread = isUnread

        applyDotColor()
        applyCloseButtonTint()
        updateStatusTooltip()

        // `.attention` 直接复用现成的呼吸环（唯一一处「非人不可」的状态，
        // 值得动用胶囊级的提示；其余状态一律只在圆点里表达）
        if status?.state == .attention && isUnread {
            beginCapsuleAttention()
        } else {
            endCapsuleAttention()
        }

        // 转出 done（focus 后 markRead）时把欠着的闪烁一并作废——
        // 否则它会晚一步落在一个已经不是 done 的圆点上
        pendingDonePulse = enteredDone || (pendingDonePulse && status?.state == .done)
        updateAmbientAnimations()
    }

    private var activity: PaneActivity? { status?.state }
    var activityDotColor: NSColor? {
        (activity == nil || activity == .idle) ? nil : effectiveDotColor
    }

    private var effectiveDotColor: NSColor {
        ShellStyle.dotColor(bound: dot == .active, activity: activity)
    }

    private func applyDotColor() {
        dotView.layer?.backgroundColor = effectiveDotColor
            .shellResolvedCGColor(for: effectiveAppearance)
    }

    private func applyCloseButtonTint() {
        // 有状态时 ✕ 借状态色，把被它盖住的圆点信息带出来；无状态时回到中性前景色
        let color = (activity == nil || activity == .idle)
            ? terminalForeground.withAlphaComponent(0.7)
            : effectiveDotColor
        closeButton.contentTintColor = color
    }

    /// 工具名/摘要只进 tooltip，不进胶囊。
    ///
    /// 胶囊里唯一有弹性的槽位是任务区，`layout()` 的宽度仲裁就是围着它写的。
    /// 把工具名塞进去要么和任务名抢那一个槽（`PreToolUse` 的频率下等于让文字
    /// 不停跳变——比呼吸的圆点扎眼得多，正好和「不打扰」相反），要么再加一段
    /// 仲裁逻辑去挤 pane 名。两条都比这点信息量贵，所以走 tooltip。
    private func updateStatusTooltip() {
        toolTip = TabPaneStatusPresentation.detailLine(for: status)
    }

    // MARK: 环境动画的开关

    /// 动画只在「窗口是 key、窗口没被遮挡、pane 所在 tab 可见」时跑。
    ///
    /// 后台 pane 空转一条无限循环的 CAAnimation 是实打实的续航 bug：多开几个 agent
    /// 就是几条永不停的 render server 时钟。而且此刻本来也没人看得见。
    private var canAnimate: Bool {
        guard let window, !isHiddenOrHasHiddenAncestor else { return false }
        return window.isKeyWindow && window.occlusionState.contains(.visible)
    }

    private func updateAmbientAnimations() {
        guard canAnimate else {
            dotView.layer?.removeAnimation(forKey: StatusDotBreath.animationKey)
            attentionRing?.layer?.removeAnimation(forKey: Self.ringBreatheKey)
            return
        }

        // 0.3↔0.9 / 0.9s 是这个环原本的参数，原样保留（提示气泡的手感已经调过）
        if attentionRing?.layer?.animation(forKey: Self.ringBreatheKey) == nil {
            attentionRing?.layer?.add(
                breathe(from: 0.3, to: 0.9, duration: 0.9), forKey: Self.ringBreatheKey)
        }

        // 与第二侧栏同一套呼吸（`StatusDotBreath`）：颜色往身后的表面上混，不动透明度或几何，
        // 所有点共用一个时钟。这里身后是终端自己的背景色，不是侧栏底色。
        // hover 时圆点整个 isHidden，动画留着也没人看，白烧。
        if let layer = dotView.layer {
            StatusDotBreath.apply(to: layer, color: effectiveDotColor, activity: activity,
                                  appearance: effectiveAppearance, enabled: !capsuleHovered,
                                  into: terminalBackground)
        }

        if pendingDonePulse && !capsuleHovered {
            pendingDonePulse = false
            pulseDot()
        }
    }

    private func breathe(
        from: CGFloat, to: CGFloat, duration: TimeInterval
    ) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = ShellStyle.easeInOutCubic
        return animation
    }

    /// `done` 的三拍闪烁：一次性，不循环。这是整套状态动效里唯一允许抢注意力的，
    /// 但也只抢一下——粘滞的品红本身已经足够显眼，闪个不停就成了骚扰。
    private func pulseDot() {
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [1, 0.2, 1, 0.2, 1]
        pulse.keyTimes = [0, 0.25, 0.5, 0.75, 1]
        pulse.duration = ShellStyle.statusDonePulseDuration
        pulse.timingFunction = ShellStyle.easeInOutCubic
        dotView.layer?.add(pulse, forKey: Self.dotPulseKey)
    }

    // MARK: - 点击 / 拖拽

    /// 顶行 pane 的 header 与 titlebar 区重叠。titlebar 区的窗口拖动由窗口服务器
    /// 侧执行，既不理会 content 视图的 mouseDownCanMoveWindow，也不理会 mouseDown
    /// 之后才改的 isMovable（两者均实测无效）——窗口会跟着光标位移，光标相对窗口
    /// 静止，pane 拖拽的落点永远停在源 pane 上。服务器在 mouseDown 派发时刻读取
    /// isMovable，所以闸必须提前拉：hover 进 header 就置 false，离开恢复。
    /// 窗口其余区域（titlebar 空白、侧栏上方）的拖动行为不受影响。
    override var mouseDownCanMoveWindow: Bool { false }

    /// 胶囊/空白都属于可拖 header；hover 态的关闭钮保留自己的点击语义。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // hover 态的 ✕（隐藏时 hitTest 天然不会命中它）
        if !closeButton.isHidden,
            hit === closeButton || hit.isDescendant(of: closeButton) {
            return hit
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        // event-tracking loop 内区分 click 与 drag：拖动超过 3pt 启动拖拽 session；
        // 普通点击在 mouseUp 时按落点分流——任务区 = 任务选择器，胶囊其余 = 展开身份面板，
        // 胶囊外 = 只选中 pane。
        let origin = event.locationInWindow
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
        while let next = NSApp.nextEvent(
            matching: mask,
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            switch next.type {
            case .leftMouseDragged:
                let dx = next.locationInWindow.x - origin.x
                let dy = next.locationInWindow.y - origin.y
                guard hypot(dx, dy) >= 3 else { continue }
                beginPaneDrag(with: next)
                return
            case .leftMouseUp:
                onSelect?()
                dispatchTap(atWindowPoint: next.locationInWindow)
                return
            default:
                continue
            }
        }
    }

    /// 点击落点分流。独立出来，测试不必合成一轮 event-tracking 循环。
    func dispatchTap(atWindowPoint point: NSPoint) {
        if taskChip.bounds.contains(taskChip.convert(point, from: nil)) {
            onTaskChipTapped?()
        } else if capsule.bounds.contains(capsule.convert(point, from: nil)) {
            onIdentityTapped?()
        }
    }

    /// 任务区在胶囊坐标系里的位置和位图，交给灵动岛做淡出。
    func taskChipSnapshot() -> (image: NSImage, frame: NSRect)? {
        taskChip.snapshot().map { ($0, taskChip.frame) }
    }

    /// 测试用：任务区中心的窗口坐标与当前文案。
    var taskChipCenterInWindow: NSPoint { taskChip.convert(NSPoint(x: taskChip.bounds.midX, y: taskChip.bounds.midY), to: nil) }
    var taskChipText: String { taskChip.label.stringValue }

    override func mouseDragged(with event: NSEvent) {
        beginPaneDrag(with: event)
    }

    private func beginPaneDrag(with event: NSEvent) {
        guard !isDraggingPane, let dragIdentifier else { return }

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(dragIdentifier.uuidString, forType: .lighttyPaneID)
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let preview = dragPreviewProvider?() ?? fallbackDragPreview()
        let location = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(
            NSRect(
                x: location.x - preview.size.width / 2,
                y: location.y - preview.size.height / 2,
                width: preview.size.width,
                height: preview.size.height),
            contents: preview)

        isDraggingPane = true
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        return context == .withinApplication ? .move : []
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        isDraggingPane = false
        // 拖拽期间跳过了 mouseExited 的放闸；此刻按光标真实位置归位——
        // 仍悬在本 header 上就保持锁定（随后拖拽仍需闸是关的）。
        if let window {
            let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            window.isMovable = !bounds.contains(local)
        }
        onDragEnded?()
    }

    private func fallbackDragPreview() -> NSImage {
        let size = NSSize(width: 156, height: 36)
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
        GhosttyRuntime.shared.configValues.backgroundColor
            .withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        NSAttributedString(
            string: title,
            attributes: [
                .font: ShellStyle.Font.compactTitle,
                .foregroundColor: GhosttyRuntime.shared.configValues.foregroundColor,
            ]
        ).draw(in: rect.insetBy(dx: 12, dy: 10))
        image.unlockFocus()
        return image
    }

    @objc private func closeTapped() { onCloseRequested?() }
}
