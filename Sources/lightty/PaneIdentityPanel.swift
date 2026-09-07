import AppKit
import LighttyCore

/// 身份胶囊的展开态（灵动岛式）。由 PaneView 驱动岛体背景层（island）形变；
/// 面板本体与第一行身份内容保持静止，背景从其周围形变。结构：
///   [●] pane 名（无框编辑，回车提交）
///   ─────────────────────────
///   [📄] 任务行（点击 → 岛体再向下生长出内联任务选择器）
///   （列表态）搜索输入 + 过滤列表：回车绑定高亮项；无匹配回车 = 以输入
///   文本新建任务并绑定——绑定/切换/新建统一成一步，无二级气泡无按钮。
final class PaneIdentityPanel: NSView, NSTextFieldDelegate {
    /// 基础两行的高度；列表展开时岛体高度 = base + 列表实高。
    static let baseHeight: CGFloat = 62
    static let panelWidth: CGFloat = 272
    /// 面板常驻 frame 高度上限（岛体在其中生长，面板本身永不动画）。
    static let maxHeight: CGFloat = baseHeight + 34 + 7 * 26 + 8

    struct TaskChoice {
        let name: String
        let fileURL: URL
        let running: Bool
        let current: Bool
    }

    var onPaneNameCommit: ((String) -> Void)?
    var onBindTask: ((URL) -> Void)?
    var onCreateTask: ((String) -> Void)?
    var onUnbindTask: (() -> Void)?
    var onTaskRenameCommit: ((String) -> Void)?
    var onDismiss: (() -> Void)?
    /// 岛体期望高度变化（列表开合）：PaneView 负责动画 island frame。
    var onIslandHeightChange: ((CGFloat) -> Void)?
    /// 任务数据源（每次打开列表时拉取）。
    var taskProvider: (() -> [TaskChoice])?

    /// 岛体背景层：frame 由 PaneView 驱动；第一行身份内容与背景 frame 解耦，
    /// 展开时状态点和标题保持原位。
    let island = IdentityIslandView()
    /// 扩展区（分隔线 + 任务行）：初次形变期间渐显/渐隐；第一行不参与。
    let extras = NSView()

    private let fixedContent = NSView()
    private let dotView = NSView()
    private let nameField = NSTextField()
    private let separator = NSView()
    private let taskButton = HoverRowButton()
    private let taskRenameButton = NSButton()
    private let taskEditor = NSTextField()

    // —— 内联任务选择器
    private let listContainer = NSView()
    private let searchField = NSTextField()
    private let listSeparator = NSView()
    private let taskScrollView = WheelAwareScrollView()
    private let taskRowsView = FlippedRowsView()
    private var rowViews: [TaskRowView] = []
    private var choices: [TaskChoice] = []
    private var filtered: [TaskChoice] = []
    private var highlighted = 0
    private var listOpen = false

    private var foreground = NSColor.white
    private var background = NSColor.black
    private var boundTaskName: String?
    private var dotColor = ShellStyle.dormantAccent
    /// agent 活动状态色。一旦设了就压过 `dotColor`——后者由 PaneView 在
    /// bind/unbind/rename 时传进来，那条路径不知道状态，会把状态色刷掉。
    private var statusDotColor: NSColor?
    private var fixedContentLeadingConstraint: NSLayoutConstraint!

    var currentIslandHeight: CGFloat {
        listOpen ? Self.baseHeight + listHeight : Self.baseHeight
    }

