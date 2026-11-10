import AppKit
import LighttyCore

/// 身份胶囊的展开态（灵动岛式）。由 PaneView 驱动岛体背景层（island）形变；
/// 面板本体与第一行身份内容保持静止，背景从其周围形变。结构：
///   [●] pane 名（无框编辑，回车提交；与 header 胶囊逐像素同构，不能加任何前缀）
///   ─────────────────────────
///   下面是左右两页，第一行和分隔线不参与切换：
///   详情页：任务 <当前任务 / 未选择> › （点击 → 选择器页从右侧推入）、目录 · 更新时间、
///   handoff 摘要；底栏左边是主操作「让 Agent 总结」（认得出 agent 时才有），右边是
///   两个图标操作：打开文档、解除绑定。任务改名走第一侧栏的任务菜单。
///   选择器页：返回 + 搜索输入、全部任务（此目录的在前）、常驻底栏（有输入就有「新建」行、键位提示）。
///   回车执行高亮行，⌘回车总是以输入文本新建；选定后整个岛收起。
///
/// 胶囊的两块点击区对应两个入口：点名字进详情页，点任务区直接进选择器页。
final class PaneIdentityPanel: NSView, NSTextFieldDelegate {
    /// 第一行加分隔线的高度：两页都从这里往下排。
    private static let headerHeight: CGFloat = 25
    /// 详情页只有任务行时的岛体高度。
    static let baseHeight: CGFloat = 62
    /// 底栏占的高度（间距 6 + 按钮 26）。没有操作时不留空白。
    static let handoffRowSpace: CGFloat = 32
    /// 放得下候选行里的「名字 + 目录 + 时间」。
    static let panelWidth: CGFloat = 340
    /// 任务行的标识，供测试定位。
    static let taskFieldIdentifier = NSUserInterfaceItemIdentifier("paneIdentity.taskField")
    /// 「让 Agent 总结」那一行的标识，供测试定位。
    static let handoffRowIdentifier = NSUserInterfaceItemIdentifier("paneIdentity.handoffRow")
    /// 选择器固定展示的候选视口高度：七行。
    private static let choiceViewportHeight: CGFloat = 7 * 26
    private static let hintHeight: CGFloat = 18
    /// 候选视口与底栏分隔线的间距：高亮行不能贴着线。
    private static let footerGap: CGFloat = 3
    /// 面板常驻 frame 高度上限（岛体在其中生长，面板本身永不动画）：选择器页是最高的
    /// 一页（详情页最多六行摘要，矮于它）。
    static let maxHeight: CGFloat =
        headerHeight + 34 + choiceViewportHeight + footerGap + 5 + 26 + hintHeight + 8

    struct TaskChoice {
        let name: String
        let fileURL: URL
        let running: Bool
        let current: Bool
        var directory: String? = nil
        var updated: Date? = nil
        /// 与这个终端的当前目录相关（`TaskDirectoryMatch`）。
        var nearby = false
    }

    /// 详情态展示的绑定任务信息，由 PaneView 在每次刷新时从任务文件读取。
    struct TaskDetail: Equatable {
        let directory: String
        let updated: String
        let summary: String
    }

    var onPaneNameCommit: ((String) -> Void)?
    var onBindTask: ((URL) -> Void)?
    var onCreateTask: ((String) -> Void)?
    var onUnbindTask: (() -> Void)?
    var onOpenTaskDocument: (() -> Void)?
    /// 让 pane 里的 agent 按交接协议重写这份任务的正文。
    ///
    /// 返回值是**真的送出去了没有**。送不出去的情形是真实存在的：面板开着的时候
    /// agent 转忙，而那一行的状态只在 `rebuildRows` 里算过一次（见
    /// `handoffActionProvider`），此刻还写着可点。这时候必须让调用方知道，否则
    /// 列表照关，用户看到的就是"点了，好像做了"。
    var onUpdateHandoff: (() -> Bool)?
    var onDismiss: (() -> Void)?
    /// 岛体期望高度变化（列表开合）：PaneView 负责动画 island frame。
    var onIslandHeightChange: ((CGFloat) -> Void)?
    /// 任务数据源（每次打开列表时拉取）。
    var taskProvider: (() -> [TaskChoice])?
    /// 绑定任务的详情。每次 `update` 问一次，读文件的代价只发生在内容可能变化时。
    var taskDetailProvider: (() -> TaskDetail?)?

    /// 「更新交接文档」这一行现在能不能点。
    ///
    /// 返回 `nil` = 这一行根本不出现。用在"这个 pane 里没有我们认得的 agent"——
    /// 不知道是 claude 还是 codex 就不知道该敲什么写法，摆一行点不动的出来只是噪音。
    /// `blocked` 则是"能做，只是现在不行"，那种要显示出来并给出理由。
    enum HandoffAction: Equatable { case ready, blocked(reason: String) }
    /// 每次重建行时问一次。刻意不缓存：这个判断只读内存里的绑定与活动状态，很便宜，
    /// 存一份没有收益。
    ///
    /// PaneView 在统一会话状态变化时推送状态色，触发此行更新；发送前仍重新检查，
    /// 避免一次点击与后台状态变化之间的竞态。
    var handoffActionProvider: (() -> HandoffAction?)?

