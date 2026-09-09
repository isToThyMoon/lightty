import AppKit
import LighttyCore

/// 身份胶囊的展开态（灵动岛式）。由 PaneView 驱动岛体背景层（island）形变；
/// 面板本体与第一行身份内容保持静止，背景从其周围形变。结构：
///   [●] pane 名（无框编辑，回车提交；与 header 胶囊逐像素同构，不能加任何前缀）
///   ─────────────────────────
///   任务  <当前任务 / 未选择>              ⌄   （点击 → 岛体向下长出选择列表）
///   （列表态）搜索输入 + 过滤列表：回车执行高亮行；无匹配回车 = 以输入文本
///   新建任务并绑定。列表底部是当前任务的两个操作：重命名、解除绑定。
///
/// 两行长得不一样是刻意的：第一行是「点了直接打字」，第二行是「点了弹出列表」，
/// 行为不同就不能同一张脸。第二行常驻浅底加箭头，不靠 hover 才暗示可点。
/// 没绑任务时面板一打开就把列表摊开——那时用户十有八九就是来挑任务的。
final class PaneIdentityPanel: NSView, NSTextFieldDelegate {
    /// 基础两行的高度；列表展开时岛体高度 = base + 列表实高。
    static let baseHeight: CGFloat = 62
    static let panelWidth: CGFloat = 272
    /// 任务行的标识，供测试定位。
    static let taskFieldIdentifier = NSUserInterfaceItemIdentifier("paneIdentity.taskField")
    /// 面板常驻 frame 高度上限（岛体在其中生长，面板本身永不动画）：
    /// 搜索行 34 + 七行候选 + 底栏（分隔线与两个操作）+ 留白。
    static let maxHeight: CGFloat = baseHeight + 34 + 7 * 26 + 5 + 2 * 26 + 8

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
    /// 岛体的投影。单独一层放在岛体**后面**，内部挖空——见 IslandShadowView。
    let islandShadow = IslandShadowView()
    /// 面板的全部内容都住在岛体的裁剪层里，由长开的岛体「露出来」。
    /// 它的 frame 反向跟着岛体走（原点取岛体原点的相反数），所以内容在面板坐标系里
    /// 纹丝不动，只是被裁的范围在变。
    private let contentHost = NSView()
    /// 扩展区（分隔线 + 任务行）：初次形变期间渐显/渐隐；第一行不参与。
    let extras = NSView()

    private let fixedContent = NSView()
    private let dotView = NSView()
    /// 与胶囊上那枚 agent 图标逐像素同构。第一行只要和胶囊差一个像素，
    /// 展开/收起交接的那一帧就会看见文字跳动。
    private let agentIcon = NSImageView()
    private var agentIconWidth: NSLayoutConstraint!
    private var agentIconGap: NSLayoutConstraint!
    private let nameField = NSTextField()
    private let separator = NSView()
    private let taskField = TaskFieldRow()
    private let taskEditor = NSTextField()

    // —— 内联任务选择器
    private let listContainer = NSView()
    private let searchField = NSTextField()
    private let listSeparator = NSView()
    private let taskScrollView = WheelAwareScrollView()
    /// 当前任务的操作（重命名、解除绑定）钉在列表底部，不跟候选一起滚——
    /// 任务一多它们就会被挤到滚动区外面，等于又藏起来了。
    private let listFooter = NSView()
    private let footerSeparator = NSView()
    private var footerHeightConstraint: NSLayoutConstraint?
    private let taskRowsView = FlippedRowsView()
    private var rowViews: [TaskRowView] = []
    /// 与 `rowViews` 一一对应的动作表。
    private var rowActions: [() -> Void] = []
    /// 滚动区里的候选行数、底栏里的操作行数。高度和滚动文档尺寸都靠这两个数。
    private var choiceRowCount = 0
    private var footerRowCount = 0
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

    /// 岛体当前的矩形。外部只读——改它必须走 `applyIslandFrame`，否则内容会被带偏。
    var islandFrame: NSRect { island.frame }