    private var listHeight: CGFloat {
        // 搜索行 34 + 行数 × 26 + 底部留白
        let rows = CGFloat(min(max(rowViews.count, 1), 7))
        return 34 + rows * 26 + 6
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        // 岛体材质与自绘菜单卡同一套：窗口内模糊（能糊到下层 Metal 终端画面）+
        // 高透抬升面罩 + 发丝线 + 宽而软的阴影。不再取终端的背景色做底——
        // 用户把终端底调成相近色时岛体会整个隐形，抬升面才能保证一直看得见。
        island.wantsLayer = true
        island.layer?.cornerRadius = 8
        island.layer?.borderWidth = 0.5
        island.layer?.shadowRadius = 18
        island.layer?.shadowOffset = NSSize(width: 0, height: -6)
        island.layer?.masksToBounds = false
        // 下层 terminal 声明了整片 I-beam，岛体夺回箭头；可点行/按钮各自装手型
        HoverCursor.installArrow(on: island)
        addSubview(island)

        for v in [fixedContent, extras] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        // —— 第一行：与胶囊逐像素同构（dot 领距 6、间距 6、11pt medium、centerY=10）
        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 3.5

        // 三个输入框都是单行编辑器：usesSingleLineMode 只管显示截断，编辑态
        // 还要 wraps=false + isScrollable=true——否则长文本（尤其 CJK）在 20pt
        // 行高里折成两行，每行都被竖向裁一半，两行都看不清。
        for field in [nameField, taskEditor, searchField] {
            guard let cell = field.cell as? NSTextFieldCell else { continue }
            cell.usesSingleLineMode = true
            cell.wraps = false
            cell.isScrollable = true
        }

        nameField.font = .systemFont(ofSize: 11, weight: .medium)
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.focusRingType = .none
        nameField.delegate = self

        // —— 扩展区
        separator.wantsLayer = true

        taskButton.isBordered = false
        taskButton.focusRingType = .none
        taskButton.setButtonType(.momentaryChange)
        taskButton.alignment = .left
        taskButton.wantsLayer = true
        taskButton.layer?.cornerRadius = 5
        taskButton.target = self
        taskButton.action = #selector(taskTapped)
        (taskButton.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        taskButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        taskRenameButton.isBordered = false
        taskRenameButton.focusRingType = .none
        taskRenameButton.setButtonType(.momentaryChange)
        taskRenameButton.image = NSImage(
            systemSymbolName: "pencil", accessibilityDescription: L("Rename task"))
        taskRenameButton.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 10, weight: .medium)
        taskRenameButton.target = self
        taskRenameButton.action = #selector(beginTaskRename)
        HoverCursor.installPointingHand(on: taskRenameButton)

        taskEditor.font = .systemFont(ofSize: 11)
        taskEditor.isBordered = false
        taskEditor.drawsBackground = false
        taskEditor.focusRingType = .none
        taskEditor.isHidden = true
        taskEditor.delegate = self

        // —— 内联任务选择器（默认隐藏；打开时岛体向下生长露出）
        listContainer.isHidden = true
        listContainer.wantsLayer = true
        listContainer.layer?.masksToBounds = true  // 展开动画中列表只露出岛体已长到的部分
        listSeparator.wantsLayer = true
        searchField.font = .systemFont(ofSize: 11)
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.delegate = self

        taskScrollView.drawsBackground = false
        taskScrollView.onWheel = { [weak self] in
            self?.pointerScrolled = true
            self?.noteScrollActivity()
        }
        // 滚动活动以裁剪视图 bounds 变化为准，而不是只看滚轮事件：手指抬起后的
        // 回弹动画、键盘上下键的 scrollToVisible 都没有事件，但行同样在指针下移动。
        taskScrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(taskListDidScroll),
            name: NSView.boundsDidChangeNotification, object: taskScrollView.contentView)
        taskScrollView.borderType = .noBorder
        taskScrollView.hasHorizontalScroller = false
        taskScrollView.hasVerticalScroller = true
        taskScrollView.autohidesScrollers = true
        taskScrollView.scrollerStyle = .overlay
        taskScrollView.contentView.drawsBackground = false
        // 文档视图不能用约束钉在裁剪视图上：滚动改的是裁剪视图的 bounds，Auto Layout
        // 每次布局都会把文档顶边拽回裁剪视图顶边，滚起来一跳一跳。宽随裁剪视图，
        // 高由行数决定，都走 frame。
        taskRowsView.autoresizingMask = [.width]
        taskScrollView.documentView = taskRowsView

        for v in [dotView, nameField] {
            v.translatesAutoresizingMaskIntoConstraints = false
            fixedContent.addSubview(v)
        }
        for v in [separator, taskButton, taskRenameButton, taskEditor] {
            v.translatesAutoresizingMaskIntoConstraints = false
            extras.addSubview(v)
        }
        listContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(listContainer)
        for v in [listSeparator, searchField, taskScrollView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            listContainer.addSubview(v)
        }

