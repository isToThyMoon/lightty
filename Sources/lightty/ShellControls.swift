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
    /// 菜单尾部的附加动作，与选项之间隔一条分割线。它**不是一个选项**——点了不会改
    /// 当前值，只是把用户送去别处（「Agent 设置…」）。放进选项里会让「选中的是什么」
    /// 变得说不清。
    var trailingAction: (title: String, run: () -> Void)?

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
        // 当前值不能被压掉——横向栈里挨着一个标签时，默认的抗压优先级不够，
        // 「Codex」会被截成「Cod…」。要截也该截别人。
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        (label.cell as? NSTextFieldCell)?.usesSingleLineMode = true
        // 让它把胶囊里剩下的宽度吃满。`NSTextField` 报的固有宽度比它真正画字需要的
        // 少半个点（对齐矩形和绘制矩形不是一回事），照着固有宽度贴的话「Codex」会被
        // 截成「Cod…」；胶囊自己的宽度已经按实测多留了 4pt，让标签铺满就够了。
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
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
        setAccessibilityValue(selectedTitle)
        invalidateIntrinsicContentSize()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .popUpButton }

    /// 宽度按实际零件算，别写死箭头的宽——SF Symbol 实际比目测宽（实测 13pt，
    /// 原来按 12 算），而且 `NSTextField` 的对齐矩形比它真正画字的地方各宽 2pt：
    /// 两笔加起来，「Codex」正好差半个点画不下，被截成「Cod…」。
    /// 这里按实测补回来，宁可多一两个点的留白。
    override var intrinsicContentSize: NSSize {
        let arrow = max(ceil(chevron.intrinsicContentSize.width), 13)
        let text = ceil(label.intrinsicContentSize.width) + 4
        return NSSize(width: text + 10 + 6 + arrow + 8, height: 26)
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
        var items = options.map { option in
            ShellMenuPopover.Item.action(
                option.title, checked: option.id == selectedID, swatch: option.swatch
            ) { [weak self] in self?.select(option.id) }
        }
        if let trailingAction {
            items.append(.separator)
            items.append(.action(trailingAction.title) { trailingAction.run() })
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
        let fill: NSColor = hovered ? ShellStyle.inputHoverFill : ShellStyle.inputFill
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

/// 壳层的多行输入框：圆角底 + 占位文字 + 自带滚动。
/// 用 `NSTextView.scrollableTextView()` 而不是手工装 NSScrollView——手工组装很容易
/// 得到零宽的 text container，文字就不换行了。
final class ShellTextArea: NSView {
    private let scroll = NSTextView.scrollableTextView()
    private let placeholderLabel = NSTextField(wrappingLabelWithString: "")

    var textView: NSTextView { scroll.documentView as! NSTextView }
    var string: String {
        get { textView.string }
        set { textView.string = newValue; contentChanged() }
    }

    /// 内容少时就这么高；多起来跟着长，最多长到 `maximumHeight`，再多才开始滚。
    /// 一上来就给两倍高会让浮层平白高一截，绝大多数任务只写一两行。
    var minimumHeight: CGFloat = 92 { didSet { invalidateIntrinsicContentSize() } }
    var maximumHeight: CGFloat = 184 { didSet { invalidateIntrinsicContentSize() } }
    private var measuredHeight: CGFloat = 0
    private var ceilingHeight: CGFloat = 0

    /// 占位文字画在输入框里，而不是塞进 `string` 当默认值——后者会被当成真内容存进任务。
    var placeholder: String = "" {
        didSet {
            placeholderLabel.stringValue = placeholder
            refreshPlaceholder()
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7

        textView.delegate = self
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 11.5)
        textView.textContainerInset = NSSize(width: 6, height: 7)
        textView.isRichText = false
        textView.allowsUndo = true
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        placeholderLabel.font = .systemFont(ofSize: 11.5)
        placeholderLabel.isSelectable = false
        placeholderLabel.setAccessibilityElement(false)
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            // 与 textContainerInset 对齐，占位文字要落在光标起点上。
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            placeholderLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
        ])
        // 中文、日文这类要先拼再确定的输入法，拼字期间的「未确定文本」不发
        // `textDidChange`——只听那一条的话，字已经打在框里了占位文字还杵着，两层叠在
        // 一起。文本存储那一条在拼字期间就会发，听它。**这一条才是修好这件事的地方**。
        NotificationCenter.default.addObserver(
            self, selector: #selector(storageDidChange),
            name: NSTextStorage.didProcessEditingNotification, object: textView.textStorage)
        applyLook()
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLook()
    }

    private func applyLook() {
        layer?.backgroundColor = ShellStyle.inputFill.shellResolvedCGColor(for: effectiveAppearance)
        textView.textColor = ShellStyle.primaryText
        // 光标颜色**不要设**：AppKit 默认跟随系统强调色，应用里其他输入框（都是
        // NSTextField 的 field editor）用的就是这个默认。这里一旦写死，同一个浮层
        // 里上面是蓝光标、下面是黑光标。
        //
        // 这是唯一一处跟随系统强调色而不走 ShellStyle.accent 的地方，是刻意的：
        // 文本光标是系统级的输入提示，不是我们的「选中 / 开启」着色。
        placeholderLabel.textColor = ShellStyle.tertiaryText
    }

    @objc private func storageDidChange() { contentChanged() }

    /// 这条通知是在文本存储的**编辑事务里**发的：此刻让排版器去生成字形会直接抛
    /// （"attempted glyph generation while textStorage is editing"）。所以只挂一个
    /// 「待布局」，真正的丈量留给 `layout()`——那时事务已经结束。
    /// 占位文字不碰排版，可以就地改。
    private func contentChanged() {
        refreshPlaceholder()
        needsLayout = true
    }

    /// 装得下就按内容的自然高度（上下内边距都在，最后一行下面有留白）；装不下才封顶，
    /// 封顶值是最后一整行的下沿——那时下边距留不住，见 `remeasure()`。
    override var intrinsicContentSize: NSSize {
        let height = measuredHeight <= maximumHeight
            ? measuredHeight
            : (ceilingHeight > 0 ? ceilingHeight : maximumHeight)
        return NSSize(width: NSView.noIntrinsicMetric, height: max(height, minimumHeight))
    }

    /// 换行取决于宽度，所以每次布局完都要重量一次。只有真的变了才作废固有尺寸——
    /// 每次都作废会和布局互相触发，转不出来。
    override func layout() {
        super.layout()
        remeasure()
    }

    private func remeasure() {
        guard let manager = textView.layoutManager, let container = textView.textContainer else { return }
        manager.ensureLayout(for: container)
        let padding = textView.textContainerInset.height * 2
        let height = ceil(manager.usedRect(for: container).height) + padding
        // 上限落在**最后一整行的下沿**，直接问排版器要真实的行框——中文走回退字体，
        // 行高跟 `defaultLineHeight` 对不上，自己算出来的整数还是会切到行。
        //
        // 这里只加**上边距**，不加下边距：文本视图是滚动区里的文档，比可视区高，
        // 下边那道内边距只存在于全文末尾，不在裁剪线上。留出它反而会让下一行露出
        // 7pt 的头——这正是原来最后一行被拦腰切开的原因。
        let top = textView.textContainerInset.height
        let limit = maximumHeight - top
        var whole: CGFloat = 0
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) {
            rect, _, _, _, stop in
            if rect.maxY <= limit + 0.5 { whole = rect.maxY } else { stop.pointee = true }
        }
        let ceiling = whole > 0 ? whole + top : maximumHeight
        guard abs(height - measuredHeight) > 0.5 || abs(ceiling - ceilingHeight) > 0.5 else { return }
        measuredHeight = height
        ceilingHeight = ceiling
        invalidateIntrinsicContentSize()
    }

    /// 框里一个字都没有（未确定文本也算字）时才显示占位文字。
    var isShowingPlaceholder: Bool { !placeholderLabel.isHidden }

    private func refreshPlaceholder() {
        // 未确定文本本身已经在 `string` 里了，`hasMarkedText` 只是多防一手：
        // 刚按下死键、还没出字的那一瞬间也不该闪出占位文字。
        placeholderLabel.isHidden = !textView.string.isEmpty || textView.hasMarkedText()
    }
}

