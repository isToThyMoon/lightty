import AppKit

/// 壳层自绘的下拉选择：当前值 + 上下箭头的胶囊按钮，点开是 ShellMenuPopover。
/// 不用 NSPopUpButton——原生控件的选中高亮走系统强调色，脱离 ShellStyle 的调色板。
/// 宽度只随当前文字，右对齐放在设置行尾。
final class ShellDropdown: NSView {
    struct Option: Equatable {
        let id: String
        let title: String
        /// 菜单行首的色点（可选）
        var swatch: NSColor? = nil
    }

    var options: [Option] { didSet { refreshTitle() } }
    var selectedID: String? { didSet { refreshTitle() } }
    var onChange: ((String) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { applyLook() } }

    init(options: [Option], selectedID: String?) {
        self.options = options
        self.selectedID = selectedID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        HoverCursor.installPointingHand(on: self)

        label.font = .systemFont(ofSize: 12.5)
        label.lineBreakMode = .byTruncatingTail
        chevron.image = NSImage(
            systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        for v in [label, chevron] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 26),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        refreshTitle()
        applyLook()
    }

    required init?(coder: NSCoder) { fatalError() }

    var selectedTitle: String {
        options.first { $0.id == selectedID }?.title ?? ""
    }

    private func refreshTitle() {
        label.stringValue = selectedTitle
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(label.intrinsicContentSize.width) + 10 + 6 + 12 + 8, height: 26)
    }

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

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseDown(with event: NSEvent) {
        let items = options.map { option in
            ShellMenuPopover.Item.action(
                option.title, checked: option.id == selectedID, swatch: option.swatch
            ) { [weak self] in self?.select(option.id) }
        }
        ShellMenuPopover.present(from: self, items: items)
    }

    func select(_ id: String) {
        guard id != selectedID, options.contains(where: { $0.id == id }) else { return }
        selectedID = id
        onChange?(id)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLook()
    }

    private func applyLook() {
        let fill: NSColor = hovered ? ShellStyle.pressedFill : ShellStyle.controlFill
        layer?.backgroundColor = fill.shellResolvedCGColor(for: effectiveAppearance)
        label.textColor = ShellStyle.primaryText
        chevron.contentTintColor = ShellStyle.secondaryText
    }
}

/// 壳层自绘的开关：开启态用 ShellStyle.accent，关闭态用中性底，滑块带过渡。
/// 不用 NSSwitch——同样是为了把「开启」的颜色收进全局重点色。
final class ShellToggle: NSView {
    static let size = NSSize(width: 34, height: 20)

    var isOn: Bool {
        didSet { applyLook(animated: true) }
    }
    var onChange: ((Bool) -> Void)?

    private let knob = NSView()

    init(isOn: Bool) {
        self.isOn = isOn
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.cornerRadius = Self.size.height / 2
        HoverCursor.installPointingHand(on: self)
        knob.wantsLayer = true
        knob.layer?.cornerRadius = 8
        knob.frame = knobFrame(on: isOn)
        addSubview(knob)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height),
        ])
        applyLook(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { Self.size }

    private func knobFrame(on: Bool) -> NSRect {
        NSRect(x: on ? Self.size.width - 18 : 2, y: 2, width: 16, height: 16)
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        isOn.toggle()
        onChange?(isOn)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLook(animated: false)
    }

    private func applyLook(animated: Bool) {
        let appearance = effectiveAppearance
        let track: NSColor = isOn ? ShellStyle.accent : ShellStyle.pressedFill
        let knobColor = NSColor.white
        let target = knobFrame(on: isOn)
        let apply = {
            self.layer?.backgroundColor = track.shellResolvedCGColor(for: appearance)
            self.knob.layer?.backgroundColor = knobColor.shellResolvedCGColor(for: appearance)
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = ShellStyle.easeInOutCubic
                knob.animator().frame = target
            }
        } else {
            knob.frame = target
        }
        apply()
    }

    // MARK: - 辅助功能

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilityValue() -> Any? { isOn ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool {
        isOn.toggle()
        onChange?(isOn)
        return true
    }
}