        let listHeightConstraint = listContainer.heightAnchor.constraint(
            equalToConstant: listHeight)
        self.listHeightConstraint = listHeightConstraint

        let fixedContentLeadingConstraint = fixedContent.leadingAnchor.constraint(
            equalTo: leadingAnchor)
        self.fixedContentLeadingConstraint = fixedContentLeadingConstraint
        NSLayoutConstraint.activate([
            fixedContent.topAnchor.constraint(equalTo: topAnchor),
            fixedContentLeadingConstraint,
            fixedContent.trailingAnchor.constraint(equalTo: trailingAnchor),
            fixedContent.heightAnchor.constraint(equalToConstant: Self.baseHeight),

            dotView.leadingAnchor.constraint(equalTo: fixedContent.leadingAnchor, constant: 6),
            dotView.centerYAnchor.constraint(equalTo: fixedContent.topAnchor, constant: 10),
            dotView.widthAnchor.constraint(equalToConstant: 7),
            dotView.heightAnchor.constraint(equalToConstant: 7),

            nameField.centerYAnchor.constraint(equalTo: dotView.centerYAnchor),
            nameField.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 6),
            nameField.trailingAnchor.constraint(
                equalTo: fixedContent.trailingAnchor, constant: -10),

            extras.topAnchor.constraint(equalTo: fixedContent.topAnchor, constant: 24),
            extras.leadingAnchor.constraint(equalTo: leadingAnchor),
            extras.trailingAnchor.constraint(equalTo: trailingAnchor),
            extras.bottomAnchor.constraint(equalTo: fixedContent.bottomAnchor),

            separator.topAnchor.constraint(equalTo: extras.topAnchor),
            separator.leadingAnchor.constraint(equalTo: extras.leadingAnchor, constant: 10),
            separator.trailingAnchor.constraint(equalTo: extras.trailingAnchor, constant: -10),
            separator.heightAnchor.constraint(equalToConstant: 1),

            taskButton.leadingAnchor.constraint(equalTo: extras.leadingAnchor, constant: 10),
            taskButton.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 7),
            // hover 底包裹内容本身（不横跨整行）；超长仍被右边界截断
            taskButton.trailingAnchor.constraint(
                lessThanOrEqualTo: taskRenameButton.leadingAnchor, constant: -4),
            taskButton.heightAnchor.constraint(equalToConstant: 22),

            taskRenameButton.centerYAnchor.constraint(equalTo: taskButton.centerYAnchor),
            taskRenameButton.trailingAnchor.constraint(
                equalTo: extras.trailingAnchor, constant: -8),
            taskRenameButton.widthAnchor.constraint(equalToConstant: 20),
            taskRenameButton.heightAnchor.constraint(equalToConstant: 20),

            taskEditor.leadingAnchor.constraint(equalTo: taskButton.leadingAnchor, constant: 2),
            taskEditor.trailingAnchor.constraint(equalTo: taskButton.trailingAnchor),
            taskEditor.centerYAnchor.constraint(equalTo: taskButton.centerYAnchor),

            // —— 列表区：紧接 base 区之下（岛体没长到时 isHidden 遮蔽）
            listContainer.topAnchor.constraint(equalTo: fixedContent.bottomAnchor),
            listContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            listContainer.widthAnchor.constraint(equalToConstant: Self.panelWidth),
            listHeightConstraint,

            listSeparator.topAnchor.constraint(equalTo: listContainer.topAnchor),
            listSeparator.leadingAnchor.constraint(
                equalTo: listContainer.leadingAnchor, constant: 10),
            listSeparator.trailingAnchor.constraint(
                equalTo: listContainer.trailingAnchor, constant: -10),
            listSeparator.heightAnchor.constraint(equalToConstant: 1),

            searchField.topAnchor.constraint(equalTo: listContainer.topAnchor, constant: 9),
            searchField.leadingAnchor.constraint(
                equalTo: listContainer.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(
                equalTo: listContainer.trailingAnchor, constant: -12),
            searchField.heightAnchor.constraint(equalToConstant: 20),

            taskScrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 7),
            taskScrollView.leadingAnchor.constraint(
                equalTo: listContainer.leadingAnchor, constant: 6),
            taskScrollView.trailingAnchor.constraint(
                equalTo: listContainer.trailingAnchor, constant: -6),
            taskScrollView.bottomAnchor.constraint(
                equalTo: listContainer.bottomAnchor, constant: -6),

        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 第一行始终锚在 header 胶囊原位；只有目标胶囊在面板打开期间移动时（例如
    /// 侧栏开合），收起阶段才更新这个锚点以完成无缝交接。
    func setIdentityAnchorOffset(_ offset: CGFloat) {
        fixedContentLeadingConstraint.constant = offset
        needsLayout = true
    }

