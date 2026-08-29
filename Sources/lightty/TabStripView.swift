import AppKit

/// 自绘 tab 条：宽度与主体 terminal 区域一致（随侧栏推移），只在 ≥2 个 tab 时显示。
/// tab 是 lightty 的窗口内概念（一个 pane 树容器），不是 macOS 原生 tab（那是
/// 多个 NSWindow 结组，tab bar 横跨全窗宽，与"一窗一侧栏"语义冲突，已弃用）。
final class TabStripView: NSView {
    static let height: CGFloat = 34

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNewTab: (() -> Void)?
    /// 双击标签重命名工作区（index, 新名字）。
    var onRename: ((Int, String) -> Void)?

    private let stack = NSStackView()
    private let newTabButton: ShellIconButton

    override init(frame: NSRect) {
        newTabButton = ShellIconButton(
            symbol: "plus", accessibilityLabel: "新建 Tab", target: nil, action: nil)
        super.init(frame: frame)
        wantsLayer = true
        applyBackground()

        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false

        newTabButton.target = self
        newTabButton.action = #selector(newTabTapped)
        newTabButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        addSubview(newTabButton)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 26),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: newTabButton.leadingAnchor, constant: -6),

            newTabButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            newTabButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            newTabButton.widthAnchor.constraint(equalToConstant: 26),
            newTabButton.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private var lastTitles: [String] = []
    private var lastActiveIndex = -1

    func update(titles: [String], activeIndex: Int) {
        // windowDidUpdate 等高频路径会反复调用；内容没变时不能重建
        //（重建会打断 hover 状态和进行中的关闭键点击，表现为闪烁/按钮失灵）。
        guard titles != lastTitles || activeIndex != lastActiveIndex else { return }
        lastTitles = titles
        lastActiveIndex = activeIndex
        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, title) in titles.enumerated() {
            let item = TabItemView(title: title, isActive: index == activeIndex)
            item.onSelect = { [weak self] in self?.onSelect?(index) }
            item.onClose = { [weak self] in self?.onClose?(index) }
            item.onRenameRequest = { [weak self, weak item] in
                guard let self, let item else { return }
                NameEditorPopover.present(
                    from: item, title: "重命名工作区", initial: title, confirmLabel: "重命名"
                ) { [weak self] name in
                    self?.onRename?(index, name)
                }
            }
            item.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
            stack.addArrangedSubview(item)
        }
    }

    @objc private func newTabTapped() { onNewTab?() }

    private func applyBackground() {
        layer?.backgroundColor =
            ShellStyle.titlebarBackground.shellResolvedCGColor(for: effectiveAppearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackground()
    }
}

/// 单个 tab 标签：圆角底 + 标题 + hover 时出现的关闭键。
private final class TabItemView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onRenameRequest: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let closeButton: ShellIconButton
    private let isActive: Bool
    private var isHovered = false { didSet { updateAppearance() } }
    private var tracking: NSTrackingArea?

    init(title: String, isActive: Bool) {
        self.isActive = isActive
        closeButton = ShellIconButton(
            symbol: "xmark", accessibilityLabel: "关闭 Tab", target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = ShellStyle.controlCornerRadius

        label.stringValue = title
        label.font = .systemFont(ofSize: 11.5, weight: isActive ? .semibold : .regular)
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.isHidden = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),

            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),

            widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
        ])
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

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onRenameRequest?()
        } else {
            onSelect?()
        }
    }

    @objc private func closeTapped() { onClose?() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        let fill: NSColor = isActive
            ? ShellStyle.selectionFill
            : (isHovered ? ShellStyle.hoverFill : .clear)
        layer?.backgroundColor = fill.shellResolvedCGColor(for: effectiveAppearance)
        label.textColor = isActive ? ShellStyle.primaryText : ShellStyle.secondaryText
        closeButton.isHidden = !isHovered
    }
}
