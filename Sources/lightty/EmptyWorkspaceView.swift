import AppKit

/// 全部工作区关闭后的空态。lightty 以 task 为核心：关掉最后一个工作区不退出
/// 软件，而是回到这个空态——提示从任务侧栏派发，或直接建一个新工作区。
final class EmptyWorkspaceView: NSView {
    /// 点“新建工作区”按钮。
    var onNewWorkspace: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        applyBackground()

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: "rectangle.on.rectangle.angled",
            accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 42, weight: .regular))
        icon.contentTintColor = ShellStyle.tertiaryText

        let title = NSTextField(labelWithString: L("No workspace open"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = ShellStyle.primaryText
        title.alignment = .center

        let subtitle = NSTextField(
            wrappingLabelWithString:
                L("Open a task from the sidebar, or create a new workspace."))
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = ShellStyle.secondaryText
        subtitle.alignment = .center
        subtitle.isSelectable = false
        subtitle.maximumNumberOfLines = 2
        subtitle.preferredMaxLayoutWidth = 240

        let button = ShellTextButton(
            L("New workspace"), emphasis: .primary, target: self,
            action: #selector(newWorkspaceTapped))

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
            subtitle.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 铺一层终端底色（含 background-opacity）：空态才不会露出桌面，观感和
    /// 一个空终端 pane 一致，而不是一个透明的窟窿。
    private func applyBackground() {
        let cfg = GhosttyRuntime.shared.configValues
        layer?.backgroundColor = cfg.backgroundColor
            .withAlphaComponent(cfg.backgroundOpacity).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackground()
    }

    @objc private func newWorkspaceTapped() { onNewWorkspace?() }
}