    // MARK: - 数据与主题

    func update(paneName: String, taskName: String?, dot: NSColor) {
        nameField.stringValue = paneName
        boundTaskName = taskName
        dotColor = dot
        endTaskRename(commit: false)
        applyColors()
    }

    /// 由 `PaneHeaderView` 在状态变化时直接推入（面板挂在窗口 contentView 上，
    /// 不在 pane 子树里，header 用「胶囊隐身」这个标记定位到展开中的面板）。
    /// `nil` = 回到绑定态静态配色。
    func applyStatusDot(_ color: NSColor?) {
        guard statusDotColor != color else { return }
        statusDotColor = color
        applyColors()
    }

    /// 岛体已改用壳层抬升面材质，不再随终端主题取色；保留入口以便状态变化时重涂。
    func applyTerminalTheme(background: NSColor, foreground: NSColor) {
        applyColors()
    }

    /// 状态色是 shellDynamic，layer 上的 CGColor 只是快照，明暗切换必须重解析。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        let appearance = effectiveAppearance
        // 岛体上的文字与线条走壳层主文字色（随系统明暗），罩层是抬升面色，两者配套
        foreground = NSColor(cgColor: ShellStyle.primaryText.shellResolvedCGColor(for: appearance))
            ?? foreground
        background = .clear
        island.layer?.backgroundColor = NSColor.clear.cgColor
        island.layer?.borderColor = ShellStyle.primaryText.withAlphaComponent(0.08)
            .shellResolvedCGColor(for: appearance)
        island.layer?.shadowOpacity =
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.45 : 0.16
        island.tint.layer?.backgroundColor = ShellStyle.raisedSurface.withAlphaComponent(0.6)
            .shellResolvedCGColor(for: appearance)
        dotView.layer?.backgroundColor = (statusDotColor ?? dotColor)
            .shellResolvedCGColor(for: effectiveAppearance)
        separator.layer?.backgroundColor = foreground.withAlphaComponent(0.08).cgColor
        listSeparator.layer?.backgroundColor = foreground.withAlphaComponent(0.08).cgColor
        nameField.textColor = foreground
        nameField.placeholderAttributedString = NSAttributedString(
            string: L("Name this terminal"),
            attributes: [
                .font: nameField.font ?? NSFont.systemFont(ofSize: 11),
                .foregroundColor: foreground.withAlphaComponent(0.3),
            ])
        taskEditor.textColor = foreground
        searchField.textColor = foreground
        searchField.placeholderAttributedString = NSAttributedString(
            string: L("Search, or type a new task name and press Return"),
            attributes: [
                .font: searchField.font ?? NSFont.systemFont(ofSize: 11),
                .foregroundColor: foreground.withAlphaComponent(0.3),
            ])
        taskRenameButton.contentTintColor = foreground.withAlphaComponent(0.5)
        taskRenameButton.isHidden = boundTaskName == nil || !taskEditor.isHidden
        taskButton.hoverFill = foreground.withAlphaComponent(0.08)

