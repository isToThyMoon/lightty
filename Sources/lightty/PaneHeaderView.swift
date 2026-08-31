import AppKit
import GhosttyKit

/// 每 pane 一条 24pt 细 header：身份胶囊（状态点 + pane 名 [+ 任务名]）+
/// 收工/注入按钮。胶囊是唯一常驻身份对象（灵动岛式）：点击向下展开
/// PaneIdentityPanel 编辑 pane 名 / 查看与操作任务；宽度富余时任务名以次要色
/// 并入胶囊，窄时只剩点 + pane 名，信息由展开面板承载。
/// 它紧贴 terminal surface，底色/文字仍取 Ghostty config 的
/// background/foreground + background-opacity；应用标题栏/侧栏则使用独立 ShellStyle。
/// ⚠️ 必须 clipsToBounds：layer 化后自绘内容会落在超出 bounds 的 ContentLayer 上，
/// 半透明底色会整张盖住终端（docs/libghostty-embedding.md 透明排查实录）。
final class PaneHeaderView: NSView, NSDraggingSource {
    static let height: CGFloat = 24

    enum Dot: Equatable {
        case unnamed        // 灰：未绑定任务
        case active         // 绿：已绑定任务文件

        var color: NSColor {
            switch self {
            case .unnamed: return .systemGray
            case .active: return .systemGreen
            }
        }
    }

    var onFinish: (() -> Void)?
    var onInject: (() -> Void)?
    /// 单击/开始拖动 header 时把该 pane 设为 active。
    var onSelect: (() -> Void)?
    /// 点击身份胶囊：展开/收起 PaneIdentityPanel。
    var onIdentityTapped: (() -> Void)?
    var onDragEnded: (() -> Void)?
    /// Ghostty SurfaceDragSource 的轻量 AppKit 对应：UUID 只用于进程内定位现有 pane。
    var dragIdentifier: UUID?
    var dragPreviewProvider: (() -> NSImage?)?

    private var isDraggingPane = false

    private let capsule = NSView()
    private let dotView = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let taskHintLabel = NSTextField(labelWithString: "")
    // 动词直接用 handoff 术语本身（UI 中 handoff 一律不翻译）：
    // Handoff = 让 agent 写交接文档交出这一棒；Restore = 让 agent 读文档接续。
    private let finishButton = ShellTextButton(
        "Handoff", palette: .terminal, target: nil, action: nil)
    private let injectButton = ShellTextButton(
        "Restore", palette: .terminal, target: nil, action: nil)
    private var capsuleTracking: NSTrackingArea?
    private var capsuleHovered = false {
        didSet { applyCapsuleFill() }
    }

    var title: String {
        get { nameLabel.stringValue }
        set { nameLabel.stringValue = newValue }
    }

    /// 胶囊在 header 坐标系中的 frame（面板形变动画的起点/终点）。
    var capsuleFrame: NSRect { capsule.frame }

    /// 面板展开期间胶囊隐身。瞬时切换、不淡出：面板第一行与胶囊逐像素同构，
    /// 交接瞬间标题原地不动（灵动岛的"岛体扩展、内容不动"）。
    func setCapsuleHidden(_ hidden: Bool) {
        capsule.alphaValue = hidden ? 0 : 1
    }

    var dot: Dot = .unnamed {
        didSet { dotView.layer?.backgroundColor = dot.color.cgColor }
    }

    var injectEnabled: Bool {
        get { injectButton.isEnabled }
        set { injectButton.isEnabled = newValue }
    }

    /// 绑定任务名；nil = 未绑定。宽度富余时以「 · 任务名」并入胶囊。
    func setTaskName(_ name: String?) {
        boundTaskName = name
        updateTaskHint()
    }

    private var boundTaskName: String?
    var titleOfBoundTask: String? { boundTaskName }

    /// core 通过 CONFIG_CHANGE / COLOR_CHANGE 报告的当前 terminal 颜色；
    /// 启动值来自全局 config。
    private var terminalBackground: NSColor
    private(set) var terminalForeground: NSColor

    init() {
        let cfg = GhosttyRuntime.shared.configValues
        terminalBackground = cfg.backgroundColor
        terminalForeground = cfg.foregroundColor
        super.init(frame: .zero)
        clipsToBounds = true
        wantsLayer = true

        capsule.wantsLayer = true
        capsule.layer?.cornerRadius = 6

        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 3.5
        dotView.layer?.backgroundColor = dot.color.cgColor

        nameLabel.font = .systemFont(ofSize: 11, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail

        taskHintLabel.font = .systemFont(ofSize: 10.5)
        taskHintLabel.lineBreakMode = .byTruncatingTail
        taskHintLabel.setContentCompressionResistancePriority(
            .defaultLow, for: .horizontal)

        applyTerminalColors()

        finishButton.target = self
        finishButton.action = #selector(finishTapped)
        injectButton.target = self
        injectButton.action = #selector(injectTapped)

        addSubview(capsule)
        for v in [dotView, nameLabel, taskHintLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            capsule.addSubview(v)
        }
        for v in [capsule, injectButton, finishButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            if v !== capsule { addSubview(v) }
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),

            capsule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            capsule.centerYAnchor.constraint(equalTo: centerYAnchor),
            capsule.heightAnchor.constraint(equalToConstant: 20),
            capsule.trailingAnchor.constraint(
                lessThanOrEqualTo: injectButton.leadingAnchor, constant: -8),

            dotView.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: 6),
            dotView.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 7),
            dotView.heightAnchor.constraint(equalToConstant: 7),

