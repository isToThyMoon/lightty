import AppKit
import GhosttyKit
import LighttyCore

/// 每 pane 一条 24pt 细 header：身份胶囊（状态点 + pane 名 [+ 任务名]）。
/// 胶囊是唯一常驻身份对象（灵动岛式）：点击向下展开
/// PaneIdentityPanel 编辑 pane 名 / 查看与操作任务；宽度富余时任务名以次要色
/// 并入胶囊，窄时只剩点 + pane 名，信息由展开面板承载。
/// 它紧贴 terminal surface，底色/文字仍取 Ghostty config 的
/// background/foreground + background-opacity；应用标题栏/侧栏则使用独立 ShellStyle。
/// ⚠️ 必须 clipsToBounds：layer 化后自绘内容会落在超出 bounds 的 ContentLayer 上，
/// 半透明底色会整张盖住终端（docs/libghostty-embedding.md 透明排查实录）。
final class PaneHeaderView: NSView, NSDraggingSource {
    static let height: CGFloat = ShellStyle.chromeRowHeight

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
    private let taskHintLabel = NSTextField(labelWithString: "")
    private var capsuleTracking: NSTrackingArea?
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

    /// 面板展开期间胶囊隐身。瞬时切换、不淡出：面板第一行与胶囊逐像素同构，
    /// 交接瞬间标题原地不动（灵动岛的"岛体扩展、内容不动"）。
    func setCapsuleHidden(_ hidden: Bool) {
        capsule.alphaValue = hidden ? 0 : 1
        capsuleIsHidden = hidden
        // 这一句被调用时面板刚挂上窗口（PaneView 的展开顺序：refresh → addSubview →
        // setCapsuleHidden），正好是把状态色补给灵动岛的时机——PaneView 的
        // refresh(panel:) 传的是静态绑定色，不知道状态。
        if hidden { syncIdentityPanelDot() }
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

    /// 绑定任务名；nil = 未绑定。宽度富余时以「 · 任务名」并入胶囊。
    func setTaskName(_ name: String?) {
        boundTaskName = name
        updateTaskHint()
    }

    private var boundTaskName: String?
    var titleOfBoundTask: String? { boundTaskName }

    /// core 通过 CONFIG_CHANGE / COLOR_CHANGE 报告的当前 terminal 颜色；
    /// 启动值来自全局 config。
    private var terminalBackground: NSColor
    private(set) var terminalForeground: NSColor

    init() {
        let cfg = GhosttyRuntime.shared.configValues
        terminalBackground = cfg.backgroundColor
        terminalForeground = cfg.foregroundColor
        super.init(frame: .zero)
        clipsToBounds = true
        wantsLayer = true

        capsule.wantsLayer = true
        capsule.layer?.cornerRadius = 6

        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 3.5
        applyDotColor()

        nameLabel.font = .systemFont(ofSize: 11, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail

        taskHintLabel.font = .systemFont(ofSize: 10.5)
        taskHintLabel.lineBreakMode = .byTruncatingTail
        taskHintLabel.setContentCompressionResistancePriority(
            .defaultLow, for: .horizontal)

        closeButton.image = NSImage(
            systemSymbolName: "xmark", accessibilityDescription: L("Close pane"))?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.focusRingType = .none
        closeButton.isHidden = true
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.toolTip = L("Close pane")

        applyTerminalColors()

        addSubview(capsule)
        for v in [dotView, closeButton, nameLabel, taskHintLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            capsule.addSubview(v)
        }
        capsule.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),

            // full-size terminal 会延伸到原生标题栏下；工作区侧栏收起时，左贴的
            // 身份胶囊会被红黄绿与侧栏开关盖住。按各 pane 自身居中后不再依赖
            // 窗口左侧安全区，多分屏也各自保持一致的视觉轴。
            capsule.centerXAnchor.constraint(equalTo: centerXAnchor),
            capsule.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
            capsule.centerYAnchor.constraint(equalTo: centerYAnchor),
            capsule.heightAnchor.constraint(equalToConstant: 20),
            capsule.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -4),

            dotView.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: 6),
            dotView.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 7),
            dotView.heightAnchor.constraint(equalToConstant: 7),

            // 与圆点同心、命中区放大到 16pt；不参与水平链，布局零位移
            closeButton.centerXAnchor.constraint(equalTo: dotView.centerXAnchor),
            closeButton.centerYAnchor.constraint(equalTo: dotView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),

            taskHintLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            taskHintLabel.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
            taskHintLabel.trailingAnchor.constraint(
                equalTo: capsule.trailingAnchor, constant: -7),
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
        if window != nil { pullStatus() }
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

    /// 任务名 hint 的完整宽度（并入胶囊时的需求），layout 判定用。
    private var fullHintWidth: CGFloat = 0

    /// 任务名 hint：宽度富余时以次要色并入胶囊；窄时 layout 置空收回
    /// （隐藏 label 仍参与约束会把胶囊撑宽，必须置空文本）。
    private func updateTaskHint() {
        let text = boundTaskName.map { " · \($0)" } ?? ""
        fullHintWidth = text.isEmpty ? 0 : ceil(
            (text as NSString).size(withAttributes: [
                .font: taskHintLabel.font ?? NSFont.systemFont(ofSize: 10.5),
            ]).width)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0 else { return }
        // 胶囊完整需求宽度 vs 可用宽度：不够时先收任务 hint（pane 名常显）。
        let chrome: CGFloat = 6 + 7 + 6 + 7 // 胶囊内边距 + 点 + 间距
        let nameWidth = ceil(nameLabel.intrinsicContentSize.width)
        let available = bounds.width - 8
        let fits = chrome + nameWidth + fullHintWidth <= available
        let want = (fits && boundTaskName != nil)
            ? " · \(boundTaskName ?? "")" : ""
        if taskHintLabel.stringValue != want {
            taskHintLabel.stringValue = want
        }
        syncAttentionRingFrame()
    }

    private func applyCapsuleFill() {
        capsule.layer?.backgroundColor = terminalForeground
            .withAlphaComponent(capsuleHovered ? 0.10 : 0.05).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let capsuleTracking { removeTrackingArea(capsuleTracking) }
        let area = NSTrackingArea(
            rect: convert(capsule.frame, from: capsule.superview),
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self)
        addTrackingArea(area)
        capsuleTracking = area
    }

    override func mouseEntered(with event: NSEvent) { capsuleHovered = true }
    override func mouseExited(with event: NSEvent) { capsuleHovered = false }

    // MARK: - 颜色

    private func applyTerminalColors() {
        let opacity = GhosttyRuntime.shared.configValues.backgroundOpacity
        layer?.backgroundColor = terminalBackground
            .withAlphaComponent(opacity).cgColor
        nameLabel.textColor = terminalForeground
        taskHintLabel.textColor = terminalForeground.withAlphaComponent(0.55)
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

    private static let dotBreatheKey = "statusBreathe"
    private static let dotPulseKey = "statusPulse"

    private var status: PaneStatus?
    /// `.done` 落地时如果 pane 不可见，闪烁就白放了——记下来，等可见了补上。
    private var pendingDonePulse = false

    /// 由 `PaneStatusPresenter` 推入。
    ///
    /// pane 自己不订阅通知：状态源是全局的一发广播，每个 pane 挂一个观察者
    /// 只是把同一次广播摊成 N 次派发，还得在 PaneView 里加订阅代码。
    func apply(_ status: PaneStatus?) {
        // 高频入口（PreToolUse/PostToolUse 一次工具调用就来两发），先挡住无变化的
        let changed = status?.state != self.status?.state
            || status?.tool != self.status?.tool
            || status?.detail != self.status?.detail
        guard changed else { return }
        let enteredDone = status?.state == .done && self.status?.state != .done
        self.status = status

        applyDotColor()
        applyCloseButtonTint()
        updateStatusTooltip()

        // `.attention` 直接复用现成的呼吸环（唯一一处「非人不可」的状态，
        // 值得动用胶囊级的提示；其余状态一律只在圆点里表达）
        if status?.state == .attention {
            beginCapsuleAttention()
        } else {
            endCapsuleAttention()
        }

        // 转出 done（focus 后 markRead）时把欠着的闪烁一并作废——
        // 否则它会晚一步落在一个已经不是 done 的圆点上
        pendingDonePulse = enteredDone || (pendingDonePulse && status?.state == .done)
        updateAmbientAnimations()
        syncIdentityPanelDot()
    }

    /// pane 是新建的、或从别的窗口拖过来的：主动向 store 拉一次当前值。
    /// 这是拉不是订阅——presenter 不知道 pane 什么时候诞生，而 store 一直知道。
    private func pullStatus() {
        guard let dragIdentifier else { return }
        apply(PaneStatusStore.shared.status(for: dragIdentifier))
    }

    private var activity: PaneActivity? { status?.state }

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
    /// 胶囊里唯一有弹性的槽位是任务名 hint，`layout()` 的宽度仲裁就是围着它写的。
    /// 把工具名塞进去要么和任务名抢那一个槽（`PreToolUse` 的频率下等于让文字
    /// 不停跳变——比呼吸的圆点扎眼得多，正好和「不打扰」相反），要么再加一段
    /// 仲裁逻辑去挤 pane 名。两条都比这点信息量贵，所以走 tooltip。
    private func updateStatusTooltip() {
        guard let status, status.state != .idle else {
            toolTip = nil
            return
        }
        var line: String
        switch status.state {
        case .thinking: line = L("Agent is thinking")
        case .tool: line = status.tool.map { L("Running %@", $0) } ?? L("Agent is working")
        case .attention: line = L("Agent needs your input")
        case .done: line = L("Agent finished")
        case .idle: return
        }
        // detail 来自 hook 写的文件，长度不可信（契约 §4.2 要求读方截断）
        if let detail = status.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
            !detail.isEmpty {
            line += " · " + String(detail.prefix(120))
        }
        toolTip = line
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
            dotView.layer?.removeAnimation(forKey: Self.dotBreatheKey)
            attentionRing?.layer?.removeAnimation(forKey: Self.ringBreatheKey)
            return
        }

        // 0.3↔0.9 / 0.9s 是这个环原本的参数，原样保留（提示气泡的手感已经调过）
        if attentionRing?.layer?.animation(forKey: Self.ringBreatheKey) == nil {
            attentionRing?.layer?.add(
                breathe(from: 0.3, to: 0.9, duration: 0.9), forKey: Self.ringBreatheKey)
        }

        // hover 时圆点整个 isHidden，动画留着也没人看，白烧
        let wantsBreath = !capsuleHovered
            && (activity == .thinking || activity == .tool)
        if wantsBreath {
            // 已经在跑同一个态就别重加：重加会把呼吸相位掐回起点，
            // 而 PostToolUse/PreToolUse 是成对高频来的，会变成一顿抽搐
            if dotView.layer?.animation(forKey: Self.dotBreatheKey) == nil {
                // 0.55 是刻意的下限：低到能看出"在动"，高到不至于像故障闪烁
                dotView.layer?.add(
                    breathe(
                        from: 0.55, to: 1,
                        duration: activity == .tool
                            ? ShellStyle.statusToolBreathDuration
                            : ShellStyle.statusBreathDuration),
                    forKey: Self.dotBreatheKey)
            }
        } else {
            dotView.layer?.removeAnimation(forKey: Self.dotBreatheKey)
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

    /// 灵动岛第一行的圆点与胶囊逐像素同构，颜色也得跟着状态走。
    ///
    /// 面板挂在窗口 contentView 上（不在 pane 子树里），header 拿不到直接引用；
    /// 但「胶囊隐身」正好是「本 header 的面板正开着」的标记，而同一窗口任意时刻
    /// 至多一个面板展开（面板的 dismiss monitor 会在点到别处时收起），据此定位即可，
    /// 不必为这一条信息再从 PaneView 牵一根线过来。
    private func syncIdentityPanelDot() {
        guard capsuleIsHidden, let host = window?.contentView else { return }
        for case let panel as PaneIdentityPanel in host.subviews {
            panel.applyStatusDot(
                (activity == nil || activity == .idle) ? nil : effectiveDotColor)
        }
    }

    // MARK: - 点击 / 拖拽

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
        // 普通点击在 mouseUp 时按落点分流——胶囊内 = 展开身份面板，其余 = 选中 pane。
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
                let point = capsule.convert(next.locationInWindow, from: nil)
                if capsule.bounds.contains(point) {
                    onIdentityTapped?()
                }
                return
            default:
                continue
            }
        }
    }

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
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: GhosttyRuntime.shared.configValues.foregroundColor,
            ]
        ).draw(in: rect.insetBy(dx: 12, dy: 10))
        image.unlockFocus()
        return image
    }

    @objc private func closeTapped() { onCloseRequested?() }
}