    /// 岛体背景层：frame 由 PaneView 驱动；第一行身份内容与背景 frame 解耦，
    /// 展开时状态点和标题保持原位。
    let island = IdentityIslandView()
    /// 岛体的投影。单独一层放在岛体**后面**，内部挖空——见 IslandShadowView。
    let islandShadow = IslandShadowView()
    /// 面板的全部内容都住在岛体的裁剪层里，由长开的岛体「露出来」。
    /// 它的 frame 反向跟着岛体走（原点取岛体原点的相反数），所以内容在面板坐标系里
    /// 纹丝不动，只是被裁的范围在变。
    private let contentHost = NSView()
    /// 第一行下方的分隔线容器。
    let extras = NSView()
    /// 两页的取景框：只有页面在里面横向滑动，第一行和分隔线不动。
    private let pageViewport = NSView()
    private let detailPage = NSView()
    private var detailPageLeading: NSLayoutConstraint!
    private var pickerPageLeading: NSLayoutConstraint!
    /// 0 = 详情页，1 = 选择器页。页面位置只由它算出，面板改宽度时也能对上。
    private var pageProgress: CGFloat = 0
    private var slideTimer: Timer?

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
    /// 「让 Agent 总结并更新 handoff」：任务进行中反复要做的动作，是详情页唯一的主操作。
    private var handoffRow: IslandActionButton?
    private var lastReportedIslandHeight: CGFloat?
    // —— 详情页
    private var taskDetail: TaskDetail?
    private let detailSlot = NSView()
    private var detailSlotHeight: NSLayoutConstraint!
    private let metaLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    /// 底栏：主操作靠左，次要操作以图标靠右。三者不等宽也不居中，一眼看出谁是主操作。
    private let actionSlot = NSStackView()
    private var actionSlotHeight: NSLayoutConstraint!
    private var actionSlotTop: NSLayoutConstraint!
    /// 只建一次：`applyColors` 调得很勤，重建会打断正在 hover 的按钮。
    private lazy var secondaryActions: [IslandActionButton] = {
        let open = IslandActionButton(title: L("Open document"), symbol: "doc.text", style: .quiet, iconOnly: true)
        open.onTap = { [weak self] in self?.onOpenTaskDocument?() }
        let unbind = IslandActionButton(title: L("Unbind"), symbol: "minus.circle", style: .destructive, iconOnly: true)
        unbind.onTap = { [weak self] in self?.onUnbindTask?() }
        actionSlot.addView(open, in: .trailing)
        actionSlot.addView(unbind, in: .trailing)
        return [open, unbind]
    }()
    private var taskChipGhost: NSView?
    private var fixedContentHeight: NSLayoutConstraint!

    // —— 内联任务选择器
    private let listContainer = NSView()
    private let searchField = NSTextField()
    private lazy var backButton: IslandActionButton = {
        let back = IslandActionButton(title: L("Back"), symbol: "chevron.left", style: .quiet, iconOnly: true)
        back.onTap = { [weak self] in self?.closeTaskList() }
        return back
    }()
    private let taskScrollView = WheelAwareScrollView()
    /// 新建行和键位提示钉在列表底部，不跟候选一起滚——任务一多它们就会被挤到滚动区
    /// 外面，等于又藏起来了。
    private let listFooter = NSView()
    private let hintLabel = NSTextField(labelWithString: "")
    private let footerSeparator = NSView()
    private var footerHeightConstraint: NSLayoutConstraint?
    private let taskRowsView = FlippedRowsView()
    private var rowViews: [TaskRowView] = []
    /// 与 `rowViews` 一一对应的动作表。
    private var rowActions: [() -> Void] = []
    /// 滚动区里的候选行数、底栏里的操作行数。高度和滚动文档尺寸都靠这两个数。
    private var choiceRowCount = 0
    private var footerRowCount = 0
    /// 滚动文档的内容高度：候选行加分组标题。
    private var choiceContentHeight: CGFloat = 0
    private var choices: [TaskChoice] = []
    private var filtered: [TaskChoice] = []
    private var highlighted = 0
    private var listOpen = false
    /// 选择器是不是这次展开的入口（点任务区 / 快捷键）。是的话 esc 直接收起整个岛，
    /// 否则用户要按两次才回到终端；返回按钮始终回详情页。
    private var listIsEntryPoint = false