    /// 第一行在面板坐标系里的位置。形变期间它必须纹丝不动——胶囊隐身、这一行顶上，
    /// 动一个像素交接就穿帮。内容之所以要跟着岛体反向偏移，就是为了守住这一条。
    var identityRowOriginInPanel: NSPoint { fixedContent.convert(.zero, to: self) }

    /// 名字相对状态点的横向偏移。必须与胶囊给出的同一个数（见 PaneIdentityMetrics）。
    var titleOffsetFromDot: CGFloat { nameField.frame.minX - dotView.frame.maxX }

    var currentIslandHeight: CGFloat {
        listOpen ? Self.baseHeight + listHeight : Self.baseHeight
    }

    private var listHeight: CGFloat {
        // 搜索行 34 + 候选行数 × 26 + 固定底栏 + 底部留白
        let rows = CGFloat(min(max(choiceRowCount, 1), 7))
        return 34 + rows * 26 + footerHeight + 8
    }

    /// 底栏：分隔线 1 + 间距 4 + 每行 26。没有操作时整条收成 0。
    private var footerHeight: CGFloat {
        footerRowCount == 0 ? 0 : 5 + CGFloat(footerRowCount) * 26
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        // 岛体是一块浮起来的半透明面（材质取舍见 IdentityIslandView）：底色留一点透，
        // 让终端的颜色渗上来；发丝边与宽软阴影负责把它从底下拎起来。不取终端的
        // 背景色做底——用户把终端底调成相近色时岛体会整个隐形。
        island.wantsLayer = true
        island.layer?.cornerRadius = IdentityIslandView.cornerRadius
        island.layer?.borderWidth = 0.5
        addSubview(islandShadow)
        // 下层 terminal 声明了整片 I-beam，岛体夺回箭头；可点行/按钮各自装手型
        HoverCursor.installArrow(on: island)
        addSubview(island)
        // 默认铺满面板：还没形变过（刚建好、或测试里直接布局）时内容就在面板原位，
        // 岛体一旦有了 frame，`applyIslandFrame` 会把它反向偏移回去。
        contentHost.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.maxHeight)
        island.hostContent(contentHost)

