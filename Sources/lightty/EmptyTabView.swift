import AppKit

/// 全部标签页关闭后的空态。lightty 以 task 为核心：关掉最后一个标签页不退出
/// 软件，而是回到这个空态——提示从任务侧栏派发，或直接建一个新标签页。
final class EmptyTabView: NSView {
    /// 点“新建标签页”按钮。
    var onNewTab: (() -> Void)?
    private var configObserver: NSObjectProtocol?
    private var terminalConfigValues: GhosttyConfigValues

    init() {
        terminalConfigValues = GhosttyRuntime.shared.configValues
        super.init(frame: .zero)
        wantsLayer = true
        applyBackground()

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: "rectangle.on.rectangle.angled",
            accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 42, weight: .regular))
        icon.contentTintColor = ShellStyle.tertiaryText

        let title = NSTextField(labelWithString: L("No tab open"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = ShellStyle.primaryText
        title.alignment = .center

        let subtitle = NSTextField(
            labelWithString:
                L("Open a task from the sidebar, or create a new tab."))
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = ShellStyle.secondaryText
        subtitle.alignment = .center
        subtitle.isSelectable = false
        subtitle.maximumNumberOfLines = 1

        let button = ShellTextButton(
            L("New tab"), emphasis: .primary, target: self,
            action: #selector(newTabTapped))

        let stack = NSStackView(views: [icon, title, subtitle, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(16, after: icon)
        stack.setCustomSpacing(18, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            // 略高于几何中心：视觉重心更稳，也避开可能盖住的浮层
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
            button.heightAnchor.constraint(equalToConstant: 28),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
        configObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyGlobalConfigDidChange,
            object: GhosttyRuntime.shared,
            queue: .main
        ) { [weak self] note in
            guard let values = note.userInfo?[GhosttyConfigNotification.valuesKey]
                    as? GhosttyConfigValues else { return }
            self?.terminalConfigValues = values
            self?.applyTheme(values)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    /// 铺一层终端底色（含 background-opacity）：空态才不会露出桌面，观感和
    /// 一个空终端 pane 一致，而不是一个透明的窟窿。
    private func applyBackground() {
        applyTheme(terminalConfigValues)
    }

    /// Empty-tab chrome sits on the terminal surface, so its semantic light/dark appearance
    /// follows the terminal background rather than the surrounding application shell.
    private func applyTheme(_ values: GhosttyConfigValues) {
        let name: NSAppearance.Name = values.backgroundColor.isLightColor ? .aqua : .darkAqua
        if appearance?.name != name { appearance = NSAppearance(named: name) }
        layer?.backgroundColor = values.backgroundColor
            .withAlphaComponent(values.backgroundOpacity).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackground()
    }

    @objc private func newTabTapped() { onNewTab?() }
}