    var isTaskListOpen: Bool { listOpen }

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
        listOpen ? Self.headerHeight + listHeight : detailAreaHeight
    }

    private var detailAreaHeight: CGFloat {
        Self.baseHeight + detailSlotHeight.constant
            + (actionSlot.isHidden ? 0 : Self.handoffRowSpace)
    }

    private var listHeight: CGFloat {
        // 搜索行 34 + 候选视口 + 固定底栏 + 底部留白
        34 + min(max(choiceContentHeight, 26), Self.choiceViewportHeight) + Self.footerGap + footerHeight + 8
    }

    /// 底栏：分隔线 1 + 间距 4 + 每行 26 + 键位提示。
    private var footerHeight: CGFloat {
        5 + CGFloat(footerRowCount) * 26 + Self.hintHeight
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

        for v in [fixedContent, extras, pageViewport] {
            v.translatesAutoresizingMaskIntoConstraints = false
            contentHost.addSubview(v)
        }
        pageViewport.clipsToBounds = true

        // —— 第一行：与胶囊逐像素同构（dot 领距 6、间距 6、11pt medium、centerY=10）
        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = PaneIdentityMetrics.dotSize / 2

        // 两个输入框都是单行编辑器：usesSingleLineMode 只管显示截断，编辑态
        // 还要 wraps=false + isScrollable=true——否则长文本（尤其 CJK）在 20pt
        // 行高里折成两行，每行都被竖向裁一半，两行都看不清。
        for field in [nameField, searchField] {
            ShellTextFieldStyle.configure(field)
        }

        nameField.font = ShellStyle.Font.compactTitle
        nameField.delegate = self

        // —— 扩展区
        separator.wantsLayer = true

        taskField.identifier = PaneIdentityPanel.taskFieldIdentifier
        taskField.onTap = { [weak self] in self?.toggleTaskList() }

        // —— 内联任务选择器（默认隐藏；打开时岛体向下生长露出）
        listContainer.isHidden = true
        listContainer.wantsLayer = true
        searchField.font = ShellStyle.Font.compactBody
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
        separator.translatesAutoresizingMaskIntoConstraints = false
        extras.addSubview(separator)
        detailPage.translatesAutoresizingMaskIntoConstraints = false
        pageViewport.addSubview(detailPage)
        for v in [taskField, detailSlot, actionSlot] {
            v.translatesAutoresizingMaskIntoConstraints = false
            detailPage.addSubview(v)
        }
        metaLabel.font = ShellStyle.Font.caption
        metaLabel.lineBreakMode = .byTruncatingHead
        summaryLabel.font = ShellStyle.Font.compactBody
        summaryLabel.maximumNumberOfLines = HandoffSummaryText.maximumLines
        summaryLabel.cell?.truncatesLastVisibleLine = true
        summaryLabel.preferredMaxLayoutWidth = Self.summaryWidth
        for v in [metaLabel, summaryLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            detailSlot.addSubview(v)
        }
        detailSlot.clipsToBounds = true
        actionSlot.orientation = .horizontal
        actionSlot.spacing = 4
        // 主操作文字放不下时截断，不把图标按钮挤出面板。
        actionSlot.setClippingResistancePriority(.defaultLow, for: .horizontal)
        actionSlot.isHidden = true
        listContainer.translatesAutoresizingMaskIntoConstraints = false
        pageViewport.addSubview(listContainer)
        footerSeparator.wantsLayer = true
        hintLabel.font = .systemFont(ofSize: 9.5)
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        listFooter.addSubview(hintLabel)
        for v in [backButton, searchField, taskScrollView, listFooter] {
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
        fixedContentHeight = fixedContent.heightAnchor.constraint(
            equalToConstant: Self.headerHeight)
        detailSlotHeight = detailSlot.heightAnchor.constraint(equalToConstant: 0)
        actionSlotHeight = actionSlot.heightAnchor.constraint(equalToConstant: 0)
        actionSlotTop = actionSlot.topAnchor.constraint(equalTo: detailSlot.bottomAnchor)
        detailPageLeading = detailPage.leadingAnchor.constraint(equalTo: pageViewport.leadingAnchor)
        pickerPageLeading = listContainer.leadingAnchor.constraint(equalTo: pageViewport.leadingAnchor)
        NSLayoutConstraint.activate([
            fixedContent.topAnchor.constraint(equalTo: contentHost.topAnchor),
            fixedContentLeadingConstraint,
            fixedContent.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            fixedContentHeight,

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

            pageViewport.topAnchor.constraint(equalTo: fixedContent.bottomAnchor),
            pageViewport.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            pageViewport.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            pageViewport.heightAnchor.constraint(equalToConstant: Self.maxHeight - Self.headerHeight),

            detailPage.topAnchor.constraint(equalTo: pageViewport.topAnchor),
            detailPage.bottomAnchor.constraint(equalTo: pageViewport.bottomAnchor),
            detailPage.widthAnchor.constraint(equalTo: pageViewport.widthAnchor),
            detailPageLeading,

            taskField.leadingAnchor.constraint(equalTo: detailPage.leadingAnchor, constant: 8),
            taskField.trailingAnchor.constraint(equalTo: detailPage.trailingAnchor, constant: -8),
            taskField.topAnchor.constraint(equalTo: detailPage.topAnchor, constant: 6),
            taskField.heightAnchor.constraint(equalToConstant: 24),

            detailSlot.leadingAnchor.constraint(equalTo: detailPage.leadingAnchor),
            detailSlot.trailingAnchor.constraint(equalTo: detailPage.trailingAnchor),
            detailSlot.topAnchor.constraint(equalTo: taskField.bottomAnchor),
            detailSlotHeight,
            metaLabel.topAnchor.constraint(equalTo: detailSlot.topAnchor, constant: Self.detailTopGap),
            metaLabel.leadingAnchor.constraint(equalTo: detailSlot.leadingAnchor, constant: Self.detailInset),
            metaLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Self.summaryWidth),
            summaryLabel.topAnchor.constraint(equalTo: metaLabel.bottomAnchor, constant: Self.detailLineGap),
            summaryLabel.leadingAnchor.constraint(equalTo: detailSlot.leadingAnchor, constant: Self.detailInset),
            summaryLabel.widthAnchor.constraint(equalToConstant: Self.summaryWidth),

            actionSlot.leadingAnchor.constraint(equalTo: detailPage.leadingAnchor, constant: 8),
            actionSlot.trailingAnchor.constraint(equalTo: detailPage.trailingAnchor, constant: -8),
            actionSlotTop,
            actionSlotHeight,

            // —— 选择器页：与详情页并排，位置由 pageProgress 决定
            listContainer.topAnchor.constraint(equalTo: pageViewport.topAnchor),
            listContainer.widthAnchor.constraint(equalTo: pageViewport.widthAnchor),
            pickerPageLeading,
            listHeightConstraint,

            backButton.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor, constant: 8),
            // 输入框的文字排在框顶，按钮对准文字而不是框的中线。
            backButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor, constant: -2),

            searchField.topAnchor.constraint(equalTo: listContainer.topAnchor, constant: 9),
            searchField.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 4),
            searchField.trailingAnchor.constraint(
                equalTo: listContainer.trailingAnchor, constant: -12),
            searchField.heightAnchor.constraint(equalToConstant: 20),

            taskScrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 7),
            taskScrollView.leadingAnchor.constraint(
                equalTo: listContainer.leadingAnchor, constant: SidebarListScrollView.leadingMargin),
            taskScrollView.trailingAnchor.constraint(
                equalTo: listContainer.trailingAnchor, constant: -SidebarListScrollView.trailingMargin),
            taskScrollView.bottomAnchor.constraint(equalTo: listFooter.topAnchor, constant: -Self.footerGap),

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

            hintLabel.leadingAnchor.constraint(equalTo: listFooter.leadingAnchor, constant: 7),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: listFooter.trailingAnchor, constant: -4),
            hintLabel.bottomAnchor.constraint(equalTo: listFooter.bottomAnchor),
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

    /// `nameEditable` 为 false 时第一行只读：没有 hook 绑定、显示的是 agent 自己写的标题时，
    /// lightty 既改不了它（那是 agent 的会话名），也不该把用户打的字存成看不见的 pane 名。
    func update(paneName: String, taskName: String?, dot: NSColor, agent: SessionAgent?, nameEditable: Bool = true) {
        taskDetail = taskName == nil ? nil : taskDetailProvider?()
        nameField.stringValue = paneName
        nameField.isEditable = nameEditable
        boundTaskName = taskName
        dotColor = dot
        agentIcon.image = agent.flatMap { AgentSessionIcon.image(for: $0) }
        agentIconWidth.constant = agent == nil ? 0 : PaneIdentityMetrics.iconSize
        agentIconGap.constant = agent == nil ? 0 : PaneIdentityMetrics.iconGap
        applyColors()
    }

    /// PaneView renders the same model snapshot into the header and the expanded panel.
    /// `nil` = 回到绑定态静态配色。
    func applyStatusDot(_ color: NSColor?) {
        guard statusDotColor != color else { return }
        statusDotColor = color
        // 状态色变了，「能不能让 Agent 总结」多半也变了（thinking / tool 时不能）。
        // 重建走 applyColors 收口，不依赖面板是否在某个窗口子树中。
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
        backButton.apply(foreground: foreground)
        footerSeparator.layer?.backgroundColor = foreground.withAlphaComponent(0.08).cgColor
        metaLabel.textColor = foreground.withAlphaComponent(0.45)
        summaryLabel.textColor = foreground.withAlphaComponent(0.75)
        hintLabel.textColor = foreground.withAlphaComponent(0.4)
        nameField.textColor = foreground
        nameField.placeholderAttributedString = NSAttributedString(
            string: L("Name this terminal"),
            attributes: [
                .font: nameField.font ?? ShellStyle.Font.compactTitle,
                .foregroundColor: foreground.withAlphaComponent(0.3),
            ])
        agentIcon.contentTintColor = foreground
        searchField.textColor = foreground
        searchField.placeholderAttributedString = NSAttributedString(
            string: L("Search name or folder, or type a new name"),
            attributes: [
                .font: searchField.font ?? ShellStyle.Font.compactBody,
                .foregroundColor: foreground.withAlphaComponent(0.3),
            ])
        taskField.apply(taskName: boundTaskName, foreground: foreground)
        // 放在最后：`foreground` 是这个函数定下来的，在它之前建行会拿到上一轮的颜色。
        // 明暗切换、主题切换、状态变化全都经过这里，这一行的颜色也就跟着对。
        refreshDetailArea()
    }

    // MARK: - 详情页

    private static let detailInset: CGFloat = 18
    private static let detailTopGap: CGFloat = 7
    private static let detailLineGap: CGFloat = 4
    private static let detailBottomGap: CGFloat = 4
    /// 摘要按面板基准宽度折行，高度才不依赖面板何时拿到 frame；胶囊特别宽时右侧留白。
    private static let summaryWidth = panelWidth - 2 * detailInset

    /// 刷新详情页。选择器开着时也照常刷新：返回时内容已经是新的，滑动途中也不会空一块。
    private func refreshDetailArea() {
        guard detailSlotHeight != nil, actionSlotHeight != nil else { return }
        let detail = taskDetail
        if let detail {
            let folder = (detail.directory as NSString).abbreviatingWithTildeInPath
            metaLabel.stringValue = "\(folder)  ·  \(detail.updated)"
            metaLabel.toolTip = detail.directory
            summaryLabel.attributedStringValue = HandoffSummaryText.attributed(
                detail.summary, font: ShellStyle.Font.compactBody,
                color: foreground.withAlphaComponent(0.75))
            let lines = ceil(summaryLabel.intrinsicContentSize.height)
            detailSlotHeight.constant = Self.detailTopGap + ceil(metaLabel.intrinsicContentSize.height)
                + Self.detailLineGap + lines + Self.detailBottomGap
        } else {
            detailSlotHeight.constant = 0
        }
        detailSlot.isHidden = detail == nil
        refreshHandoffRow()
        let footerVisible = handoffRow != nil || detail != nil
        secondaryActions.forEach {
            $0.isHidden = detail == nil
            $0.apply(foreground: foreground)
        }
        actionSlot.isHidden = !footerVisible
        actionSlotHeight.constant = footerVisible ? IslandActionButton.height : 0
        actionSlotTop.constant = footerVisible ? 6 : 0
        needsLayout = true
        window?.invalidateCursorRects(for: self)
        reportIslandHeight()
    }

    /// 岛体高度真的变了才通知：`applyColors` 调得很勤（明暗切换、每次状态推送），
    /// 每次都喊一嗓子会在形变过程中和动画抢方向盘。
    private func reportIslandHeight() {
        let height = currentIslandHeight
        guard height != lastReportedIslandHeight else { return }
        lastReportedIslandHeight = height
        onIslandHeightChange?(height)
    }

    /// 胶囊任务区的位图：胶囊隐身后留在原位淡出，第一行右侧才不会突然空掉。
    func installTaskChipGhost(_ image: NSImage, frameInCapsule frame: NSRect) {
        taskChipGhost?.removeFromSuperview()
        let ghost = PassthroughImageView(image: image)
        ghost.wantsLayer = true
        ghost.translatesAutoresizingMaskIntoConstraints = false
        fixedContent.addSubview(ghost)
        NSLayoutConstraint.activate([
            ghost.leadingAnchor.constraint(equalTo: fixedContent.leadingAnchor, constant: frame.minX),
            ghost.centerYAnchor.constraint(equalTo: dotView.centerYAnchor),
            ghost.widthAnchor.constraint(equalToConstant: frame.width),
            ghost.heightAnchor.constraint(equalToConstant: frame.height),
        ])
        taskChipGhost = ghost
    }

    func fadeTaskChipGhost(visible: Bool, duration: TimeInterval) {
        guard let taskChipGhost else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : duration
            taskChipGhost.animator().alphaValue = visible ? 1 : 0
        }
    }

    // MARK: - 让 Agent 总结

    /// 重建「让 Agent 总结并更新 handoff」按钮。
    ///
    /// `handoffActionProvider` 返回 nil = 按钮不出现（认不出这个 pane 里跑的是哪家 agent，
    /// 见该属性的注释）。每次重建：文字颜色、禁用态都在 init 里定死。
    private func refreshHandoffRow() {
        // `applyColors` 会经由 `viewDidChangeEffectiveAppearance` 在很早的时刻被调到，
        // 约束还没建好就什么都不做。
        guard actionSlotHeight != nil else { return }
        handoffRow = nil
        actionSlot.setViews([], in: .leading)

        if boundTaskName != nil, let availability = handoffActionProvider?() {
            let blockedReason: String? = {
                guard case .blocked(let reason) = availability else { return nil }
                return reason
            }()
            let row = IslandActionButton(
                title: L("Have the Agent summarize it"), symbol: "sparkles", style: .primary,
                detail: blockedReason, enabled: blockedReason == nil)
            row.apply(foreground: foreground)
            row.identifier = Self.handoffRowIdentifier
            actionSlot.setViews([row], in: .leading)
            if blockedReason == nil {
                row.onTap = { [weak self] in
                    guard let self else { return }
                    // 送不出去就别关面板。这一行的可点状态是上一次重建时算的，
                    // 面板开着的这段时间 agent 可能已经转忙；关掉面板等于告诉
                    // 用户"做了"。重建一次让它当场变灰，用户看得见为什么。
                    guard self.onUpdateHandoff?() == true else {
                        self.refreshHandoffRow()
                        return
                    }
                    self.onDismiss?()
                }
            }
            handoffRow = row
        }
    }

    // MARK: - 翻页

    /// 选择器页从右向左推入，返回时反向。和岛体高度变化各走各的时钟：一个管横向位移，
    /// 一个管纵向裁切，互不依赖。没上窗口（首次展开前）或减少动态效果时直接到位。
    private func slidePages(to target: CGFloat) {
        slideTimer?.invalidate()
        slideTimer = nil
        detailPage.isHidden = false
        listContainer.isHidden = false
        let start = pageProgress
        func finish() {
            pageProgress = target
            applyPageOffsets()
            detailPage.isHidden = target == 1
            listContainer.isHidden = target == 0
            window?.invalidateCursorRects(for: self)
        }
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            finish()
            return
        }
        let duration = 0.24
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let progress = min(1, (CACurrentMediaTime() - began) / duration)
            self.pageProgress = start + (target - start) * CGFloat(1 - pow(1 - progress, 3))
            self.applyPageOffsets()
            self.layoutSubtreeIfNeeded()
            if progress >= 1 {
                timer.invalidate()
                self.slideTimer = nil
                finish()
            }
        }
        slideTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func applyPageOffsets() {
        guard let detailPageLeading, let pickerPageLeading else { return }
        detailPageLeading.constant = -bounds.width * pageProgress
        pickerPageLeading.constant = bounds.width * (1 - pageProgress)
    }

    /// 面板在展开前才拿到宽度，这里补上那时算不出的页面位置。
    override func layout() {
        applyPageOffsets()
        super.layout()
    }

    // MARK: - 任务选择器

    /// 任务行的动作：切到选择器页；已在选择器页则返回。
    func toggleTaskList() {
        listOpen ? closeTaskList() : openTaskList()
    }

    /// 以选择器作为这次展开的入口：胶囊任务区或快捷键。
    func openTaskPicker() {
        listIsEntryPoint = true
        if !listOpen { openTaskList() }
    }

    private func openTaskList() {
        choices = taskProvider?() ?? []
        searchField.stringValue = ""
        listOpen = true
        // Build the final list geometry before revealing it through the island clip.
        applyFilter("")
        applyColors()
        slidePages(to: 1)
        window?.makeFirstResponder(searchField)
    }

    private func closeTaskList() {
        resetListState()
        applyColors()
        slidePages(to: 0)
        focusInitialField()
    }

    private func resetListState() {
        listOpen = false
        listIsEntryPoint = false
        scrollSettle?.cancel()
        scrollSettle = nil
        isScrolling = false
        pointerScrolled = false
    }

    /// 整个岛要收起了：不翻回详情页，当前页留在原位随岛体缩回。
    private func dismissFromTaskList() {
        resetListState()
        onDismiss?()
    }

    private func applyFilter(_ query: String) {
        pointerScrolled = false
        noteScrollActivity()
        filtered = Self.rank(choices, query: query)
        rebuildRows()
    }

    /// 候选排序。无输入：此目录的在前，其余保持传入序（最近更新）。有输入：名字命中排在
    /// 目录命中之前，同档按匹配分，再把此目录的提前。目录只匹配末级，整条路径里到处
    /// 都是 `/Users/…` 的字母，匹配它等于什么都能搜到。
    static func rank(_ choices: [TaskChoice], query: String) -> [TaskChoice] {
        let keyed = choices.enumerated().compactMap { offset, choice -> (TaskChoice, [Int])? in
            let nearby = choice.nearby ? 0 : 1
            if query.isEmpty { return (choice, [nearby, offset]) }
            if let score = FuzzyMatch.score(pattern: query, in: choice.name) {
                return (choice, [0, -score, nearby, offset])
            }
            let folder = choice.directory.map { ($0 as NSString).lastPathComponent } ?? ""
            guard let score = FuzzyMatch.score(pattern: query, in: folder) else { return nil }
            return (choice, [1, -score, nearby, offset])
        }
        return keyed.sorted { $0.1.lexicographicallyPrecedes($1.1) }.map(\.0)
    }

    private func rebuildRows() {
        taskRowsView.subviews.filter { !($0 is TaskRowView) }.forEach { $0.removeFromSuperview() }
        choiceContentHeight = 0
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = []
        rowActions = []
        choiceRowCount = 0
        footerRowCount = 0

        listFooter.subviews.filter { $0 !== footerSeparator && $0 !== hintLabel }
            .forEach { $0.removeFromSuperview() }
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
                choiceContentHeight += 26
            }
            rowViews.append(row)
            rowActions.append(action)
        }

        /// 分组标题和空状态只是文字，不进 `rowViews`：上下键和回车都够不着它。
        func addCaption(_ text: String) {
            let caption = NSTextField(labelWithString: text)
            caption.font = .systemFont(ofSize: 9.5, weight: .medium)
            caption.textColor = foreground.withAlphaComponent(0.4)
            let holder = NSView()
            caption.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(caption)
            NSLayoutConstraint.activate([
                caption.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 7),
                caption.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            ])
            attach(row: holder, to: taskRowsView, below: previousChoice, gap: previousChoice == nil ? 0 : 2)
            previousChoice = holder
            choiceContentHeight += 26
        }

        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        // 只有两组都有内容时才分组，否则标题不提供任何信息。搜索时按匹配度排，也不分组。
        let groups = query.isEmpty && filtered.contains(where: \.nearby) && filtered.contains { !$0.nearby }
        for (index, choice) in filtered.enumerated() {
            if groups, index == 0 { addCaption(L("This folder")) }
            if groups, index > 0, filtered[index - 1].nearby, !choice.nearby { addCaption(L("Other folders")) }
            add(TaskRowView(
                title: choice.name,
                detail: Self.rowDetail(for: choice),
                checked: choice.current,
                role: .choice,
                foreground: foreground)) { [weak self] in self?.pick(index) }
            rowViews.last?.toolTip = choice.directory
        }
        if filtered.isEmpty {
            addCaption(query.isEmpty ? L("No tasks yet") : L("No matching tasks."))
        }
        // 有输入就常驻新建行。模糊匹配很宽，只在零匹配时给新建，用户就建不了名字相近的任务。
        if !query.isEmpty {
            add(TaskRowView(
                title: L("New task “%@”", query),
                detail: filtered.isEmpty ? "↩" : "⌘↩", checked: false, role: .action,
                foreground: foreground), toFooter: true) { [weak self] in self?.createFromQuery() }
        }
        hintLabel.stringValue = {
            if query.isEmpty { return filtered.isEmpty ? "" : L("↩ Bind") }
            return filtered.isEmpty ? L("↩ New") : L("↩ Bind · ⌘↩ New")
        }()
        // 岛体最多展示七行候选；更多任务留在原生滚动视口内，不能继续撑高面板。
        taskRowsView.frame = NSRect(
            x: 0, y: 0, width: taskScrollView.contentSize.width,
            height: max(choiceContentHeight - 2, 0))
        footerHeightConstraint?.constant = footerHeight
        listHeightConstraint?.constant = listHeight

        if listOpen { reportIslandHeight() }
        layoutSubtreeIfNeeded()
        setHighlight(firstEnabledRow(), scroll: true)
        window?.invalidateCursorRects(for: self)
    }

    private var listHeightConstraint: NSLayoutConstraint?

    /// 候选行尾注：活跃优先于时间，因为另一个终端正开着它比「多久前改过」更影响选择。
    private static func rowDetail(for choice: TaskChoice) -> String? {
        let folder = choice.directory.map { ($0 as NSString).lastPathComponent }
        let time = choice.running ? L("Active") : choice.updated.map { RelativeTime.text($0, localize: { L($0) }) }
        let parts = [folder, time].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func attach(row: NSView, to container: NSView,
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

    /// 从 `index` 出发按 `step` 找下一个点得动的行；找不到就留在原地（到头了）。
    ///
    /// 上下键必须跳过禁用行：停在上面它会亮起来、看着能按，按下去却什么都不发生，
    /// 列表连关都不关。鼠标那条路早就挡住了（`TaskRowView.mouseEntered`），键盘这条
    /// 一直漏着。
    private func nextEnabledRow(from index: Int, step: Int) -> Int {
        var candidate = index + step
        while rowViews.indices.contains(candidate) {
            if rowViews[candidate].enabled { return candidate }
            candidate += step
        }
        return index
    }

    /// 重建之后落脚的第一行。跳过禁用行。列表里现在没有会被禁用的行了（唯一那条
    /// 已经提到第一层），但这两个helper 保持按 `enabled` 走：下一条禁用行进来时
    /// 不必再想起这件事，而代价只是一次 `firstIndex`。
    private func firstEnabledRow() -> Int {
        rowViews.firstIndex(where: { $0.enabled }) ?? 0
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

    /// 挑完就回到终端：这是一次性动作，留着岛体只会挡住刚要开始干活的终端。
    private func pick(_ index: Int) {
        guard filtered.indices.contains(index) else { return }
        onBindTask?(filtered[index].fileURL)
        dismissFromTaskList()
    }

    private func createFromQuery() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        onCreateTask?(query)
        dismissFromTaskList()
    }

    /// esc：这次是从任务区直接进来的就整个收起，否则退回详情页。
    private func leaveTaskList() {
        listIsEntryPoint ? dismissFromTaskList() : closeTaskList()
    }

    /// 回车：执行当前高亮行登记的动作。空列表（没有任务、也没输入）时直接收起。
    private func commitList() {
        guard rowActions.indices.contains(highlighted) else {
            closeTaskList()
            return
        }
        rowActions[highlighted]()
    }

    // MARK: - 交互

    /// 展开动画收尾时把光标放到该放的地方：列表开着就是搜索框，否则是 pane 名。
    func focusInitialField() {
        if listOpen {
            window?.makeFirstResponder(searchField)
        } else {
            window?.makeFirstResponder(nameField)
            nameField.currentEditor()?.selectAll(nil)
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
            } else if control === searchField {
                commitList()
            }
            return true
        case #selector(NSResponder.moveDown(_:)) where control === searchField:
            setHighlight(nextEnabledRow(from: highlighted, step: 1), scroll: true)
            return true
        case #selector(NSResponder.moveUp(_:)) where control === searchField:
            setHighlight(nextEnabledRow(from: highlighted, step: -1), scroll: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if control === searchField {
                leaveTaskList()
            } else {
                onDismiss?()
            }
            return true
        default:
            return false
        }
    }

    /// ⌘回车在字段编辑器里没有默认命令，走按键等价路径。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        guard listOpen, isReturn, event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        createFromQuery()
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        if listOpen {
            leaveTaskList()
        } else {
            onDismiss?()
        }
    }

}