            nameLabel.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),

            taskHintLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            taskHintLabel.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
            taskHintLabel.trailingAnchor.constraint(
                equalTo: capsule.trailingAnchor, constant: -7),

            finishButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            finishButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            finishButton.heightAnchor.constraint(equalToConstant: 20),
            injectButton.trailingAnchor.constraint(equalTo: finishButton.leadingAnchor, constant: -4),
            injectButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            injectButton.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 胶囊内容与 hover

    /// 任务名 hint 的完整宽度（并入胶囊时的需求），layout 判定用。
    private var fullHintWidth: CGFloat = 0

    /// 任务名 hint：宽度富余时以次要色并入胶囊；窄时 layout 置空收回
    /// （隐藏 label 仍参与约束会把胶囊撑宽，必须置空文本）。
    private func updateTaskHint() {
        let text = boundTaskName.map { " · \($0)" } ?? ""
        fullHintWidth = text.isEmpty ? 0 : ceil(
            (text as NSString).size(withAttributes: [
                .font: taskHintLabel.font ?? NSFont.systemFont(ofSize: 10.5),
            ]).width)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard injectButton.frame.minX > 0 else { return }
        // 胶囊完整需求宽度 vs 可用宽度：不够时先收任务 hint（pane 名常显）。
        let chrome: CGFloat = 6 + 7 + 6 + 7 // 胶囊内边距 + 点 + 间距
        let nameWidth = ceil(nameLabel.intrinsicContentSize.width)
        let available = injectButton.frame.minX - 8 - 4
        let fits = chrome + nameWidth + fullHintWidth <= available
        let want = (fits && boundTaskName != nil)
            ? " · \(boundTaskName ?? "")" : ""
        if taskHintLabel.stringValue != want {
            taskHintLabel.stringValue = want
        }
    }

    private func applyCapsuleFill() {
        capsule.layer?.backgroundColor = terminalForeground
            .withAlphaComponent(capsuleHovered ? 0.10 : 0.05).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let capsuleTracking { removeTrackingArea(capsuleTracking) }
        let area = NSTrackingArea(
            rect: convert(capsule.frame, from: capsule.superview),
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self)
        addTrackingArea(area)
        capsuleTracking = area
    }

    override func mouseEntered(with event: NSEvent) { capsuleHovered = true }
    override func mouseExited(with event: NSEvent) { capsuleHovered = false }

    // MARK: - 颜色

    private func applyTerminalColors() {
        let opacity = GhosttyRuntime.shared.configValues.backgroundOpacity
        layer?.backgroundColor = terminalBackground
            .withAlphaComponent(opacity).cgColor
        nameLabel.textColor = terminalForeground
        taskHintLabel.textColor = terminalForeground.withAlphaComponent(0.55)
        applyCapsuleFill()
        finishButton.terminalForeground = terminalForeground
        injectButton.terminalForeground = terminalForeground
    }

    /// per-surface CONFIG_CHANGE（条件主题解析结果）：一次拿到整套前景/背景。
    func applyTerminalTheme(background: NSColor, foreground: NSColor) {
        terminalBackground = background
        terminalForeground = foreground
        applyTerminalColors()
    }

    /// core 报告 per-surface 颜色变化（GHOSTTY_ACTION_COLOR_CHANGE）后由
    /// runtime 转发；header 随 terminal 主题重新着色。
    func noteTerminalColorChange(kind: ghostty_action_color_kind_e, color: NSColor) {
        switch kind {
        case GHOSTTY_ACTION_COLOR_KIND_BACKGROUND: terminalBackground = color
        case GHOSTTY_ACTION_COLOR_KIND_FOREGROUND: terminalForeground = color
        default: return
        }
        applyTerminalColors()
    }

    // MARK: - 点击 / 拖拽

    /// 胶囊/空白都属于可拖 header；动作按钮保留自己的点击语义。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === finishButton || hit.isDescendant(of: finishButton)
            || hit === injectButton || hit.isDescendant(of: injectButton) {
            return hit
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        // event-tracking loop 内区分 click 与 drag：拖动超过 3pt 启动拖拽 session；
        // 普通点击在 mouseUp 时按落点分流——胶囊内 = 展开身份面板，其余 = 选中 pane。
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
                let point = capsule.convert(next.locationInWindow, from: nil)
                if capsule.bounds.contains(point) {
                    onIdentityTapped?()
                }
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
        guard !isDraggingPane, let dragIdentifier else { return }

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

    @objc private func finishTapped() { onFinish?() }
    @objc private func injectTapped() { onInject?() }
}
