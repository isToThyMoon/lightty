import AppKit

/// 每 pane 一条 24pt 细 header：状态点 + 任务名 + 收工/注入按钮，双击改名。
/// 它紧贴 terminal surface，底色/文字仍取 Ghostty config 的
/// background/foreground + background-opacity；应用标题栏/侧栏则使用独立 ShellStyle。
/// ⚠️ 必须 clipsToBounds：layer 化后自绘内容会落在超出 bounds 的 ContentLayer 上，
/// 半透明底色会整张盖住终端（docs/libghostty-embedding.md 透明排查实录）。
final class PaneHeaderView: NSView, NSTextFieldDelegate, NSDraggingSource {
    static let height: CGFloat = 24

    enum Dot: Equatable {
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
    /// 单击/开始拖动 header 时把该 pane 设为 active。
    var onSelect: (() -> Void)?
    var onDragEnded: (() -> Void)?
    /// Ghostty SurfaceDragSource 的轻量 AppKit 对应：UUID 只用于进程内定位现有 pane。
    var dragIdentifier: UUID?
    var dragPreviewProvider: (() -> NSImage?)?

    private var isDraggingPane = false

    private let dotView = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let nameEditor = NSTextField()
    private let finishButton = ShellTextButton(
        "收工", palette: .terminal, target: nil, action: nil)
    private let injectButton = ShellTextButton(
        "注入", palette: .terminal, target: nil, action: nil)

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

        finishButton.target = self
        finishButton.action = #selector(finishTapped)
        injectButton.target = self
        injectButton.action = #selector(injectTapped)

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
            finishButton.heightAnchor.constraint(equalToConstant: 20),
            injectButton.trailingAnchor.constraint(equalTo: finishButton.leadingAnchor, constant: -4),
            injectButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            injectButton.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// label/dot/空白都属于可拖 header；编辑器与动作按钮保留自己的点击语义。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === nameEditor || hit.isDescendant(of: nameEditor)
            || hit === finishButton || hit.isDescendant(of: finishButton)
            || hit === injectButton || hit.isDescendant(of: injectButton) {
            return hit
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            beginRename()
            return
        }

        // NSHostingView 中 vendor 可直接收到 mouseDragged；纯 AppKit header 还会遇到
        // first-responder/子控件重定向，因此在 mouseDown 的 event-tracking loop 内
        // 明确区分 click 与 drag。拖动超过 3pt 才启动 session，普通点击仍在 mouseUp
        // 时选择 pane。
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
        guard !isDraggingPane, nameEditor.isHidden,
              let dragIdentifier else { return }

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
