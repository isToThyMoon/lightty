import AppKit

enum PrimarySidebarMode: String, Codable, CaseIterable {
    case handoff, sessions
    var title: String { self == .handoff ? "Handoff" : "Sessions" }
    var hint: String {
        self == .handoff ? L("Injected when an agent starts, written back as it works.")
            : L("Click to resume your last session.")
    }
}

/// Stable panel chrome; mode contents present shared app models and own only their UI state.
final class PrimarySidebar: NSView {
    var onRequestClose: (() -> Void)?
    var onModeChanged: ((PrimarySidebarMode) -> Void)?
    private(set) var mode: PrimarySidebarMode
    private let modeSwitch = ModeSwitch()
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let host = NSView()
    private let handoff = HandoffSidebarContent()
    private lazy var sessions = SessionsSidebarContent(library: library)
    private let library: SessionLibrary
    private let search = ShellIconButton(symbol: ShellSymbol.search, accessibilityLabel: L("Search"), target: nil, action: nil)
    private let create = ShellIconButton(symbol: ShellSymbol.create, accessibilityLabel: L("New task"), target: nil, action: nil)
    private let collapse = ShellIconButton(symbol: ShellSymbol.sidebar, accessibilityLabel: L("Primary sidebar"), target: nil, action: nil)

    init(headerCenterY: CGFloat, mode: PrimarySidebarMode, library: SessionLibrary) {
        self.mode = mode
        self.library = library
        super.init(frame: .zero)
        wantsLayer = true
        modeSwitch.onSelect = { [weak self] value in self?.selectMode(value) }
        hint.font = ShellStyle.Font.hint
        hint.textColor = ShellStyle.tertiaryText
        hint.isSelectable = false
        search.target = self; search.action = #selector(searchContent)
        create.target = self; create.action = #selector(newTask)
        collapse.target = self; collapse.action = #selector(closePanel)
        for view in [modeSwitch, hint, host, search, create, collapse] {
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
            modeSwitch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ShellStyle.sectionInset),
            modeSwitch.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ShellStyle.sectionInset),
            modeSwitch.heightAnchor.constraint(equalToConstant: ModeSwitch.height),
            hint.topAnchor.constraint(equalTo: modeSwitch.bottomAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: modeSwitch.leadingAnchor, constant: 4),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ShellStyle.sectionInset),
            host.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 14),
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyMode()
    }
    required init?(coder: NSCoder) { fatalError() }

    func selectMode(_ value: PrimarySidebarMode) {
        guard value != mode else { return }
        ShellMenuPopover.dismiss()
        LaunchComposer.dismiss()
        mode = value
        applyMode()
        onModeChanged?(value)
    }

    private func applyMode() {
        modeSwitch.select(mode)
        hint.stringValue = mode.hint
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
    static let height: CGFloat = 32
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
            button.focusRingType = .none
            button.lineBreakMode = .byTruncatingTail
            button.target = self
            button.action = #selector(segmentClicked(_:))
            button.toolTip = value == .handoff ? L("Manage handoff tasks") : L("Continue local CLI sessions")
            button.setAccessibilityRole(.radioButton)
            HoverCursor.installPointingHand(on: button)
            addSubview(button)
            return button
        }
        setAccessibilityRole(.radioGroup)
        applyState()
    }
    required init?(coder: NSCoder) { fatalError() }

    func select(_ value: PrimarySidebarMode) {
        guard value != selected else { return }
        selected = value
        applyState()
        guard window != nil else { return needsLayout = true }
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
