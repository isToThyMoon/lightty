import AppKit

/// 每 pane 一条 24pt 细 header：状态点 + 任务名 + 收工/注入按钮，双击改名。
/// 底色/文字取 ghostty config 的 background/foreground + background-opacity（视觉铁律）；
/// 语义状态点（绿/橙/灰）是唯一例外。
/// ⚠️ 必须 clipsToBounds：layer 化后自绘内容会落在超出 bounds 的 ContentLayer 上，
/// 半透明底色会整张盖住终端（docs/libghostty-embedding.md 透明排查实录）。
final class PaneHeaderView: NSView, NSTextFieldDelegate {
    static let height: CGFloat = 24

    enum Dot {
        case unnamed        // 灰：未命名，仅内存
        case active         // 绿：已绑定任务文件
        case stuck          // 橙

        var color: NSColor {
            switch self {
            case .unnamed: return .systemGray
            case .active: return .systemGreen
            case .stuck: return .systemOrange
            }
        }
    }

    var onRename: ((String) -> Void)?
    var onFinish: (() -> Void)?
    var onInject: (() -> Void)?
    /// 改名编辑结束（提交或取消）后回调，pane 用它把焦点还给终端
    var onEditingEnded: (() -> Void)?

    private let dotView = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let nameEditor = NSTextField()
    private let finishButton = NSButton(title: "收工", target: nil, action: nil)
    private let injectButton = NSButton(title: "注入", target: nil, action: nil)

    var title: String {
        get { nameLabel.stringValue }
        set { nameLabel.stringValue = newValue }
    }

    var dot: Dot = .unnamed {
        didSet { dotView.layer?.backgroundColor = dot.color.cgColor }
    }

    var injectEnabled: Bool {
        get { injectButton.isEnabled }
        set { injectButton.isEnabled = newValue }
    }

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
        wantsLayer = true

        let cfg = GhosttyRuntime.shared.configValues
        layer?.backgroundColor = cfg.backgroundColor
            .withAlphaComponent(cfg.backgroundOpacity).cgColor

        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 3.5
        dotView.layer?.backgroundColor = dot.color.cgColor

        nameLabel.font = .systemFont(ofSize: 11, weight: .medium)
        nameLabel.textColor = cfg.foregroundColor
        nameLabel.lineBreakMode = .byTruncatingTail

        // 编辑器贴 header 样式：无边框、无焦点环，前景色随配置，底色用前景色淡化
        nameEditor.font = nameLabel.font
        nameEditor.isHidden = true
        nameEditor.isBordered = false
        nameEditor.drawsBackground = false
        nameEditor.textColor = cfg.foregroundColor
        nameEditor.focusRingType = .none
        nameEditor.wantsLayer = true
        nameEditor.layer?.backgroundColor = cfg.foregroundColor.withAlphaComponent(0.12).cgColor
        nameEditor.layer?.cornerRadius = 3
        nameEditor.delegate = self
        (nameEditor.cell as? NSTextFieldCell)?.usesSingleLineMode = true

        for (button, action) in [(finishButton, #selector(finishTapped)),
                                 (injectButton, #selector(injectTapped))] {
            button.bezelStyle = .inline
            button.controlSize = .small
            button.font = .systemFont(ofSize: 10)
            button.target = self
            button.action = action
        }

        for v in [dotView, nameLabel, nameEditor, injectButton, finishButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),

            dotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 7),
            dotView.heightAnchor.constraint(equalToConstant: 7),

            nameLabel.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: injectButton.leadingAnchor, constant: -8),

            // 与 label 同字体同 cell 内边距，基线对齐 → 进出编辑态文字零位移
            nameEditor.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            nameEditor.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),
            nameEditor.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            nameEditor.trailingAnchor.constraint(lessThanOrEqualTo: injectButton.leadingAnchor, constant: -8),

            finishButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            finishButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            injectButton.trailingAnchor.constraint(equalTo: finishButton.leadingAnchor, constant: -4),
            injectButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            beginRename()
        } else {
            super.mouseDown(with: event)
        }
    }

    func beginRename() {
        // 占位符延续原 title（半透明前景色）：切入编辑态时文字内容与位置都不跳
        let cfg = GhosttyRuntime.shared.configValues
        nameEditor.placeholderAttributedString = NSAttributedString(
            string: title,
            attributes: [
                .font: nameLabel.font!,
                .foregroundColor: cfg.foregroundColor.withAlphaComponent(0.4),
            ])
        nameEditor.stringValue = title == "未命名" ? "" : title
        nameEditor.isHidden = false
        nameLabel.isHidden = true
        window?.makeFirstResponder(nameEditor)
    }

    /// Enter/失焦提交，Esc 取消（空名视为取消）
    private func endRename(commit: Bool) {
        guard !nameEditor.isHidden else { return }
        nameEditor.isHidden = true
        nameLabel.isHidden = false
        let name = nameEditor.stringValue.trimmingCharacters(in: .whitespaces)
        if commit, !name.isEmpty, name != title {
            onRename?(name)
        }
        onEditingEnded?()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        endRename(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endRename(commit: false)
            return true
        }
        return false
    }

    @objc private func finishTapped() { onFinish?() }
    @objc private func injectTapped() { onInject?() }
}
