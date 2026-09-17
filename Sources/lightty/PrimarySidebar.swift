import AppKit

enum PrimarySidebarMode: String, Codable, CaseIterable {
    case handoff, sessions
    var title: String { self == .handoff ? "Handoff" : "Sessions" }
    var hint: String {
        self == .handoff ? L("Save task progress for an agent to pick up.")
            : L("Browse and continue local Agent sessions.")
    }
}

/// 第一侧栏卡片的可拖宽度：默认宽即最大宽，最小压到它的 2/3；
/// 头部三钮、模式切换带与列表行都按卡片实际宽度铺开。
enum PrimarySidebarSizing {
    static let range = SidebarWidthRange(
        minimum: (ShellStyle.taskPanelWidth * 2 / 3).rounded(), maximum: ShellStyle.taskPanelWidth)
}

enum PrimarySidebarWidthPreference {
    static let defaultsKey = "lightty.primarySidebar.width"
    /// 默认铺到最大宽（即历史上的固定宽）。
    static let preference = SidebarWidthPreference(
        defaultsKey: defaultsKey, range: PrimarySidebarSizing.range, fallback: PrimarySidebarSizing.range.maximum)

    static func width(in defaults: PreferenceStorage = FilePreferences.shared) -> CGFloat {
        preference.width(in: defaults)
    }

    static func setWidth(_ width: CGFloat, in defaults: PreferenceStorage = FilePreferences.shared) {
        preference.setWidth(width, in: defaults)
    }
}

/// Stable panel chrome; mode contents present shared app models and own only their UI state.
/// 右边线可调宽，越过最小宽度继续左拖则关闭（与第二侧栏同一手势）。
final class PrimarySidebar: NSView {
    var onRequestClose: (() -> Void)?
    var onModeChanged: ((PrimarySidebarMode) -> Void)?
    var onResizeBegan: (() -> Void)?
    var onWidthChange: ((CGFloat) -> Void)?
    var onResizeEnded: (() -> Void)?
    private(set) var mode: PrimarySidebarMode
    private let modeSwitch = ModeSwitch()
    private let host = NSView()
    private let handoff = HandoffSidebarContent()
    private lazy var sessions = SessionsSidebarContent(library: library)
    private let library: SessionLibrary
    private let search = ShellIconButton(symbol: ShellSymbol.search, accessibilityLabel: L("Search"), target: nil, action: nil)
    private let create = ShellIconButton(symbol: ShellSymbol.create, accessibilityLabel: L("New task"), target: nil, action: nil)
    private let collapse = ShellIconButton(symbol: ShellSymbol.sidebar, accessibilityLabel: L("Primary sidebar"), target: nil, action: nil)
    private let dragStrip = EdgeDragStrip(range: PrimarySidebarSizing.range)

    init(headerCenterY: CGFloat, mode: PrimarySidebarMode, library: SessionLibrary) {
        self.mode = mode
        self.library = library
        super.init(frame: .zero)
        wantsLayer = true
        modeSwitch.onSelect = { [weak self] value in self?.selectMode(value) }
        search.target = self; search.action = #selector(searchContent)
        create.target = self; create.action = #selector(newTask)
        collapse.target = self; collapse.action = #selector(closePanel)
        dragStrip.onDragClose = { [weak self] in self?.onRequestClose?() }
        dragStrip.onResizeBegan = { [weak self] in self?.onResizeBegan?() }
        dragStrip.onWidthChange = { [weak self] width in self?.onWidthChange?(width) }
        dragStrip.onResizeEnded = { [weak self] in self?.onResizeEnded?() }
        for view in [modeSwitch, host, search, create, collapse, dragStrip] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            collapse.centerYAnchor.constraint(equalTo: topAnchor, constant: headerCenterY),
            collapse.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ShellStyle.sidebarHorizontalInset),
            collapse.widthAnchor.constraint(equalToConstant: ShellStyle.chromeRowHeight), collapse.heightAnchor.constraint(equalToConstant: ShellStyle.chromeRowHeight),
            create.centerYAnchor.constraint(equalTo: collapse.centerYAnchor),
            create.trailingAnchor.constraint(equalTo: collapse.leadingAnchor, constant: -ShellStyle.inlineGap),
            create.widthAnchor.constraint(equalToConstant: ShellStyle.chromeRowHeight), create.heightAnchor.constraint(equalToConstant: ShellStyle.chromeRowHeight),
            search.centerYAnchor.constraint(equalTo: collapse.centerYAnchor),
            search.trailingAnchor.constraint(equalTo: create.leadingAnchor, constant: -ShellStyle.inlineGap),
            search.widthAnchor.constraint(equalToConstant: ShellStyle.chromeRowHeight), search.heightAnchor.constraint(equalToConstant: ShellStyle.chromeRowHeight),
            modeSwitch.topAnchor.constraint(equalTo: collapse.bottomAnchor, constant: ShellStyle.chromeGap),
            modeSwitch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SidebarListScrollView.leadingMargin + 2),
            modeSwitch.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(SidebarListScrollView.trailingMargin + SidebarListScrollView.railWidth + 2)),
            modeSwitch.heightAnchor.constraint(equalToConstant: ModeSwitch.height),
            host.topAnchor.constraint(equalTo: modeSwitch.bottomAnchor, constant: ShellStyle.SidebarHeader.listGap),
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
            // 拖动条从模式切换带起：头部行右端是收起钮，不让它抢点击。
            dragStrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            dragStrip.topAnchor.constraint(equalTo: modeSwitch.topAnchor),
            dragStrip.bottomAnchor.constraint(equalTo: bottomAnchor),
            dragStrip.widthAnchor.constraint(equalToConstant: 14),
        ])
        applyMode()
    }
    required init?(coder: NSCoder) { fatalError() }

    func selectMode(_ value: PrimarySidebarMode, animated: Bool = true) {
        guard value != mode else { return }
        ShellMenuPopover.dismiss()
        LaunchComposer.dismiss()
        mode = value
        applyMode(animated: animated)
        onModeChanged?(value)
    }

    private func applyMode(animated: Bool = true) {
        modeSwitch.select(mode, animated: animated)
        create.isHidden = false
        create.setAccessibilityLabel(mode == .handoff ? L("New task") : L("New session"))
        create.toolTip = mode == .handoff ? L("New task") : L("New session")
        for view in host.subviews { view.isHidden = true }
        let content: NSView = mode == .handoff ? handoff : sessions
        if content.superview == nil {
            content.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                content.topAnchor.constraint(equalTo: host.topAnchor),
                content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
        }
        content.isHidden = false
        if mode == .sessions { sessions.activate() }
    }

    @objc private func searchContent() {
        (window?.windowController as? TerminalWindowController)?.toggleSearchPalette()
    }
    /// 两种模式的「新建」走同一个启动浮层，只是初值不同：会话模式不挂任务，
    /// 任务模式在浮层里填名字与初始正文。以前会话模式是一个两项的菜单，
    /// 那个形状装不下工作目录，于是新会话只能落在当前终端的目录里。
    @objc private func newTask() {
        guard let controller = window?.windowController as? TerminalWindowController else { return }
        LaunchComposer.begin(mode == .handoff ? .newTask : .session,
                             from: create, in: controller, preferredEdge: .maxY)
    }
    @objc private func closePanel() { onRequestClose?() }
    override func cancelOperation(_ sender: Any?) { onRequestClose?() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.cornerRadius = ShellStyle.panelCornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        self.shadow = shadow
        applyColors()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }
    private func applyColors() {
        layer?.backgroundColor = ShellStyle.raisedSurface.shellResolvedCGColor(for: effectiveAppearance)
        layer?.borderColor = ShellStyle.divider.shellResolvedCGColor(for: effectiveAppearance)
    }
}