/// 岛体里的按钮。主操作带文字和常驻底色，次要操作只有图标、指上去才显底，
/// 两者一眼分得开；图标按钮的文字进 tooltip 和辅助功能。
final class IslandActionButton: NSView {
    static let height: CGFloat = 26
    enum Style { case primary, quiet, destructive }

    var onTap: (() -> Void)?
    private let style: Style
    private let enabled: Bool
    private let icon = NSImageView()
    private let label: NSTextField
    private let detailLabel: NSTextField
    private var foreground = NSColor.labelColor
    private var hovered = false { didSet { applyColors() } }
    private var pressed = false { didSet { applyColors() } }

    init(title: String, symbol: String, style: Style, detail: String? = nil,
         enabled: Bool = true, iconOnly: Bool = false) {
        self.style = style
        self.enabled = enabled
        label = NSTextField(labelWithString: iconOnly ? "" : title)
        detailLabel = NSTextField(labelWithString: detail ?? "")
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        if enabled { HoverCursor.installPointingHand(on: self) }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        var constraints = [
            heightAnchor.constraint(equalToConstant: Self.height),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if iconOnly {
            toolTip = title
            constraints += [
                widthAnchor.constraint(equalToConstant: Self.height),
                icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            ]
        } else {
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.init(rawValue: 240), for: .horizontal)
            detailLabel.font = .systemFont(ofSize: 9.5)
            for view in [label, detailLabel] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            constraints += [
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
                icon.widthAnchor.constraint(equalToConstant: 13),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                detailLabel.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: detail == nil ? 0 : 8),
                detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityEnabled(enabled)
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(foreground: NSColor) {
        self.foreground = foreground
        applyColors()
    }

    private func applyColors() {
        let appearance = effectiveAppearance
        let tint: NSColor
        let fillBase: NSColor
        let fill: CGFloat
        switch style {
        case .primary:
            tint = ShellStyle.navigationAccent
            fillBase = tint
            fill = pressed ? 0.28 : hovered ? 0.22 : 0.14
        case .quiet:
            tint = foreground.withAlphaComponent(hovered ? 0.85 : 0.55)
            fillBase = foreground
            fill = pressed ? 0.15 : hovered ? 0.1 : 0
        case .destructive:
            // 平时和其他图标一样安静，指上去才亮出红色，避免在面板上长期吸引视线。
            tint = hovered ? .systemRed : foreground.withAlphaComponent(0.55)
            fillBase = .systemRed
            fill = pressed ? 0.2 : hovered ? 0.12 : 0
        }
        layer?.backgroundColor = fillBase.withAlphaComponent(enabled ? fill : 0.04)
            .shellResolvedCGColor(for: appearance)
        let text = enabled ? tint : foreground.withAlphaComponent(0.3)
        label.textColor = text
        icon.contentTintColor = text
        detailLabel.textColor = foreground.withAlphaComponent(0.4)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func mouseEntered(with event: NSEvent) { if enabled { hovered = true } }
    override func mouseExited(with event: NSEvent) { hovered = false; pressed = false }

    // 点不动的按钮也吃掉 mouseDown：穿下去会关掉面板，看着像"点了没反应"。
    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        pressed = true
    }

    override func mouseUp(with event: NSEvent) {
        guard enabled, pressed else { return }
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onTap?() }
    }
}

/// 把 handoff 摘要的 Markdown 排成岛体里的文字：Agent 写的是给下一个 Agent 看的 Markdown，
/// 标记符原样显示很吵，但这里只是预览，不需要完整渲染器（完整内容走「打开文档」）。
enum HandoffSummaryText {
    static let maximumLines = 6