        // 任务行内容：📄 + 名字/入口 + ⌄/⌃（同一条 attributed，整行可点）
        let bound = boundTaskName != nil
        let textColor = foreground.withAlphaComponent(bound ? 0.85 : 0.45)
        let font = NSFont.systemFont(ofSize: 11)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: textColor,
        ]

        func symbol(_ name: String, size: CGFloat, alpha: CGFloat) -> NSAttributedString? {
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
                        .applying(.init(paletteColors: [
                            foreground.withAlphaComponent(alpha),
                        ]))) else { return nil }
            let attachment = NSTextAttachment()
            attachment.image = image
            // 以 capHeight 为基准垂直居中：descender 偏移会让图标沉底
            attachment.bounds = NSRect(
                x: 0, y: (font.capHeight - image.size.height) / 2,
                width: image.size.width, height: image.size.height)
            let string = NSMutableAttributedString(attachment: attachment)
            string.addAttribute(
                .font, value: font, range: NSRange(location: 0, length: string.length))
            return string
        }

        let title = NSMutableAttributedString()
        if let doc = symbol(bound ? "doc.text" : "doc.badge.plus", size: 9.5,
                            alpha: bound ? 0.6 : 0.4) {
            title.append(NSAttributedString(string: " ", attributes: attributes))
            title.append(doc)
        }
        title.append(NSAttributedString(
            string: "  \(boundTaskName ?? L("Bind task"))", attributes: attributes))
        taskButton.attributedTitle = title
    }

    // MARK: - 内联任务选择器

    @objc private func taskTapped() {
        listOpen ? closeTaskList() : openTaskList()
    }

    private func openTaskList() {
        choices = taskProvider?() ?? []
        searchField.stringValue = ""
        listOpen = true
        // 先建行再显示容器：rebuildRows 看到容器还是隐藏的，就按「从 0 长出」做露出遮罩。
        applyFilter("")  // 定好列表目标高度，并触发岛体形变（PaneView 里 0.18s easeOut）
        listContainer.isHidden = false
        applyColors()
        window?.makeFirstResponder(searchField)
    }

    /// 读取动画当前露出的列表高度；同一事务内尚无呈现层时，从遮罩起点衔接。
    private var visibleListHeight: CGFloat {
        guard !listContainer.isHidden else { return 0 }
        // 动画可被连续输入打断，约束只代表目标，不能作为下一段动画的起点。
        if let presented = island.layer?.presentation() {
            return max(0, presented.frame.height - Self.baseHeight)
        }
        if let mask = listContainer.layer?.mask {
            let animation = mask.animation(forKey: "reveal") as? CABasicAnimation
            return mask.presentation()?.bounds.height
                ?? (animation?.fromValue as? CGFloat)
                ?? mask.bounds.height
        }
        return listHeightConstraint?.constant ?? 0
    }

    /// 列表布局固定，用顶边锚定的显式遮罩与岛体同步露出内容。
    /// 不动画高度约束，避免重排让滚动视口内的行跳位。
    private func revealList(from oldHeight: CGFloat) {
        layoutSubtreeIfNeeded()
        let full = listContainer.bounds
        // 收缩或反向动画也必须丢弃旧遮罩，它的顶边坐标属于旧容器。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        listContainer.layer?.mask = nil
        CATransaction.commit()
        guard full.height > oldHeight else { return }
        let mask = CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        mask.anchorPoint = CGPoint(x: 0.5, y: 1)
        mask.position = CGPoint(x: full.midX, y: full.height)
        mask.bounds = full
        listContainer.layer?.mask = mask
        let grow = CABasicAnimation(keyPath: "bounds.size.height")
        grow.fromValue = oldHeight
        grow.toValue = full.height
        grow.duration = 0.18
        grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak listContainer] in
            if listContainer?.layer?.mask === mask { listContainer?.layer?.mask = nil }
        }
        mask.add(grow, forKey: "reveal")
        CATransaction.commit()
    }

    private func closeTaskList() {
        listOpen = false
        scrollSettle?.cancel()
        scrollSettle = nil
        isScrolling = false
        pointerScrolled = false
        listContainer.isHidden = true
        listContainer.layer?.mask = nil
        applyColors()
        onIslandHeightChange?(currentIslandHeight)
        window?.invalidateCursorRects(for: self)
    }

    private func applyFilter(_ query: String) {
        pointerScrolled = false
        noteScrollActivity()
        if query.isEmpty {
            filtered = choices
        } else {
            filtered = choices
                .compactMap { choice -> (TaskChoice, Int)? in
                    guard let score = FuzzyMatch.score(
                        pattern: query, in: choice.name) else { return nil }
                    return (choice, score)
                }
                .sorted { $0.1 > $1.1 }
                .map { $0.0 }
        }
        rebuildRows()
    }

    private func rebuildRows() {
        let visibleHeight = visibleListHeight
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = []

        var previous: NSView?
        for (index, choice) in filtered.enumerated() {
            let row = TaskRowView(
                title: choice.name,
                detail: choice.running ? L("Active") : nil,
                checked: choice.current,
                destructive: false,
                foreground: foreground)
            row.onTap = { [weak self] in self?.pick(index) }
            row.onHover = { [weak self] in self?.hoverHighlight(index) }
            attach(row: row, below: previous)
            previous = row
            rowViews.append(row)
        }
        // 无匹配：显式给出"回车新建"行（可点击）
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        if filtered.isEmpty, !query.isEmpty {
            let row = TaskRowView(
                title: L("New task “%@”", query),
                detail: L("Return"), checked: false, destructive: false,
                foreground: foreground)
            row.onTap = { [weak self] in self?.createFromQuery() }
            let rowIndex = rowViews.count
            row.onHover = { [weak self] in self?.hoverHighlight(rowIndex) }
            attach(row: row, below: previous)
            previous = row
            rowViews.append(row)
        }
        // 已绑定：底部解绑行
        if boundTaskName != nil {
            let row = TaskRowView(
                title: L("Unbind"), detail: nil, checked: false, destructive: true,
                foreground: foreground)
            row.onTap = { [weak self] in
                self?.onUnbindTask?()
                self?.closeTaskList()
            }
            let rowIndex = rowViews.count
            row.onHover = { [weak self] in self?.hoverHighlight(rowIndex) }
            attach(row: row, below: previous)
            rowViews.append(row)
        }
        // 岛体最多展示七行；更多任务留在原生滚动视口内，不能继续撑高透明面板。
        taskRowsView.frame = NSRect(
            x: 0, y: 0, width: taskScrollView.contentSize.width,
            height: max(CGFloat(rowViews.count) * 26 - 2, 0))
        listHeightConstraint?.constant = listHeight

        if listOpen {
            onIslandHeightChange?(currentIslandHeight)
            revealList(from: visibleHeight)
        }
        layoutSubtreeIfNeeded()
        setHighlight(0, scroll: true)
        window?.invalidateCursorRects(for: self)
    }

    private var listHeightConstraint: NSLayoutConstraint?

    private func attach(row: TaskRowView, below previous: NSView?) {
        row.translatesAutoresizingMaskIntoConstraints = false
        taskRowsView.addSubview(row)
        var constraints = [
            row.leadingAnchor.constraint(equalTo: taskRowsView.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: taskRowsView.trailingAnchor),
            row.heightAnchor.constraint(equalToConstant: 24),
        ]
        if let previous {
            constraints.append(row.topAnchor.constraint(equalTo: previous.bottomAnchor, constant: 2))
        } else {
            constraints.append(row.topAnchor.constraint(equalTo: taskRowsView.topAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }

    // 滚动（含回弹）期间行从静止指针下经过，会连发 mouseEntered；此时高亮条会
    // 跟着行跳来跳去，看起来像在和系统回弹抢位。滚动活动结束 150ms 后才恢复 hover。
    // 键盘上下键触发的滚动同样屏蔽——否则指针停在列表上时，行一滚过指针，
    // hover 就把键盘刚选中的行抢回去。
    private var isScrolling = false
    private var scrollSettle: DispatchWorkItem?
    /// 这轮滚动是否由滚轮/触控板驱动：停稳后把高亮归到指针所在行；键盘滚动不归位。
    private var pointerScrolled = false

    @objc private func taskListDidScroll(_ note: Notification) {
        noteScrollActivity()
    }

    private func noteScrollActivity() {
        guard listOpen else { return }
        isScrolling = true
        scrollSettle?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scrollDidSettle() }
        scrollSettle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func scrollDidSettle() {
        isScrolling = false
        guard pointerScrolled else { return }
        pointerScrolled = false
        // 滚动期间吞掉的 mouseEntered 不会补发；停稳后按指针位置归位，
        // 否则高亮会留在早已滚出视口的行上，回车会绑定一个看不见的任务。
        guard let window, listOpen else { return }
        let point = taskRowsView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard taskScrollView.documentVisibleRect.contains(point),
              let index = rowViews.firstIndex(where: { $0.frame.contains(point) }) else { return }
        setHighlight(index)
    }

    private func hoverHighlight(_ index: Int) {
        guard !isScrolling else { return }
        setHighlight(index)
    }

    /// `scroll`：键盘移动或筛选重置高亮时把行滚进视口。鼠标 hover 触发的高亮绝不能滚——
    /// 用户滚轮滚动时指针不断经过新行，每次都 scrollToVisible 会把列表往回拽。
    private func setHighlight(_ index: Int, scroll: Bool = false) {
        if scroll {
            pointerScrolled = false
            noteScrollActivity()
        }
        highlighted = index
        for (i, row) in rowViews.enumerated() {
            row.highlighted = i == index
        }
        if scroll, rowViews.indices.contains(index) {
            rowViews[index].scrollToVisible(rowViews[index].bounds)
        }
    }

    private func pick(_ index: Int) {
        guard filtered.indices.contains(index) else { return }
        onBindTask?(filtered[index].fileURL)
        closeTaskList()
    }

    private func createFromQuery() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        onCreateTask?(query)
        closeTaskList()
    }

    /// 回车语义：有匹配 → 绑定高亮项；无匹配 → 以输入文本新建并绑定。
    private func commitList() {
        if filtered.isEmpty {
            if searchField.stringValue
                .trimmingCharacters(in: .whitespaces).isEmpty {
                closeTaskList()
            } else if highlighted < rowViews.count - (boundTaskName != nil ? 1 : 0) {
                createFromQuery()
            } else {
                onUnbindTask?()
                closeTaskList()
            }
        } else if highlighted < filtered.count {
            pick(highlighted)
        } else {
            // 高亮落在解绑行
            onUnbindTask?()
            closeTaskList()
        }
    }

    // MARK: - 交互

    func focusNameField() {
        window?.makeFirstResponder(nameField)
        nameField.currentEditor()?.selectAll(nil)
    }

    /// PaneView 的展开/收起动画只通过这个入口控制可消失内容。
    func setExpandedContentAlpha(_ alpha: CGFloat, animated: Bool) {
        if animated {
            extras.animator().alphaValue = alpha
            listContainer.animator().alphaValue = alpha
        } else {
            extras.alphaValue = alpha
            listContainer.alphaValue = alpha
        }
    }

    @objc private func beginTaskRename() {
        guard let boundTaskName else { return }
        if listOpen { closeTaskList() }
        taskEditor.stringValue = boundTaskName
        taskEditor.isHidden = false
        taskButton.isHidden = true
        taskRenameButton.isHidden = true
        window?.makeFirstResponder(taskEditor)
        taskEditor.currentEditor()?.selectAll(nil)
    }

    private func endTaskRename(commit: Bool) {
        guard !taskEditor.isHidden else { return }
        let name = taskEditor.stringValue.trimmingCharacters(in: .whitespaces)
        taskEditor.isHidden = true
        taskButton.isHidden = false
        taskRenameButton.isHidden = boundTaskName == nil
        if commit, !name.isEmpty, name != boundTaskName {
            onTaskRenameCommit?(name)
        }
    }

    // MARK: - 编辑提交（回车）/ 取消（Esc）/ 上下键

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSTextField === searchField else { return }
        applyFilter(searchField.stringValue.trimmingCharacters(in: .whitespaces))
    }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            if control === nameField {
                let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { onPaneNameCommit?(name) }
                onDismiss?()
            } else if control === taskEditor {
                endTaskRename(commit: true)
            } else if control === searchField {
                commitList()
            }
            return true
        case #selector(NSResponder.moveDown(_:)) where control === searchField:
            setHighlight(min(highlighted + 1, max(rowViews.count - 1, 0)), scroll: true)
            return true
        case #selector(NSResponder.moveUp(_:)) where control === searchField:
            setHighlight(max(highlighted - 1, 0), scroll: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if control === taskEditor {
                endTaskRename(commit: false)
            } else if control === searchField {
                closeTaskList()
            } else {
                onDismiss?()
            }
            return true
        default:
            return false
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if listOpen {
            closeTaskList()
        } else {
            onDismiss?()
        }
    }

}