/// 两段式模式切换：灰底圆角轨道，当前模式的一段铺白色滑块，点另一段即切换。
final class ModeSwitch: NSView {
    static let height: CGFloat = ShellStyle.SidebarHeader.height
    private static let inset: CGFloat = 3
    var onSelect: ((PrimarySidebarMode) -> Void)?
    private(set) var selected: PrimarySidebarMode = .handoff
    private let knob = NSView()
    private(set) var segments: [NSButton] = []

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        knob.wantsLayer = true
        knob.layer?.cornerRadius = 7
        knob.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.10)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            return shadow
        }()
        addSubview(knob)
        segments = PrimarySidebarMode.allCases.map { value in
            let button = NSButton()
            button.isBordered = false
            button.focusRingType = .exterior
            button.lineBreakMode = .byTruncatingTail
            button.target = self
            button.action = #selector(segmentClicked(_:))
            button.toolTip = value.hint
            button.setAccessibilityRole(.radioButton)
            HoverCursor.installPointingHand(on: button)
            addSubview(button)
            return button
        }
        setAccessibilityRole(.radioGroup)
        applyState()
    }
    required init?(coder: NSCoder) { fatalError() }

    func select(_ value: PrimarySidebarMode, animated: Bool = true) {
        guard value != selected else { return }
        selected = value
        applyState()
        guard animated, window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            knob.frame = segmentFrame(selectedIndex)
            needsLayout = true
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = ShellStyle.animationDuration
            context.timingFunction = ShellStyle.easeInOutCubic
            knob.animator().frame = segmentFrame(selectedIndex)
        }
    }

    private var selectedIndex: Int { PrimarySidebarMode.allCases.firstIndex(of: selected) ?? 0 }

    private func segmentFrame(_ index: Int) -> NSRect {
        let inner = bounds.insetBy(dx: Self.inset, dy: Self.inset)
        let width = inner.width / CGFloat(max(segments.count, 1))
        return NSRect(x: inner.minX + width * CGFloat(index), y: inner.minY, width: width, height: inner.height)
    }

    override func layout() {
        super.layout()
        for (index, button) in segments.enumerated() { button.frame = segmentFrame(index) }
        knob.frame = segmentFrame(selectedIndex)
    }

    @objc private func segmentClicked(_ sender: NSButton) {
        guard let index = segments.firstIndex(of: sender) else { return }
        onSelect?(PrimarySidebarMode.allCases[index])
    }

    private func applyState() {
        for (value, button) in zip(PrimarySidebarMode.allCases, segments) {
            let active = value == selected
            button.attributedTitle = NSAttributedString(string: value.title, attributes: [
                .font: active ? ShellStyle.Font.selectedMode : ShellStyle.Font.mode,
                .foregroundColor: active ? ShellStyle.primaryText : ShellStyle.secondaryText,
                .paragraphStyle: { let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byTruncatingTail; return style }(),
            ])
            button.state = active ? .on : .off
            button.setAccessibilityValue(active)
            button.setAccessibilityLabel(value.title)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }
    private func applyColors() {
        layer?.backgroundColor = ShellStyle.segmentTrack.shellResolvedCGColor(for: effectiveAppearance)
        knob.layer?.backgroundColor = ShellStyle.segmentKnob.shellResolvedCGColor(for: effectiveAppearance)
    }
}