    /// 去掉空行和节头，只留前几行。摘要是预览，空行在六行的额度里太奢侈。
    static func lines(of markdown: String) -> [String] {
        markdown.split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
            .prefix(maximumLines).map { $0 }
    }

    /// `**粗体**` 与 `` `代码` `` 转成字体变化，配不上对的标记按原文保留。
    static func attributed(_ markdown: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.lineBreakMode = .byWordWrapping
        let bold = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
        let code = NSFont.monospacedSystemFont(ofSize: font.pointSize - 0.5, weight: .regular)
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        let result = NSMutableAttributedString()
        let pattern = try! NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*|`([^`]+)`")
        let text = lines(of: markdown).joined(separator: "\n") as NSString
        var cursor = 0
        for match in pattern.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
            result.append(NSAttributedString(
                string: text.substring(with: NSRange(location: cursor, length: match.range.location - cursor)),
                attributes: base))
            var attributes = base
            let inner: String
            if match.range(at: 1).location != NSNotFound {
                inner = text.substring(with: match.range(at: 1)).replacingOccurrences(of: "`", with: "")
                attributes[.font] = bold
            } else {
                inner = text.substring(with: match.range(at: 2))
                attributes[.font] = code
            }
            result.append(NSAttributedString(string: inner, attributes: attributes))
            cursor = match.range.location + match.range.length
        }
        result.append(NSAttributedString(string: text.substring(from: cursor), attributes: base))
        return result
    }
}

