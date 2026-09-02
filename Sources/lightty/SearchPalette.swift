import AppKit
import LighttyCore

/// 全文搜索浮层（⇧⇧ 呼出），Notion 式：窗口左右居中、偏上，无遮罩压暗，
/// 点击卡片外关闭；卡片与侧栏/标题栏同底色，内部无分割线；
/// 左列表（任务名 + 命中摘录）+ 右预览（handoff 正文 + 目的地操作，
/// 目的地语义与侧栏任务点击一致：跳转已打开 pane / 三种打开方式）。
final class SearchPaletteView: NSView, NSTextFieldDelegate {
    var onDismiss: (() -> Void)?

    private struct Result {
        let fileURL: URL
        let task: TaskFile
        let running: [(controller: TerminalWindowController, pane: PaneView)]
        let snippet: NSAttributedString?
    }

    private weak var controller: TerminalWindowController?
    private let card = NSView()
    private let searchField = NSTextField()
    private let listScroll = NSScrollView()
    private let rowsStack = NSStackView()
    private let previewPane = NSView()
    private let previewTitle = NSTextField(labelWithString: "")
    private let previewTag = NSTextField(labelWithString: "")
    // scrollableTextView 工厂：自带 text container 宽度跟踪（手工组装易得零宽不换行）
    private let bodyScroll = NSTextView.scrollableTextView()
    private var previewBody: NSTextView { bodyScroll.documentView as! NSTextView }
    private let previewActions = NSStackView()
    private let hintLabel = NSTextField(labelWithString: "")
    private var results: [Result] = []
    private var selectedIndex = 0
    /// ↑↓ 滚动时行会从静止指针下滑过、误触 hover 选中；键盘导航后记录
    /// 指针位置，鼠标真动了才恢复 hover 跟随。
    private var hoverSuppressedAt: NSPoint?

    init(controller: TerminalWindowController) {
        self.controller = controller
        super.init(frame: .zero)

        // 卡片 layer 配置延迟到 viewDidMoveToWindow：layer-backed 视图挂窗时
        // backing layer 会被 AppKit 重建，init 里设置的 bg/shadow 会丢失。
        card.wantsLayer = true

        let icon = NSImageView(image: NSImage(
            systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))!)
        icon.contentTintColor = ShellStyle.tertiaryText

        searchField.placeholderString = L("Search task names and handoff content")
        searchField.font = .systemFont(ofSize: 15)
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.delegate = self
        (searchField.cell as? NSTextFieldCell)?.usesSingleLineMode = true

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = ShellStyle.paletteRowGap