extension ShellTextArea: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) { refreshPlaceholder() }
}

/// Shared configuration for every editable single-line AppKit text field.
///
/// The field remains an `NSTextField`: its cell owns placeholder rendering and
/// AppKit owns the shared field editor and input-method lifecycle. This module
/// only centralizes the invariant single-line configuration.
enum ShellTextFieldStyle {
    static func configure(
        _ field: NSTextField,
        font: NSFont? = nil,
        placeholder: String? = nil
    ) {
        if let font { field.font = font }
        if let placeholder { field.placeholderString = placeholder }
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        if let cell = field.cell as? NSTextFieldCell {
            cell.usesSingleLineMode = true
            cell.wraps = false
            cell.isScrollable = true
        }
    }
}

/// 壳层的单行输入框：与 `ShellDropdown`、`ShellTextArea` 同一块底色和圆角。
///
/// 原来这些框用的是系统 bezel——深色下是一圈浅边加近黑底，跟旁边自绘的胶囊、
/// 文本域完全是两种语言，一个卡片里三种框长得都不一样。
///
/// 容器只负责外观与布局；placeholder、文字、光标和 field editor 全部由 NSTextField
/// 与 AppKit 自己处理。
final class ShellFieldBox: NSView {
    let field: NSTextField

    static let height: CGFloat = 28

    init(_ field: NSTextField) {
        self.field = field
        ShellTextFieldStyle.configure(field)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
        applyLook()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLook()
    }

    private func applyLook() {
        layer?.backgroundColor = ShellStyle.inputFill.shellResolvedCGColor(for: effectiveAppearance)
        field.textColor = ShellStyle.primaryText
    }
}