/// 不接收鼠标的图片：只用来显示，点击落到下面的控件。
private final class PassthroughImageView: NSImageView {
    convenience init(image: NSImage) {
        self.init(frame: .zero)
        self.image = image
        imageScaling = .scaleNone
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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

    /// 点不动的行：文字压暗、不给手型光标、不高亮、`onTap` 不触发。
    /// 只用在「这个操作现在做不了，但值得让用户看见它存在」——理由写在 `detail`
    /// 里，藏掉整行等于让用户以为功能不存在。
    ///
    /// 面板要读它来跳过键盘高亮（见 `nextEnabledRow`），所以不是 private。
    let enabled: Bool

    init(title: String, detail: String?, checked: Bool, role: Role,
         foreground: NSColor, enabled: Bool = true) {
        self.rowForeground = foreground
        self.enabled = enabled
        super.init(frame: .zero)
        if enabled { HoverCursor.installPointingHand(on: self) }
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
        label.font = ShellStyle.Font.compactBody
        label.lineBreakMode = .byTruncatingTail
        switch role {
        case .choice: label.textColor = foreground.withAlphaComponent(0.85)
        case .action: label.textColor = ShellStyle.navigationAccent
        case .destructive: label.textColor = .systemRed
        }
        if !enabled { label.textColor = foreground.withAlphaComponent(0.3) }

        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let detailLabel = NSTextField(labelWithString: detail ?? "")
        detailLabel.font = .systemFont(ofSize: 9.5)
        detailLabel.textColor = foreground.withAlphaComponent(0.4)
        detailLabel.lineBreakMode = .byTruncatingMiddle

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
            // 没有尾注时文字用满整行，空标签也不占位。
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: detail == nil ? trailingAnchor : detailLabel.leadingAnchor, constant: -8),

            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 150),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyFill()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 禁用行即便被标成高亮也不上底色：上了色它就跟可点的行长得一样，
    /// 而按下去什么都不会发生。
    private func applyFill() {
        layer?.backgroundColor = highlighted && enabled
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

    // 点不动的行照样吃掉 mouseDown：让它穿到底下去会关掉面板，看着像"点了没反应"。
    // 高亮由面板统一管（移到哪一行、上下键走到哪一行），这里只发 `onHover`。
    override func mouseEntered(with event: NSEvent) {
        guard enabled else { return }
        onHover?()
    }

    override func mouseDown(with event: NSEvent) { guard enabled else { return }; onTap?() }
}


/// 任务行：常驻浅底、右端一个向右的箭头，说明点它会进入下一页。
/// 和第一行（pane 名，点了直接打字）行为不同，所以长得也不同。
private final class TaskFieldRow: NSView {
    var onTap: (() -> Void)?

    private let caption = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { applyFill() } }
    private var restingFill = NSColor.clear
    private var hoverFill = NSColor.clear

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        HoverCursor.installPointingHand(on: self)

        caption.font = ShellStyle.Font.caption
        value.font = ShellStyle.Font.compactBody
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

    func apply(taskName: String?, foreground: NSColor) {
        caption.stringValue = L("Task")
        caption.textColor = foreground.withAlphaComponent(0.45)
        value.stringValue = taskName ?? L("Not set")
        value.textColor = foreground.withAlphaComponent(taskName == nil ? 0.4 : 0.85)
        chevron.image = NSImage(
            systemSymbolName: "chevron.right",
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