        let document = FlippedView()
        // documentView 走 Auto Layout 必须关掉 autoresizing 翻译，否则自动
        // 生成的 frame 约束与手写约束冲突，文档视图被解成零尺寸（列表隐形）
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rowsStack)
        listScroll.documentView = document
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.drawsBackground = false

        // 预览面板：以浅一档的底色与列表区分（无分割线原则）
        previewPane.wantsLayer = true
        previewPane.layer?.cornerRadius = 8

        previewTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        previewTitle.textColor = ShellStyle.primaryText
        previewTitle.lineBreakMode = .byTruncatingTail

        previewTag.font = .systemFont(ofSize: 10.5)

        previewBody.isEditable = false
        previewBody.isSelectable = true
        previewBody.drawsBackground = false
        previewBody.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        previewBody.textContainerInset = NSSize(width: 0, height: 4)
        bodyScroll.hasVerticalScroller = true
        bodyScroll.autohidesScrollers = true
        bodyScroll.drawsBackground = false

        previewActions.orientation = .vertical
        previewActions.alignment = .leading
        previewActions.spacing = 4

        hintLabel.stringValue = L("↩ Jump / open in current workspace · esc Close")
        hintLabel.font = .systemFont(ofSize: 10.5)
        hintLabel.textColor = ShellStyle.tertiaryText

        addSubview(card)
        for v in [icon, searchField, listScroll, previewPane, hintLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(v)
        }
        for v in [previewTitle, previewTag, bodyScroll, previewActions] {
            v.translatesAutoresizingMaskIntoConstraints = false
            previewPane.addSubview(v)
        }
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        // ⚠️ 卡片不与 palette/themeFrame 建立任何约束：钉在窗口根视图上的
        // 约束会反向驱动窗口尺寸（AeroSpace 等平铺 WM 会因此重排）。
        // 卡片 frame 在 layout() 里按 ShellStyle.palette* token 手动计算，
        // 卡片内部子视图照常用 Auto Layout（约束只到 card 为止）。
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),

            searchField.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            searchField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),

            listScroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 14),
            listScroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            listScroll.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -8),

            previewPane.topAnchor.constraint(equalTo: listScroll.topAnchor),
            previewPane.leadingAnchor.constraint(
                equalTo: listScroll.trailingAnchor, constant: 10),
            previewPane.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            previewPane.bottomAnchor.constraint(equalTo: listScroll.bottomAnchor),
            // 左列表 58% / 右预览 42%
            previewPane.widthAnchor.constraint(
                equalTo: listScroll.widthAnchor, multiplier: 0.72),

            previewTitle.topAnchor.constraint(equalTo: previewPane.topAnchor, constant: 12),
            previewTitle.leadingAnchor.constraint(
                equalTo: previewPane.leadingAnchor, constant: 12),
            previewTitle.trailingAnchor.constraint(
                lessThanOrEqualTo: previewTag.leadingAnchor, constant: -8),

            previewTag.centerYAnchor.constraint(equalTo: previewTitle.centerYAnchor),
            previewTag.trailingAnchor.constraint(
                equalTo: previewPane.trailingAnchor, constant: -12),

            bodyScroll.topAnchor.constraint(equalTo: previewTitle.bottomAnchor, constant: 8),
            bodyScroll.leadingAnchor.constraint(
                equalTo: previewPane.leadingAnchor, constant: 12),
            bodyScroll.trailingAnchor.constraint(
                equalTo: previewPane.trailingAnchor, constant: -12),

            previewActions.topAnchor.constraint(equalTo: bodyScroll.bottomAnchor, constant: 10),
            previewActions.leadingAnchor.constraint(
                equalTo: previewPane.leadingAnchor, constant: 8),
            previewActions.trailingAnchor.constraint(
                equalTo: previewPane.trailingAnchor, constant: -8),
            previewActions.bottomAnchor.constraint(
                equalTo: previewPane.bottomAnchor, constant: -8),

            rowsStack.topAnchor.constraint(equalTo: document.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rowsStack.widthAnchor.constraint(equalTo: listScroll.widthAnchor),
            document.widthAnchor.constraint(equalTo: listScroll.widthAnchor),
            document.bottomAnchor.constraint(equalTo: rowsStack.bottomAnchor),

            hintLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            hintLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])
        applyColors()
        refresh(query: "")
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyColors() {
        card.layer?.backgroundColor =
            ShellStyle.sidebarBackground.shellResolvedCGColor(for: effectiveAppearance)
        card.layer?.borderColor =
            ShellStyle.divider.shellResolvedCGColor(for: effectiveAppearance)
        previewPane.layer?.backgroundColor =
            ShellStyle.raisedSurface.shellResolvedCGColor(for: effectiveAppearance)
        previewPane.layer?.borderColor =
            ShellStyle.divider.shellResolvedCGColor(for: effectiveAppearance)
        searchField.textColor = ShellStyle.primaryText
        previewBody.textColor = ShellStyle.secondaryText
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let layer = card.layer else { return }
        layer.cornerRadius = 12
        layer.borderWidth = 1
        previewPane.layer?.cornerRadius = 10
        previewPane.layer?.borderWidth = 1
        // 投影用 NSView.shadow（AppKit 维护，backing layer 重建后自动重涂；
        // 直接写 layer.shadow* 会在挂窗/重建时丢失——已踩过）。
        // 大扩散 + 明显下坠 = Notion 式悬浮感。
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
        shadow.shadowBlurRadius = 48
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        card.shadow = shadow
        // 预览区自身也是浮起的小卡片（Notion 式：抬升面 + 描边 + 轻投影）
        let previewShadow = NSShadow()
        previewShadow.shadowColor = NSColor.black.withAlphaComponent(0.14)
        previewShadow.shadowBlurRadius = 18
        previewShadow.shadowOffset = NSSize(width: 0, height: -4)
        previewPane.shadow = previewShadow
        applyColors()
    }

    override func layout() {
        super.layout()
        // 卡片 frame 手动计算（相对窗口的 token 定位，对窗口尺寸零反压）
        let w = min(bounds.width * ShellStyle.paletteWidthRatio, ShellStyle.paletteMaxWidth)
        let h = min(bounds.height * ShellStyle.paletteHeightRatio, ShellStyle.paletteMaxHeight)
        let x = (bounds.width - w) / 2
        let topOffset = bounds.height * ShellStyle.paletteTopRatio
        let y = isFlipped ? topOffset : bounds.height - topOffset - h
        card.frame = NSRect(x: x, y: y, width: w, height: h).integral
    }

    func focusSearch() {
        window?.makeFirstResponder(searchField)
    }

    override func mouseDown(with event: NSEvent) {
        let point = card.convert(event.locationInWindow, from: nil)
        if !card.bounds.contains(point) { onDismiss?() }
    }

    /// 覆盖下层终端注册的 I-beam 光标区（灵动岛同款问题同款解法）：
    /// 浮层整体箭头，可点行/按钮手型，输入框由 AppKit 自管 I-beam。
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    // MARK: - 检索

    private func refresh(query: String) {
        let running = AppState.shared.runningPanes()
        let all = AppState.shared.taskStore.list().tasks
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        var scored: [(result: Result, nameScore: Int?, bodyHits: Int)] = []
        for entry in all {
            let bound = running.filter {
                $0.pane.taskFileURL?.standardizedFileURL == entry.fileURL.standardizedFileURL
            }
            var nameScore: Int?
            var snippet: NSAttributedString?
            var bodyHits = 0
            if trimmed.isEmpty {
                nameScore = 0
            } else {
                nameScore = FuzzyMatch.score(pattern: trimmed, in: entry.task.name)
                (snippet, bodyHits) = Self.bodySnippet(in: entry.task.body, query: trimmed)
                guard nameScore != nil || bodyHits > 0 else { continue }
            }
            scored.append((
                Result(fileURL: entry.fileURL, task: entry.task,
                       running: bound, snippet: snippet),
                nameScore, bodyHits))
        }
        if trimmed.isEmpty {
            scored.sort {
                if ($0.result.running.isEmpty) != ($1.result.running.isEmpty) {
                    return !$0.result.running.isEmpty
                }
                return $0.result.task.updated > $1.result.task.updated
            }
        } else {
            scored.sort { a, b in
                switch (a.nameScore, b.nameScore) {
                case let (x?, y?) where x != y: return x > y
                case (.some, nil): return true
                case (nil, .some): return false
                default:
                    if a.bodyHits != b.bodyHits { return a.bodyHits > b.bodyHits }
                    return a.result.task.updated > b.result.task.updated
                }
            }
        }
        results = scored.map(\.result)
        selectedIndex = 0
        rebuildRows()
        updatePreview()
    }

    /// 正文首个命中行摘录（命中词加粗），返回（摘录，命中行总数）
    private static func bodySnippet(
        in body: String, query: String
    ) -> (NSAttributedString?, Int) {
        var snippet: NSAttributedString?
        var hits = 0
        let lowerQuery = query.lowercased()
        for line in body.split(separator: "\n") {
            guard line.lowercased().contains(lowerQuery) else { continue }
            hits += 1
            guard snippet == nil else { continue }
            let text = String(line).trimmingCharacters(in: .whitespaces)
            let attr = NSMutableAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: ShellStyle.secondaryText,
                ])
            if let hit = text.lowercased().range(of: lowerQuery) {
                attr.addAttributes(
                    [
                        .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                        .foregroundColor: ShellStyle.primaryText,
                    ],
                    range: NSRange(hit, in: text))
            }
            snippet = attr
        }
        return (snippet, hits)
    }

    // MARK: - 左列表

    private func rebuildRows() {
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, result) in results.enumerated() {
            let row = PaletteRowView(
                name: result.task.name,
                tag: result.running.isEmpty ? L("Dormant") : L("Active"),
                tagColor: result.running.isEmpty
                    ? ShellStyle.tertiaryText : ShellStyle.boundAccent,
                snippet: result.snippet)
            // 单击 = 选中并更新预览（提交动作在预览区/回车），与 Notion 的
            // 选择→预览→行动一致；hover 同样跟随（指针悬到哪预览到哪）
            let select: () -> Void = { [weak self] in
                self?.selectedIndex = index
                self?.applySelection()
                self?.updatePreview()
            }
            row.onTap = select
            row.onHover = { [weak self] in
                guard let self else { return }
                if let anchor = self.hoverSuppressedAt {
                    guard hypot(NSEvent.mouseLocation.x - anchor.x,
                                NSEvent.mouseLocation.y - anchor.y) > 2 else { return }
                    self.hoverSuppressedAt = nil
                }
                select()
            }
            row.onDoubleTap = { [weak self] in
                self?.selectedIndex = index
                self?.commitDefault()
            }
            row.translatesAutoresizingMaskIntoConstraints = false
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
        applySelection()
        window?.invalidateCursorRects(for: self)
    }

    private func applySelection() {
        for case let (index, row as PaletteRowView) in
            rowsStack.arrangedSubviews.enumerated() {
            row.isSelected = index == selectedIndex
        }
        if let row = rowsStack.arrangedSubviews[safe: selectedIndex] {
            row.scrollToVisible(row.bounds)
        }
    }

    // MARK: - 右预览

    private func updatePreview() {
        previewActions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let result = results[safe: selectedIndex] else {
            previewPane.isHidden = true
            return
        }
        previewPane.isHidden = false
        previewTitle.stringValue = result.task.name
        let active = !result.running.isEmpty
        previewTag.stringValue = active ? L("Active") : L("Dormant")
        previewTag.textColor = active ? ShellStyle.boundAccent : ShellStyle.tertiaryText
        previewBody.string = result.task.body.isEmpty
            ? RestoreFlow.summarize(result.task.body)
            : result.task.body

        // 目的地操作：与侧栏任务点击（RestoreFlow）同一套语义
        for (index, entry) in result.running.enumerated() {
            let workspace = entry.controller.workspaceName(of: entry.pane)
            let label = workspace.map { "\($0) › \(entry.pane.header.title)" }
                ?? entry.pane.header.title
            addAction(L("Jump · %@", label)) { [weak self] in
                guard let self, let target = self.results[safe: self.selectedIndex]?
                    .running[safe: index] else { return }
                target.controller.window?.makeKeyAndOrderFront(nil)
                target.controller.reveal(pane: target.pane)
                self.onDismiss?()
            }
        }
        addAction(L("Split in current workspace")) { [weak self] in
            self?.open { controller, pane in controller.addPaneToActiveTab(pane) }
        }
        addAction(L("New workspace")) { [weak self] in
            self?.open { controller, pane in controller.addTab(initialPane: pane) }
        }
        addAction(L("New window")) { [weak self] in
            self?.open { _, pane in AppState.shared.newWindow(initialPane: pane) }
        }
    }

    private func addAction(_ title: String, handler: @escaping () -> Void) {
        let button = PaletteActionButton(title)
        button.onTap = handler
        button.translatesAutoresizingMaskIntoConstraints = false
        previewActions.addArrangedSubview(button)
        button.widthAnchor.constraint(equalTo: previewActions.widthAnchor).isActive = true
    }

    private func open(
        _ place: (TerminalWindowController, PaneView) -> Void
    ) {
        guard let controller, let result = results[safe: selectedIndex] else { return }
        let pane = PaneView()
        pane.bind(to: result.fileURL, name: result.task.name)
        place(controller, pane)
        pane.focusTerminal()
        onDismiss?()
    }

    /// 回车默认动作：活跃跳转（首个绑定 pane），休眠在当前工作区分屏打开
    private func commitDefault() {
        guard let result = results[safe: selectedIndex] else { return }
        if let target = result.running.first {
            target.controller.window?.makeKeyAndOrderFront(nil)
            target.controller.reveal(pane: target.pane)
            onDismiss?()
        } else {
            open { controller, pane in controller.addPaneToActiveTab(pane) }
        }
    }

    // MARK: - 键盘

    func controlTextDidChange(_ obj: Notification) {
        refresh(query: searchField.stringValue)
    }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            commitDefault()
            return true
        case #selector(NSResponder.moveDown(_:)):
            guard !results.isEmpty else { return true }
            hoverSuppressedAt = NSEvent.mouseLocation
            selectedIndex = min(selectedIndex + 1, results.count - 1)
            applySelection()
            updatePreview()
            return true
        case #selector(NSResponder.moveUp(_:)):
            hoverSuppressedAt = NSEvent.mouseLocation
            selectedIndex = max(selectedIndex - 1, 0)
            applySelection()
            updatePreview()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onDismiss?()
            return true
        default:
            return false
        }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// 左列表行：任务名 + 活跃标签 + 命中摘录（hover/单击选中、双击提交）。