        for v in [fixedContent, extras] {
            v.translatesAutoresizingMaskIntoConstraints = false
            contentHost.addSubview(v)
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

        taskField.identifier = PaneIdentityPanel.taskFieldIdentifier
        taskField.onTap = { [weak self] in self?.toggleTaskList() }

        taskEditor.font = .systemFont(ofSize: 11)
        taskEditor.isBordered = false
        taskEditor.drawsBackground = false
        taskEditor.focusRingType = .none
        taskEditor.isHidden = true
        taskEditor.delegate = self

        // —— 内联任务选择器（默认隐藏；打开时岛体向下生长露出）
        listContainer.isHidden = true
        listContainer.wantsLayer = true
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
        taskScrollView.contentView.drawsBackground = false
        // 文档视图不能用约束钉在裁剪视图上：滚动改的是裁剪视图的 bounds，Auto Layout
        // 每次布局都会把文档顶边拽回裁剪视图顶边，滚起来一跳一跳。宽随裁剪视图，
        // 高由行数决定，都走 frame。
        taskRowsView.autoresizingMask = [.width]
        taskScrollView.documentView = taskRowsView

        for v in [dotView, agentIcon, nameField] {
            v.translatesAutoresizingMaskIntoConstraints = false
            fixedContent.addSubview(v)
        }
        agentIconWidth = agentIcon.widthAnchor.constraint(equalToConstant: 0)
        agentIconGap = nameField.leadingAnchor.constraint(equalTo: agentIcon.trailingAnchor)
        for v in [separator, taskField, taskEditor] {
            v.translatesAutoresizingMaskIntoConstraints = false
            extras.addSubview(v)
        }
        listContainer.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(listContainer)
        footerSeparator.wantsLayer = true
        for v in [listSeparator, searchField, taskScrollView, listFooter] {
            v.translatesAutoresizingMaskIntoConstraints = false
            listContainer.addSubview(v)
        }

        footerSeparator.translatesAutoresizingMaskIntoConstraints = false
        listFooter.addSubview(footerSeparator)

        let listHeightConstraint = listContainer.heightAnchor.constraint(
            equalToConstant: listHeight)
        self.listHeightConstraint = listHeightConstraint
        let footerHeightConstraint = listFooter.heightAnchor.constraint(equalToConstant: 0)
        self.footerHeightConstraint = footerHeightConstraint

        let fixedContentLeadingConstraint = fixedContent.leadingAnchor.constraint(
            equalTo: contentHost.leadingAnchor)
        self.fixedContentLeadingConstraint = fixedContentLeadingConstraint
        NSLayoutConstraint.activate([
            fixedContent.topAnchor.constraint(equalTo: contentHost.topAnchor),
            fixedContentLeadingConstraint,
            fixedContent.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            fixedContent.heightAnchor.constraint(equalToConstant: Self.baseHeight),

            dotView.leadingAnchor.constraint(
                equalTo: fixedContent.leadingAnchor, constant: PaneIdentityMetrics.dotLeading),
            dotView.centerYAnchor.constraint(equalTo: fixedContent.topAnchor, constant: 10),
            dotView.widthAnchor.constraint(equalToConstant: PaneIdentityMetrics.dotSize),
            dotView.heightAnchor.constraint(equalToConstant: PaneIdentityMetrics.dotSize),

            // 与胶囊同一套数：dot →6→ 图标(10) →4→ 名字；没有图标时两段都收成 0。
            agentIcon.leadingAnchor.constraint(
                equalTo: dotView.trailingAnchor, constant: PaneIdentityMetrics.iconLeading),
            agentIcon.centerYAnchor.constraint(equalTo: dotView.centerYAnchor),
            agentIcon.heightAnchor.constraint(equalToConstant: PaneIdentityMetrics.iconSize),
            agentIconWidth,
            agentIconGap,

            nameField.centerYAnchor.constraint(equalTo: dotView.centerYAnchor),
            nameField.trailingAnchor.constraint(
                equalTo: fixedContent.trailingAnchor, constant: -10),

            extras.topAnchor.constraint(equalTo: fixedContent.topAnchor, constant: 24),
            extras.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            extras.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            extras.bottomAnchor.constraint(equalTo: fixedContent.bottomAnchor),

            separator.topAnchor.constraint(equalTo: extras.topAnchor),
            separator.leadingAnchor.constraint(equalTo: extras.leadingAnchor, constant: 10),
            separator.trailingAnchor.constraint(equalTo: extras.trailingAnchor, constant: -10),
            separator.heightAnchor.constraint(equalToConstant: 1),

            // 任务行横跨整行：它现在长得像一个下拉选择器，常驻浅底 + 右端箭头，
            // 不靠 hover 才暗示可点——用户不会把鼠标移上去试。
            taskField.leadingAnchor.constraint(equalTo: extras.leadingAnchor, constant: 8),
            taskField.trailingAnchor.constraint(equalTo: extras.trailingAnchor, constant: -8),
            taskField.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 6),
            taskField.heightAnchor.constraint(equalToConstant: 24),

            taskEditor.leadingAnchor.constraint(equalTo: taskField.valueLeadingAnchor),
            taskEditor.trailingAnchor.constraint(equalTo: taskField.trailingAnchor, constant: -10),
            taskEditor.centerYAnchor.constraint(equalTo: taskField.centerYAnchor),

            // —— 列表区：紧接 base 区之下（岛体没长到时 isHidden 遮蔽）
            listContainer.topAnchor.constraint(equalTo: fixedContent.bottomAnchor),
            listContainer.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            listContainer.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
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
                equalTo: listContainer.leadingAnchor, constant: SidebarListScrollView.leadingMargin),
            taskScrollView.trailingAnchor.constraint(
                equalTo: listContainer.trailingAnchor, constant: -SidebarListScrollView.trailingMargin),
            taskScrollView.bottomAnchor.constraint(equalTo: listFooter.topAnchor),

            listFooter.leadingAnchor.constraint(equalTo: taskScrollView.leadingAnchor),
            listFooter.trailingAnchor.constraint(
                equalTo: taskScrollView.trailingAnchor, constant: -SidebarListScrollView.railWidth),
            listFooter.bottomAnchor.constraint(
                equalTo: listContainer.bottomAnchor, constant: -8),
            footerHeightConstraint,

            footerSeparator.topAnchor.constraint(equalTo: listFooter.topAnchor),
            footerSeparator.leadingAnchor.constraint(
                equalTo: listFooter.leadingAnchor, constant: 4),
            footerSeparator.trailingAnchor.constraint(
                equalTo: listFooter.trailingAnchor, constant: -4),
            footerSeparator.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private var morphTimer: Timer?

    /// One clock owns the entire reveal. AppKit must never animate the island and
    /// its counter-offset content independently: their intermediate frames drift.
    func applyIslandFrame(_ frame: NSRect, duration: TimeInterval,
                          completion: (() -> Void)? = nil) {
        morphTimer?.invalidate()
        morphTimer = nil
        let start = island.frame
        guard duration > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            displayIslandFrame(frame)
            completion?()
            return
        }
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let progress = min(1, (CACurrentMediaTime() - began) / duration)
            let eased = CGFloat(1 - pow(1 - progress, 3))
            func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * eased }
            self.displayIslandFrame(NSRect(
                x: mix(start.minX, frame.minX), y: mix(start.minY, frame.minY),
                width: mix(start.width, frame.width), height: mix(start.height, frame.height)))
            if progress >= 1 {
                timer.invalidate()
                self.morphTimer = nil
                completion?()
            }
        }
        morphTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func displayIslandFrame(_ frame: NSRect) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            island.frame = frame
            contentHost.frame = NSRect(
                origin: NSPoint(x: -frame.minX, y: -frame.minY), size: bounds.size)
            islandShadow.frame = frame
            islandShadow.apply(size: frame.size)
            layoutSubtreeIfNeeded()
            CATransaction.commit()
        }
    }

    /// 第一行始终锚在 header 胶囊原位；只有目标胶囊在面板打开期间移动时（例如
    /// 侧栏开合），收起阶段才更新这个锚点以完成无缝交接。
    func setIdentityAnchorOffset(_ offset: CGFloat) {
        fixedContentLeadingConstraint.constant = offset
        needsLayout = true
    }

    // MARK: - 数据与主题

    func update(paneName: String, taskName: String?, dot: NSColor, agent: SessionAgent?) {
        nameField.stringValue = paneName
        boundTaskName = taskName
        dotColor = dot
        agentIcon.image = agent.flatMap { AgentSessionIcon.image(for: $0) }
        agentIconWidth.constant = agent == nil ? 0 : PaneIdentityMetrics.iconSize
        agentIconGap.constant = agent == nil ? 0 : PaneIdentityMetrics.iconGap
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
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        island.layer?.borderColor = ShellStyle.primaryText.withAlphaComponent(0.12)
            .shellResolvedCGColor(for: appearance)
        islandShadow.layer?.shadowOpacity = isDark ? 0.55 : 0.22
        // 顶亮底稍暗的极淡渐变：给这块面一点厚度，纯平涂会显得是贴上去的色块。
        // 底下是糊过的画面（窗口后模糊），罩色只负责提亮和保证文字对比度，
        // 不必压实——压实了就又变回一块白板。
        let surface = ShellStyle.raisedSurface
        island.tint.gradientLayer?.colors = [
            surface.withAlphaComponent(isDark ? 0.52 : 0.48)
                .shellResolvedCGColor(for: appearance),
            surface.withAlphaComponent(isDark ? 0.44 : 0.40)
                .shellResolvedCGColor(for: appearance),
        ]
        dotView.layer?.backgroundColor = (statusDotColor ?? dotColor)
            .shellResolvedCGColor(for: effectiveAppearance)
        separator.layer?.backgroundColor = foreground.withAlphaComponent(0.08).cgColor
        listSeparator.layer?.backgroundColor = foreground.withAlphaComponent(0.08).cgColor
        footerSeparator.layer?.backgroundColor = foreground.withAlphaComponent(0.08).cgColor
        nameField.textColor = foreground
        nameField.placeholderAttributedString = NSAttributedString(
            string: L("Name this terminal"),
            attributes: [
                .font: nameField.font ?? NSFont.systemFont(ofSize: 11),
                .foregroundColor: foreground.withAlphaComponent(0.3),
            ])
        agentIcon.contentTintColor = foreground
        taskEditor.textColor = foreground
        searchField.textColor = foreground
        searchField.placeholderAttributedString = NSAttributedString(
            string: L("Search, or type a new task name and press Return"),
            attributes: [
                .font: searchField.font ?? NSFont.systemFont(ofSize: 11),
                .foregroundColor: foreground.withAlphaComponent(0.3),
            ])
        taskField.apply(taskName: boundTaskName, isOpen: listOpen, foreground: foreground)
        taskField.isHidden = !taskEditor.isHidden
    }

    // MARK: - 内联任务选择器

    /// 任务行的动作：开合选择列表。
    func toggleTaskList() {
        listOpen ? closeTaskList() : openTaskList()
    }

    private func openTaskList() {
        choices = taskProvider?() ?? []
        searchField.stringValue = ""
        listOpen = true
        // Build the final list geometry before revealing it through the island clip.
        applyFilter("")
        listContainer.isHidden = false
        applyColors()
        if morphTimer == nil { window?.makeFirstResponder(searchField) }
    }

    private func closeTaskList() {
        listOpen = false
        scrollSettle?.cancel()
        scrollSettle = nil
        isScrolling = false
        pointerScrolled = false
        listContainer.isHidden = true
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
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = []
        rowActions = []
        choiceRowCount = 0
        footerRowCount = 0

        listFooter.subviews.filter { $0 !== footerSeparator }.forEach { $0.removeFromSuperview() }
        var previousChoice: NSView?
        var previousAction: NSView?
        // 行和它的动作一起登记：回车、点击、上下键走同一张表，不再靠下标反推
        // 「这一行是任务还是新建还是解绑」——底部动作一多，那种算法必错。
        func add(_ row: TaskRowView, toFooter: Bool = false, action: @escaping () -> Void) {
            let index = rowViews.count
            row.onTap = action
            row.onHover = { [weak self] in self?.hoverHighlight(index) }
            if toFooter {
                attach(row: row, to: listFooter,
                       below: previousAction ?? footerSeparator, gap: previousAction == nil ? 4 : 2)
                previousAction = row
                footerRowCount += 1
            } else {
                attach(row: row, to: taskRowsView, below: previousChoice,
                       gap: previousChoice == nil ? 0 : 2)
                previousChoice = row
                choiceRowCount += 1
            }
            rowViews.append(row)
            rowActions.append(action)
        }

        for (index, choice) in filtered.enumerated() {
            add(TaskRowView(
                title: choice.name,
                detail: choice.running ? L("Active") : nil,
                checked: choice.current,
                role: .choice,
                foreground: foreground)) { [weak self] in self?.pick(index) }
        }
        // 无匹配：显式给出"回车新建"行（可点击）
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        if filtered.isEmpty, !query.isEmpty {
            add(TaskRowView(
                title: L("New task “%@”", query),
                detail: L("Return"), checked: false, role: .action,
                foreground: foreground)) { [weak self] in self?.createFromQuery() }
        }
        // 已绑定：底部放当前任务的两个操作。改名原本挂在任务行右边一支 20×20、
        // 半透明的铅笔上，没人找得到；挪到这里和解绑并排——用户点开列表本来就是
        // 在管任务归属，两个同类操作放在一处。
        if boundTaskName != nil {
            add(TaskRowView(
                title: L("Rename this task…"), detail: nil, checked: false,
                role: .action, foreground: foreground), toFooter: true) { [weak self] in
                guard let self else { return }
                self.closeTaskList()
                self.beginTaskRename()
            }
            add(TaskRowView(
                title: L("Unbind"), detail: nil, checked: false, role: .destructive,
                foreground: foreground), toFooter: true) { [weak self] in
                self?.onUnbindTask?()
                self?.closeTaskList()
            }
        }
        // 岛体最多展示七行候选；更多任务留在原生滚动视口内，不能继续撑高面板。
        taskRowsView.frame = NSRect(
            x: 0, y: 0, width: taskScrollView.contentSize.width,
            height: max(CGFloat(choiceRowCount) * 26 - 2, 0))
        footerSeparator.isHidden = footerRowCount == 0
        footerHeightConstraint?.constant = footerHeight
        listHeightConstraint?.constant = listHeight

        if listOpen {
            onIslandHeightChange?(currentIslandHeight)
        }
        layoutSubtreeIfNeeded()
        setHighlight(0, scroll: true)
        window?.invalidateCursorRects(for: self)
    }

    private var listHeightConstraint: NSLayoutConstraint?

    private func attach(row: TaskRowView, to container: NSView,
                        below previous: NSView?, gap: CGFloat) {
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        var constraints = [
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            row.heightAnchor.constraint(equalToConstant: 24),
        ]
        if let previous {
            constraints.append(
                row.topAnchor.constraint(equalTo: previous.bottomAnchor, constant: gap))
        } else {
            constraints.append(row.topAnchor.constraint(equalTo: container.topAnchor))
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
    /// 回车：执行当前高亮行登记的动作。空列表（没有任务、也没输入）时直接收起。
    private func commitList() {
        guard rowActions.indices.contains(highlighted) else {
            closeTaskList()
            return
        }
        rowActions[highlighted]()
    }

    // MARK: - 交互

    /// 面板展开到位后，还没绑任务就把列表摊开：用户点开胶囊八成就是来挑任务的，
    /// 不该还要先发现第二行能点。已经绑了就保持收起——那时多半只是想扫一眼是哪个。
    ///
    /// Prepare before presenting the window, so opening reveals the complete list
    /// in one transition and does not focus an editor halfway through the morph.
    func expandTaskListForFirstUse() {
        guard boundTaskName == nil, !listOpen else { return }
        toggleTaskList()
    }

    /// 展开动画收尾时把光标放到该放的地方：列表开着就是搜索框，否则是 pane 名。
    func focusInitialField() {
        if listOpen {
            window?.makeFirstResponder(searchField)
        } else {
            window?.makeFirstResponder(nameField)
            nameField.currentEditor()?.selectAll(nil)
        }
    }

    @objc private func beginTaskRename() {
        guard let boundTaskName else { return }
        if listOpen { closeTaskList() }
        taskEditor.stringValue = boundTaskName
        taskEditor.isHidden = false
        taskField.isHidden = true
        window?.makeFirstResponder(taskEditor)
        taskEditor.currentEditor()?.selectAll(nil)
    }

    private func endTaskRename(commit: Bool) {
        guard !taskEditor.isHidden else { return }
        let name = taskEditor.stringValue.trimmingCharacters(in: .whitespaces)
        taskEditor.isHidden = true
        taskField.isHidden = false
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

    /// 行的身份：候选任务、对当前任务的操作、破坏性操作。三种各自一个颜色——
    /// 操作和候选同色时，用户看不出底下那两行不是"又一个任务"。
    enum Role { case choice, action, destructive }

    init(title: String, detail: String?, checked: Bool, role: Role,
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
        switch role {
        case .choice: label.textColor = foreground.withAlphaComponent(0.85)
        case .action: label.textColor = ShellStyle.navigationAccent
        case .destructive: label.textColor = .systemRed
        }

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


/// 任务行：长得就像 macOS 的下拉选择器——常驻浅底、圆角、右端一个箭头。
///
/// 改这一行是因为它原来和上一行（pane 名，点了直接打字）长得一模一样：都是透明底
/// 的一行字，只有图标不同。两种完全不同的行为顶着同一张脸，用户只能靠试才知道
/// 这里点得开。可点性原本靠 hover 变色表达，可鼠标不移上去就什么提示都没有。
///
/// 左边那个「任务」小标签同理：把这一行的值是什么说死，不用从「绑定任务」四个字
/// 里猜。第一行不加标签——它必须和 header 上的胶囊逐像素同构，加了形变就穿帮。
private final class TaskFieldRow: NSView {
    var onTap: (() -> Void)?

    private let caption = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { applyFill() } }
    private var restingFill = NSColor.clear
    private var hoverFill = NSColor.clear

    /// 内联改名的编辑框要和值对齐，位置由这里给出。
    var valueLeadingAnchor: NSLayoutXAxisAnchor { value.leadingAnchor }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        HoverCursor.installPointingHand(on: self)

        caption.font = .systemFont(ofSize: 10.5)
        value.font = .systemFont(ofSize: 11)
        value.lineBreakMode = .byTruncatingTail
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        caption.setContentCompressionResistancePriority(.required, for: .horizontal)

        for view in [caption, value, chevron] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            // 标签 10.5pt、值 11pt，字号不同时各自按 centerY 居中对的是行盒中心，
            // 不是基线——看着就是一高一低。共用一条基线才是齐的。
            caption.firstBaselineAnchor.constraint(equalTo: value.firstBaselineAnchor),

            value.leadingAnchor.constraint(equalTo: caption.trailingAnchor, constant: 8),
            value.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.trailingAnchor.constraint(
                lessThanOrEqualTo: chevron.leadingAnchor, constant: -6),

            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(taskName: String?, isOpen: Bool, foreground: NSColor) {
        caption.stringValue = L("Task")
        caption.textColor = foreground.withAlphaComponent(0.45)
        value.stringValue = taskName ?? L("Not set")
        value.textColor = foreground.withAlphaComponent(taskName == nil ? 0.4 : 0.85)
        chevron.image = NSImage(
            systemSymbolName: isOpen ? "chevron.up" : "chevron.down",
            accessibilityDescription: L("Choose task"))?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        chevron.contentTintColor = foreground.withAlphaComponent(0.45)
        restingFill = foreground.withAlphaComponent(0.06)
        hoverFill = foreground.withAlphaComponent(0.11)
        applyFill()
    }

    private func applyFill() {
        layer?.backgroundColor = (hovered ? hoverFill : restingFill).cgColor
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
    override func mouseDown(with event: NSEvent) { onTap?() }
}

/// 灵动岛岛体：窗口后模糊 + 抬升面罩，子层随 frame 形变（morph 动画改 frame）。
///
/// 模糊只能来自「窗口后模糊」，而它要求这一层住在自己的窗口里。别的路都试过、都不通：
///   - `NSVisualEffectView` 窗口内模糊：读不到 ghostty 装的那层 IOSurface，
///     糊出来是一片均匀的灰，等于白白盖一层不透明底。
///   - `CALayer.backgroundFilters` 加高斯模糊：同样不生效，终端的字原样透上来。
///   - 自截图再糊（菜单卡那套）：`cacheDisplay` 截不到 IOSurface，截出来是空的。
/// 所以整个面板挂在一扇静止的子窗口里（`PaneIdentityWindow`）。那扇窗口不参与动画，
/// 形变仍然发生在面板内部，一个像素都没让给窗口。
///
/// 圆角走 `maskImage`：窗口后模糊不是普通图层内容，祖先的 `masksToBounds` 裁不到它。
final class IdentityIslandView: NSView {
    /// 岛体圆角。裁切层、磨砂遮罩、阴影路径、外层描边都用它，别各写各的。
    static let cornerRadius: CGFloat = 8


    /// 圆角裁切层：罩层这类普通图层由它裁；磨砂自己带遮罩。
    private let clip = NSView()
    private let blur = NSVisualEffectView()
    let tint = SheenView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clip.wantsLayer = true
        clip.layer?.cornerRadius = Self.cornerRadius
        clip.layer?.masksToBounds = true
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.maskImage = .paneIdentityRoundedMask(cornerRadius: Self.cornerRadius)
        // Each sampled frame resizes the material and clip synchronously.
        // No descendant owns an independent position or size animation.
        blur.frame = bounds
        blur.autoresizingMask = [.width, .height]
        addSubview(blur)
        clip.frame = bounds
        clip.autoresizingMask = [.width, .height]
        addSubview(clip)
        tint.frame = clip.bounds
        tint.autoresizingMask = [.width, .height]
        clip.addSubview(tint)
    }

    /// 面板内容住进裁剪层：岛体长到哪儿，内容就露到哪儿。
    func hostContent(_ view: NSView) {
        clip.addSubview(view)
    }

    required init?(coder: NSCoder) { fatalError() }

}

/// 岛体的投影。单独一层、画在岛体后面，并且用 even-odd 遮罩把岛体内部挖掉。
///
/// 为什么不直接给岛体图层设阴影：`CALayer` 把阴影画在自己内容的**背后**，而岛体是
/// 半透明的（磨砂 + 五成罩色），阴影会透上来把岛内的文字压暗。挖空之后阴影只留在
/// 轮廓外面，内容干净。
final class IslandShadowView: NSView {
    /// 阴影向外散开的范围。遮罩要盖住这一圈，否则阴影会被遮罩边界切平。
    private static let spread: CGFloat = 60
    private let cutout = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = 22
        layer?.shadowOffset = NSSize(width: 0, height: -8)
        cutout.fillRule = .evenOdd
        layer?.mask = cutout
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shadow and cutout use the same sampled size as the island.
    func apply(size: NSSize) {
        guard let layer else { return }
        let radius = IdentityIslandView.cornerRadius
        let body = NSRect(origin: .zero, size: size)
        let shadowPath = CGPath(roundedRect: body, cornerWidth: radius,
                                cornerHeight: radius, transform: nil)
        // 遮罩层坐标系比本层大一圈（原点在 -spread），路径里的岛体轮廓相应内移。
        let maskFrame = body.insetBy(dx: -Self.spread, dy: -Self.spread)
        let maskPath = CGMutablePath()
        maskPath.addRect(NSRect(origin: .zero, size: maskFrame.size))
        maskPath.addRoundedRect(
            in: NSRect(x: Self.spread, y: Self.spread, width: size.width, height: size.height),
            cornerWidth: radius, cornerHeight: radius)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cutout.frame = maskFrame
        CATransaction.commit()
        layer.shadowPath = shadowPath
        cutout.path = maskPath
    }
}

/// 抬升面本体：整个视图就是一层渐变，颜色由宿主随明暗重解析后灌进来。
final class SheenView: NSView {
    override func makeBackingLayer() -> CALayer { CAGradientLayer() }

    var gradientLayer: CAGradientLayer? { layer as? CAGradientLayer }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        gradientLayer?.startPoint = CGPoint(x: 0.5, y: 1)
        gradientLayer?.endPoint = CGPoint(x: 0.5, y: 0)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// 承载灵动岛的子窗口。它**静止**：位置由宿主在布局变化时喂，动画全部发生在
/// 面板内部。存在的唯一理由是窗口后模糊要求磨砂层住在自己的窗口里。
final class PaneIdentityWindow: NSPanel {
    /// 面板四周留出的透明边距。岛体展开时占满面板整宽，阴影只能画在这圈边距里；
    /// 边距不够就会被窗口边界切平，看起来像贴纸而不是浮起来的卡。
    static let shadowMargin: CGFloat = 60

    init(content: NSView) {
        let margin = Self.shadowMargin
        super.init(
            contentRect: NSRect(origin: .zero,
                                size: NSSize(width: content.bounds.width + margin * 2,
                                             height: content.bounds.height + margin * 2)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false   // 岛体自己画投影；系统投影会框住整扇窗（含透明边距）
        hidesOnDeactivate = false
        animationBehavior = .none
        isMovableByWindowBackground = false
        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        content.frame = NSRect(origin: NSPoint(x: margin, y: margin), size: content.bounds.size)
        root.addSubview(content)
        contentView = root
    }

    /// 面板里有两个输入框（pane 名、任务搜索），必须能成为 key。
    override var canBecomeKey: Bool { true }

    /// 不让 AppKit 把窗口挤进屏幕可见区域。四周那圈透明边距会让窗口顶边高出主窗口，
    /// 顶到菜单栏那一带；默认的约束会把整扇窗往下推，面板跟着下移，第一行就对不上
    /// 胶囊了——形变一交接就穿帮。这里的位置由宿主算好，不需要系统插手。
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

extension NSImage {
    /// 圆角遮罩图，九宫格拉伸——岛体形变时尺寸一直在变，不能每帧重画。
    static func paneIdentityRoundedMask(cornerRadius radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(
            top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// 任务列表的滚动视图：滚轮/触控板事件上报，宿主据此区分指针驱动与键盘驱动的滚动。
private final class WheelAwareScrollView: SidebarListScrollView {
    var onWheel: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onWheel?()
        super.scrollWheel(with: event)
    }
}
