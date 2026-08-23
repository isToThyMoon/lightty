import AppKit

/// 每 pane 一条 24pt 细 header：状态点 + 任务名 + 收工/注入按钮，双击改名。
/// 底色/文字取 ghostty config 的 background/foreground + background-opacity（视觉铁律）；
/// 语义状态点（绿/橙/灰）是唯一例外。
/// ⚠️ 必须 clipsToBounds：layer 化后自绘内容会落在超出 bounds 的 ContentLayer 上，
/// 半透明底色会整张盖住终端（docs/libghostty-embedding.md 透明排查实录）。
final class PaneHeaderView: NSView {
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

        nameEditor.font = .systemFont(ofSize: 11)
        nameEditor.isHidden = true
        nameEditor.target = self
        nameEditor.action = #selector(commitRename)

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

            nameEditor.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            nameEditor.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameEditor.widthAnchor.constraint(equalToConstant: 180),

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
        nameEditor.stringValue = title == "未命名" ? "" : title
        nameEditor.isHidden = false
        nameLabel.isHidden = true
        window?.makeFirstResponder(nameEditor)
    }

    @objc private func commitRename() {
        let name = nameEditor.stringValue.trimmingCharacters(in: .whitespaces)
        nameEditor.isHidden = true
        nameLabel.isHidden = false
        guard !name.isEmpty else { return }
        onRename?(name)
    }

    @objc private func finishTapped() { onFinish?() }
    @objc private func injectTapped() { onInject?() }
}
