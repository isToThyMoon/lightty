import AppKit

enum PrimarySidebarMode: String, Codable, CaseIterable {
    case handoff, sessions
    var title: String { self == .handoff ? L("Handoff tasks") : L("Sessions") }
    var hint: String {
        self == .handoff ? L("Start an agent with a task. Try saying: “Summarize the task.”")
            : L("Click to resume your last session.")
    }
}

/// Stable panel chrome; mode contents own their own data and interactions.
final class PrimarySidebar: NSView {
    var onRequestClose: (() -> Void)?
    var onModeChanged: ((PrimarySidebarMode) -> Void)?
    private(set) var mode: PrimarySidebarMode
    private let titleButton = NSButton()
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let host = NSView()
    private let handoff = HandoffSidebarContent()
    private lazy var sessions = SessionsSidebarContent(library: library)
    private let library: SessionLibrary
    private let search = ShellIconButton(symbol: "magnifyingglass", accessibilityLabel: L("Search"), target: nil, action: nil)
    private let create = ShellIconButton(symbol: "doc.badge.plus", accessibilityLabel: L("New task"), target: nil, action: nil)
    private let collapse = ShellIconButton(symbol: "sidebar.left", accessibilityLabel: L("Primary sidebar"), target: nil, action: nil)

    init(headerCenterY: CGFloat, mode: PrimarySidebarMode, library: SessionLibrary) {
        self.mode = mode
        self.library = library
        super.init(frame: .zero)
        wantsLayer = true
        titleButton.cell = ModeTitleCell(textCell: "")
        titleButton.isBordered = false
        titleButton.font = .systemFont(ofSize: 18, weight: .semibold)
        titleButton.alignment = .left
        titleButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
                .applying(.init(paletteColors: [ShellStyle.primaryText])))
        titleButton.imagePosition = .imageTrailing
        titleButton.target = self
        titleButton.action = #selector(chooseMode)
        HoverCursor.installPointingHand(on: titleButton)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = ShellStyle.tertiaryText
        hint.isSelectable = false
        search.target = self; search.action = #selector(searchContent)
        create.target = self; create.action = #selector(newTask)
        collapse.target = self; collapse.action = #selector(closePanel)
        for view in [titleButton, hint, host, search, create, collapse] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            collapse.centerYAnchor.constraint(equalTo: topAnchor, constant: headerCenterY),
            collapse.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            collapse.widthAnchor.constraint(equalToConstant: 28), collapse.heightAnchor.constraint(equalToConstant: 28),
            create.centerYAnchor.constraint(equalTo: collapse.centerYAnchor),
            create.trailingAnchor.constraint(equalTo: collapse.leadingAnchor, constant: -4),
            create.widthAnchor.constraint(equalToConstant: 28), create.heightAnchor.constraint(equalToConstant: 28),
            search.centerYAnchor.constraint(equalTo: collapse.centerYAnchor),
            search.trailingAnchor.constraint(equalTo: create.leadingAnchor, constant: -4),
            search.widthAnchor.constraint(equalToConstant: 28), search.heightAnchor.constraint(equalToConstant: 28),
            titleButton.topAnchor.constraint(equalTo: collapse.bottomAnchor, constant: 12),
            titleButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            titleButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            titleButton.heightAnchor.constraint(equalToConstant: 34),
            hint.topAnchor.constraint(equalTo: titleButton.bottomAnchor, constant: 4),
            hint.leadingAnchor.constraint(equalTo: titleButton.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
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
        titleButton.title = mode.title
        titleButton.contentTintColor = ShellStyle.primaryText
        titleButton.setAccessibilityLabel(mode.title)
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

    @objc private func chooseMode() {
        ShellMenuPopover.present(from: titleButton, items: PrimarySidebarMode.allCases.map { value in
            .action(value.title, checked: mode == value,
                    subtitle: value == .handoff ? L("Manage handoff tasks") : L("Continue local CLI sessions")) {
                [weak self] in self?.selectMode(value)
            }
        })
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
        layer?.cornerRadius = 16
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

/// Align the chevron optically with the title's capitals, not its text baseline.
private final class ModeTitleCell: NSButtonCell {
    override func drawImage(_ image: NSImage, withFrame frame: NSRect, in controlView: NSView) {
        super.drawImage(image, withFrame: frame.offsetBy(dx: 0, dy: controlView.isFlipped ? -2 : 2), in: controlView)
    }
}