/// NSScrollView 的文档坐标从上向下增长，任务排序与键盘移动因此保持直观。
private final class FlippedRowsView: NSView {
    override var isFlipped: Bool { true }
}

/// 内联任务选择器的行（terminal palette）：高亮/勾选/尾注。
private final class TaskRowView: NSView {
    var onTap: (() -> Void)?
    var onHover: (() -> Void)?
    var highlighted = false { didSet { applyFill() } }

    private let rowForeground: NSColor
    private var tracking: NSTrackingArea?

    init(title: String, detail: String?, checked: Bool, destructive: Bool,
         foreground: NSColor) {
        self.rowForeground = foreground
        super.init(frame: .zero)
        HoverCursor.installPointingHand(on: self)
        wantsLayer = true
        layer?.cornerRadius = 5

        let check = NSImageView()
        check.image = NSImage(
            systemSymbolName: "checkmark", accessibilityDescription: nil)
        check.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 8, weight: .semibold)
        check.contentTintColor = foreground.withAlphaComponent(0.8)
        check.isHidden = !checked

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = destructive
            ? .systemRed : foreground.withAlphaComponent(0.85)

        let detailLabel = NSTextField(labelWithString: detail ?? "")
        detailLabel.font = .systemFont(ofSize: 9.5)
        detailLabel.textColor = foreground.withAlphaComponent(0.4)