private final class PaletteRowView: NSView {
    var onTap: (() -> Void)?
    var onDoubleTap: (() -> Void)?
    var onHover: (() -> Void)?
    var isSelected = false { didSet { applyFill() } }

    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { applyFill() } }

    init(name: String, tag: String, tagColor: NSColor, snippet: NSAttributedString?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        nameLabel.textColor = ShellStyle.primaryText
        nameLabel.lineBreakMode = .byTruncatingTail

        let tagLabel = NSTextField(labelWithString: tag)
        tagLabel.font = .systemFont(ofSize: 10.5)
        tagLabel.textColor = tagColor

        let title = NSStackView(views: [nameLabel, tagLabel])
        title.orientation = .horizontal
        title.spacing = 8

        var rows: [NSView] = [title]
        if let snippet {
            let label = NSTextField(labelWithString: "")
            label.attributedStringValue = snippet
            label.lineBreakMode = .byTruncatingTail
            rows.append(label)
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyFill() {
        let fill: NSColor =
            isSelected ? ShellStyle.selectionFill : (hovered ? ShellStyle.controlFill : .clear)
        layer?.backgroundColor = fill.shellResolvedCGColor(for: effectiveAppearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFill()
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

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        onHover?()
    }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyFill()  // 挂窗时 backing layer 重建，选中态底色需重涂
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleTap?() } else { onTap?() }
    }
}

/// 预览区目的地行：与恢复气泡的目的地行同一视觉语言（左对齐、hover 提亮）。
private final class PaletteActionButton: NSView {
    var onTap: (() -> Void)?

    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { applyFill() } }

    init(_ title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = ShellStyle.primaryText
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyFill() {
        let fill: NSColor = hovered ? ShellStyle.selectionFill : .clear
        layer?.backgroundColor = fill.shellResolvedCGColor(for: effectiveAppearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFill()
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

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) { onTap?() }
}