        for v in [check, label, detailLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 11),

            label.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: detailLabel.leadingAnchor, constant: -8),

            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyFill()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyFill() {
        layer?.backgroundColor = highlighted
            ? rowForeground.withAlphaComponent(0.1).cgColor
            : NSColor.clear.cgColor
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

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) { onTap?() }
}

/// 带 hover 提亮的无边框按钮（任务行用；可点性由 hover 表达，不用箭头图标）。
private final class HoverRowButton: NSButton {
    var hoverFill: NSColor = .clear
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { applyFill() } }
    private var cursorInstalled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !cursorInstalled else { return }
        cursorInstalled = true
        HoverCursor.installPointingHand(on: self)
    }

    private func applyFill() {
        layer?.backgroundColor = hovered ? hoverFill.cgColor : NSColor.clear.cgColor
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
}

/// 灵动岛岛体：窗口内模糊 + 高透抬升面罩，子层随 frame 形变（morph 动画改 frame）。
final class IdentityIslandView: NSView {
    /// 圆角裁切层：窗口内模糊是层树里的普通 backdrop 层，祖先的 masksToBounds 裁得到，
    /// 不必给磨砂设 maskImage——形变动画中逐帧拉伸遮罩图会让边缘闪。
    private let clip = NSView()
    private let blur = NSVisualEffectView()
    let tint = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clip.wantsLayer = true
        clip.layer?.cornerRadius = 8
        clip.layer?.masksToBounds = true
        blur.material = .menu
        blur.blendingMode = .withinWindow
        blur.state = .active
        tint.wantsLayer = true
        // 走 autoresizing 而不是手动同步 frame：岛体 morph 用 animator 改 frame，
        // AppKit 在同一个动画组里给 autoresizing 子视图也套隐式动画，各层才会同步形变；
        // 手动在 setFrameSize 里赋值会让子层瞬间跳到终态，看起来像另一座岛飞过来。
        clip.frame = bounds
        clip.autoresizingMask = [.width, .height]
        addSubview(clip)
        // 磨砂层不随岛体形变改尺寸：backdrop 每帧重建很贵，会把 0.18s 的形变拖成
        // 半秒且顶部闪烁。做成固定超高、顶边钉在裁切层顶边（底边距弹性），
        // 岛体长高只是裁切层露出更多，磨砂本身静止。
        blur.frame = NSRect(x: 0, y: bounds.height - Self.blurHeight,
                            width: bounds.width, height: Self.blurHeight)
        blur.autoresizingMask = [.width, .minYMargin]
        clip.addSubview(blur)
        tint.frame = clip.bounds
        tint.autoresizingMask = [.width, .height]
        clip.addSubview(tint)
    }

    private static let blurHeight: CGFloat = 1200

    required init?(coder: NSCoder) { fatalError() }
}

/// 任务列表的滚动视图：滚轮/触控板事件上报，宿主据此区分指针驱动与键盘驱动的滚动。
private final class WheelAwareScrollView: NSScrollView {
    var onWheel: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onWheel?()
        super.scrollWheel(with: event)
    }
}
