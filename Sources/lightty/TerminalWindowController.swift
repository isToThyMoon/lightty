import AppKit
import LighttyCore

/// 窗口内的一个 tab：固定容器 + pane 树。tab 是 lightty 概念（切换只换主区域
/// 内容），不是 macOS 原生 tab（那是多 NSWindow 结组，已弃用）。
final class TerminalTab {
    let id = UUID()
    /// 固定 wrapper：挂在 contentHost 里，isHidden 控制显隐；
    /// split 重组只替换其内部的树，wrapper 本身与约束不动。
    let container = NSView()
    /// pane 树根（container 的唯一 subview）：单 pane 或嵌套 NSSplitView。
    fileprivate(set) var rootView: NSView?
    /// 标签页名：会话态，双击 tab 标签改，不从 pane/任务派生、不落盘。
    var title = L("Tab")

    init() {
        container.translatesAutoresizingMaskIntoConstraints = false
    }
}

/// 层级：window（1 侧边栏 + 1 tab 条）→ tab（pane 树容器）→ split 布局 → pane。
/// core new_tab 在当前窗口追加 tab；new_split 改当前 tab 的 pane tree，
/// 并继承当前任务；方向一致插相邻位、方向不同原位包反向 split。
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    private let rootContainer = NSView()
    /// 主体区（tab 条 + tab 内容），随侧栏钉住向右推移。
    private let mainArea = NSView()
    private let tabStrip = TabStripView()
    private let contentHost = NSView()
    private var tabStripHeightConstraint: NSLayoutConstraint?
    private var tabs: [TerminalTab] = []
    private var activeTabIndex = 0
    /// 会话恢复出的窗口：frame 来自快照，不再由 core 的 INITIAL_SIZE 重设。
    var suppressesInitialSize = false
    /// 首帧侧栏布局（默认 task 开、标签页栏关；恢复时按快照）
    private var initialTaskPanelOpen = true
    private var initialTabSidebarOpen = false
    /// 恢复中的快照：frame 与分隔线比例要等侧栏就位后再应用（侧栏展开会改布局，
    /// 先设 frame 会被改回默认宽）。
    private var pendingRestore: WindowSnapshot?
    private var activeTab: TerminalTab? {
        tabs.indices.contains(activeTabIndex) ? tabs[activeTabIndex] : nil
    }
    var tabCount: Int { tabs.count }
    /// pinned 侧栏是 docked layout：主体区从侧栏右缘开始；preview 保持 overlay。
    private var rootLeadingConstraint: NSLayoutConstraint?
    private weak var sidebarButton: ShellIconButton?
    private var tabSidebar: TabSidebarView?
    private var tabSidebarLeadingConstraint: NSLayoutConstraint?
    private var tabSidebarWidthConstraint: NSLayoutConstraint?
    private var tabSidebarWidth = TabSidebarWidthPreference.width()
    private var tabSidebarResizeActive = false
    private var taskPanel: TaskSidebar?
    /// 设置页（整窗覆盖，垫在标题栏容器之下）
    private var settingsView: SettingsView?
    private var settingsWidthConstraint: NSLayoutConstraint?
    /// 全部标签页关闭后的空态视图（task 为核心，不退出软件）。
    private var emptyStateView: EmptyTabView?
    private var taskPanelLeadingConstraint: NSLayoutConstraint?
    /// 标签页侧栏的吸边开关：开着时吸在其右边线（关闭钮），关着时吸在主区左缘
    /// （展开钮，带 hover 感应带）。
    private var tabEdgeControl: EdgeToggleControl?
    private var tabEdgeStrip: EdgeRevealStrip?
    /// 展开钮的 x（主区左缘）：task 卡片开合时随让位一起动画
    private var tabEdgeLeadingConstraint: NSLayoutConstraint?
    private var sidebarLayoutAnimationTimer: Timer?

    /// 逐帧驱动约束 + 逐帧 layout：terminal surface 每帧按当前宽度真实 resize/重排
    /// （与拖动分屏线同一路径）。隐式动画只会"滑过去后一次性重排"，观感是跳变。
    /// ghostty 每次 resize 会 clearPromptForRedraw（清空活跃行等 shell SIGWINCH
    /// 重绘），通过 ghostty_surface_set_prompt_clear_on_resize 在动画期间关闭
    /// prompt 清空，prompt 随宽度自然 reflow 不再闪烁。
    private func animateSidebarLayout(
        _ targets: [(NSLayoutConstraint, CGFloat)],
        duration: TimeInterval = ShellStyle.sidebarAnimationDuration,
        completion: (() -> Void)? = nil
    ) {
        stopSidebarAnimationDriver()
        guard let themeFrame = window?.contentView?.superview else {
            targets.forEach { $0.0.constant = $0.1 }
            completion?()
            return
        }
        // 滑动期间关掉 hover：控件从静止指针下经过会闪一串瞬态 hover
        // （并因 AppKit 漏发 exited 而卡住）。驱动器停下时放开并重算。
        ShellHoverGate.suppress()
        let terminals = panes().map(\.terminal)
        terminals.forEach { $0.setPromptClearOnResize(false) }
        let starts = targets.map { $0.0.constant }
        let begin = CACurrentMediaTime()
        sidebarAnimationStep = { [weak self, weak themeFrame] in
            let progress = min(1, (CACurrentMediaTime() - begin) / duration)
            // easeInOutCubic：起步收尾都柔和（实测优于 easeOutExpo——
            // expo 的瞬时起步在真实 reflow 的终端上反而显得急）
            let eased = progress < 0.5
                ? 4 * progress * progress * progress
                : 1 - pow(-2 * progress + 2, 3) / 2
            for (index, target) in targets.enumerated() {
                target.0.constant = starts[index] + (target.1 - starts[index]) * CGFloat(eased)
            }
            themeFrame?.layoutSubtreeIfNeeded()
            if progress >= 1 {
                self?.stopSidebarAnimationDriver()
                terminals.forEach { $0.setPromptClearOnResize(true) }
                completion?()
            }
        }
        startSidebarAnimationDriver()
    }

    /// 帧驱动器：优先 CADisplayLink（与 vsync 对齐，消除 Timer 抖动，
    /// macOS 14+），旧系统回退 120Hz Timer。progress 按真实时间计算，
    /// 掉帧只会跳帧不会拖慢。
    private var sidebarAnimationStep: (() -> Void)?
    private var sidebarCADisplayLink: Any?

    private func startSidebarAnimationDriver() {
        if #available(macOS 14.0, *), let view = window?.contentView {
            let link = view.displayLink(target: self, selector: #selector(sidebarDisplayTick))
            // ProMotion 屏默认只给 60Hz，高帧率必须显式申请
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            sidebarCADisplayLink = link
        } else {
            let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
                self?.sidebarAnimationStep?()
            }
            RunLoop.main.add(timer, forMode: .common)
            sidebarLayoutAnimationTimer = timer
        }
    }

    @objc private func sidebarDisplayTick() {
        sidebarAnimationStep?()
    }

    private func stopSidebarAnimationDriver() {
        if #available(macOS 14.0, *) {
            (sidebarCADisplayLink as? CADisplayLink)?.invalidate()
        }
        sidebarCADisplayLink = nil
        sidebarLayoutAnimationTimer?.invalidate()
        sidebarLayoutAnimationTimer = nil
        sidebarAnimationStep = nil
        // 完成或被打断都算滑动结束（打断者会立刻再次关闸）
        ShellHoverGate.release(in: window)
    }

    private weak var titlebarChrome: NSView?
    private weak var lastFocusedPane: PaneView?
    private weak var zoomedPane: PaneView?

    init(initialPane: PaneView = PaneView()) {
        let window = TerminalWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640))
        // 新建 surface 的窗口先保持透明：contentRect 只是占位，真实尺寸要等 core 的
        // INITIAL_SIZE（window-width/height × cell）异步到达。若此时就露脸，用户会
        // 看到空壳小窗再跳成正式尺寸的两段闪。surface 已存在的 pane（拖出成窗）
        // 不会再收到 INITIAL_SIZE，直接正常显示。
        let expectsInitialSize = initialPane.terminal.surface == nil
        super.init(window: window)
        window.delegate = self
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesDidChange),
            name: .lighttyPreferencesDidChange, object: nil)
        window.center()
        if expectsInitialSize {
            window.alphaValue = 0
            // 兜底：INITIAL_SIZE 丢失/被 guard 挡下也必须显形
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.revealWindowIfNeeded()
            }
        }

        rootContainer.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = rootContainer
        installMainArea()
        install(pane: initialPane)
        lastFocusedPane = initialPane
        addTab(initialPane: initialPane, select: true, installPane: false)
        installTitlebarAccessory(on: window)
        updateWindowTitle(for: initialPane)
        // AppKit 会在 makeKeyAndOrderFront 前后替换一次私有标题栏树；下一轮布局后
        // 再 ensure，避免控件只存在于已脱离窗口的旧 titlebar 中。
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.installTitlebarAccessory(on: window)
            self.updateWindowTitle(for: self.activePane)
            // 默认布局：task 侧栏（核心）打开，标签页侧栏收起；恢复的窗口按快照
            // （不做滑入动画，随后一次性落 frame 和分隔线比例）。
            let restoring = self.pendingRestore != nil
            if self.initialTabSidebarOpen { self.openTabSidebar(animated: false) }
            if self.initialTaskPanelOpen { self.openTaskPanel(animated: !restoring) }
            self.installTabEdgeControl()
            if let snapshot = self.pendingRestore {
                self.pendingRestore = nil
                self.finishRestore(snapshot)
            }
        }
    }

    /// INITIAL_SIZE 应用后（或兜底超时）把窗口从透明占位态显形。幂等。
    func revealWindowIfNeeded() {
        guard let window, window.alphaValue < 1 else { return }
        window.alphaValue = 1
    }

    /// 标题栏操作区：三键后只保留抽屉开关。新标签页与分屏操作归入标签页侧栏
    /// 标题行，使右侧 terminal 可以延伸到窗口顶边，不再有一条全宽操作栏。
    /// 直接挂进标题栏视图并以缩放键锚点对齐，保证与红绿灯严格同一水平线。
    /// ⚠️ 标题栏是私有视图，会在侧边栏插拔/全屏切换时重建并丢掉外来子视图——
    /// 所以做成幂等的 ensure：掉了就重装（toggle 与窗口激活时都会调）。
    private func installTitlebarAccessory(on window: NSWindow) {
        guard let zoomButton = window.standardWindowButton(.zoomButton),
              let titlebar = zoomButton.superview else { return }
        // 私有标题栏重建后，旧 chrome 仍可能有 window/superview；必须和当前三键
        // 所在的 titlebar 做对象身份比较。
        if let chrome = titlebarChrome, chrome.superview === titlebar { return }
        titlebarChrome?.removeFromSuperview()

        // 穿透容器：chrome 铺满标题栏，但空白处点击必须落到下层的红黄绿三键
        let chrome = ShellPassthroughView()
        // 不 pin 外观：壳层 palette 已是明暗动态色，随系统切换。
        chrome.translatesAutoresizingMaskIntoConstraints = false
        titlebar.addSubview(chrome)

        let button = ShellIconButton(
            symbol: "sidebar.left", accessibilityLabel: L("Task Sidebar"), target: self,
            action: #selector(toggleSidebarFromTitlebar))

        button.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(button)
        NSLayoutConstraint.activate([
            chrome.leadingAnchor.constraint(equalTo: titlebar.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: titlebar.trailingAnchor),
            chrome.topAnchor.constraint(equalTo: titlebar.topAnchor),
            chrome.bottomAnchor.constraint(equalTo: titlebar.bottomAnchor),

            button.leadingAnchor.constraint(equalTo: zoomButton.trailingAnchor, constant: 9),
            button.centerYAnchor.constraint(equalTo: zoomButton.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 24),
        ])

        titlebarChrome = chrome
        sidebarButton = button
        updateSidebarButtonState()
    }

    private func updateWindowTitle(for pane: PaneView?) {
        guard let window else { return }
        // tab 名 = 标签页名（用户所有），不再从 pane/任务派生。
        // 系统标题不显示；window.title 只喂 cmd-tab、Mission Control 等系统 UI。
        _ = pane
        window.titleVisibility = .hidden
        window.title = activeTab?.title ?? "lightty"
    }

    /// 侧栏按钮 = task 卡片开关。卡片开着时它挪进卡片头部行（点了收起），
    /// 标题栏那一枚隐藏（否则会落在卡片里的红绿灯旁边、与头部行按钮重复）。
    private func updateSidebarButtonState() {
        sidebarButton?.isHidden = taskPanel != nil || settingsView != nil
        SessionStore.shared.scheduleSave()  // task 卡片开合入快照
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window else { return }
        installTitlebarAccessory(on: window)
        updateWindowTitle(for: activePane)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.installTitlebarAccessory(on: window)
            self.updateWindowTitle(for: self.activePane)
        }
    }

    /// 私有标题栏可能在 becomeKey 回调之后才完成替换；windowDidUpdate 是稳定的
    /// 最终兜底。ensure 有对象身份保护，正常帧不会重复创建控件。
    func windowDidUpdate(_ notification: Notification) {
        guard let window else { return }
        installTitlebarAccessory(on: window)
        updateWindowTitle(for: activePane)
    }

    /// 全屏时标题栏随菜单栏自动浮现，空 toolbar 会跟着露出一条空玻璃条；全屏期间藏掉。
    func windowWillEnterFullScreen(_ notification: Notification) {
        window?.toolbar?.isVisible = false
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        window?.toolbar?.isVisible = true
    }

    @objc private func toggleSidebarFromTitlebar() {
        toggleSidebar()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 主体区（tab 条 + tab 内容）

    /// rootContainer → mainArea（leading 随侧栏钉住推移）→ [tabStrip, contentHost]。
    /// tab 切换只翻转各 tab container 的 isHidden，视图不出层级、surface 不重建。
    private func installMainArea() {
        mainArea.translatesAutoresizingMaskIntoConstraints = false
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        // 侧栏区 chrome 底毯：主区让位后左侧露出的窗口透明底（桌面壁纸）
        // 由它兜住——task 悬浮卡片要浮在 chrome 面上，不是浮在"洞"上。
        // trailing 锚在主区左缘，随让位动画自动伸缩，无需参与动画编排。
        let underlay = ShellBackdropView(fill: ShellStyle.sidebarBackground)
        underlay.translatesAutoresizingMaskIntoConstraints = false
        rootContainer.addSubview(underlay)
        rootContainer.addSubview(mainArea)
        mainArea.addSubview(tabStrip)
        mainArea.addSubview(contentHost)

        let leading = mainArea.leadingAnchor.constraint(
            equalTo: rootContainer.leadingAnchor)
        rootLeadingConstraint = leading
        let stripHeight = tabStrip.heightAnchor.constraint(equalToConstant: 0)
        tabStripHeightConstraint = stripHeight
        NSLayoutConstraint.activate([
            underlay.leadingAnchor.constraint(equalTo: rootContainer.leadingAnchor),
            underlay.topAnchor.constraint(equalTo: rootContainer.topAnchor),
            underlay.bottomAnchor.constraint(equalTo: rootContainer.bottomAnchor),
            underlay.trailingAnchor.constraint(equalTo: mainArea.leadingAnchor),

            leading,
            mainArea.topAnchor.constraint(equalTo: rootContainer.topAnchor),
            mainArea.bottomAnchor.constraint(equalTo: rootContainer.bottomAnchor),
            mainArea.trailingAnchor.constraint(equalTo: rootContainer.trailingAnchor),

            tabStrip.topAnchor.constraint(equalTo: mainArea.topAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: mainArea.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: mainArea.trailingAnchor),
            stripHeight,

            contentHost.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            contentHost.leadingAnchor.constraint(equalTo: mainArea.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: mainArea.trailingAnchor),
            contentHost.bottomAnchor.constraint(equalTo: mainArea.bottomAnchor),
        ])

        tabStrip.onSelect = { [weak self] index in self?.selectTab(at: index) }
        tabStrip.onClose = { [weak self] index in self?.closeTab(at: index) }
        tabStrip.onRename = { [weak self] index, name in
            self?.renameTab(at: index, to: name)
        }
    }

    // MARK: - tab 管理

    /// 标签页默认名计数器（跨窗口全局，与「终端 N」的 pane 计数同策略）：
    /// 标签页是语义单元、窗口只是展示容器，默认名必须全局唯一才能在
    /// 侧栏跳转行里直接当身份用，窗口层不需要另起名字。
    private static var tabCounter = 0

    /// 同 PaneView.seedDefaultNameCounter：恢复后新标签页不与「标签页 2」重名。
    private static func seedTabCounter(from titles: [String]) {
        let prefix = L("Tab %d").replacingOccurrences(of: "%d", with: "")
        let numbers = titles.compactMap { title -> Int? in
            guard title.hasPrefix(prefix) else { return nil }
            return Int(title.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces))
        }
        if let top = numbers.max() { tabCounter = max(tabCounter, top) }
    }

    /// core `new_tab`：当前窗口追加一个 tab（标签页 = 新的 pane 树容器）。
    func addTab(initialPane: PaneView, select: Bool = true, installPane: Bool = true) {
        if installPane { install(pane: initialPane) }
        appendTab(root: initialPane, select: select)
    }

    /// 新标签页的公共尾巴：root 可以是单 pane，也可以是恢复流程已经装好的整棵分屏树。
    @discardableResult
    private func appendTab(root: NSView, select: Bool, title: String? = nil) -> TerminalTab {
        emptyStateView?.isHidden = true  // 有标签页了，收起空态占位
        let tab = TerminalTab()
        Self.tabCounter += 1
        tab.title = title ?? L("Tab %d", Self.tabCounter)
        contentHost.addSubview(tab.container)
        NSLayoutConstraint.activate([
            tab.container.topAnchor.constraint(equalTo: contentHost.topAnchor),
            tab.container.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
            tab.container.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            tab.container.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
        ])
        tabs.append(tab)
        setRoot(root, in: tab)
        if select {
            selectTab(at: tabs.count - 1)
        } else {
            tab.container.isHidden = tabs.count > 1
            refreshTabStrip()
        }
        return tab
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeTabIndex = index
        for (i, tab) in tabs.enumerated() {
            tab.container.isHidden = i != index
        }
        refreshTabStrip()
        let pane = activePane
        if let pane {
            lastFocusedPane = pane
            pane.focusTerminal()
            updateWindowTitle(for: pane)
        }
    }

    /// 关一个 tab：释放其全部 pane（surface 随引用释放）。最后一个 tab 关窗口。
    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs.remove(at: index)
        tab.container.removeFromSuperview()
        // 关掉最后一个标签页不退出软件：task 是核心，回到空态等待再次派发。
        if tabs.isEmpty {
            activeTabIndex = 0
            enterEmptyState()
            NotificationCenter.default.post(name: .lighttyTasksDidChange, object: nil)
            return
        }
        if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        } else if index < activeTabIndex {
            activeTabIndex -= 1
        }
        selectTab(at: activeTabIndex)
        // tab 里可能有绑定任务的 pane，侧栏活跃态需要跟着退
        NotificationCenter.default.post(name: .lighttyTasksDidChange, object: nil)
    }

    /// 进入“无标签页”空态：终端区放引导占位，并把任务卡片带出来（task 为核心）。
    private func enterEmptyState() {
        let view: EmptyTabView
        if let existing = emptyStateView {
            view = existing
        } else {
            view = EmptyTabView()
            view.onNewTab = { [weak self] in self?.addTab(initialPane: PaneView()) }
            view.translatesAutoresizingMaskIntoConstraints = false
            contentHost.addSubview(view, positioned: .below, relativeTo: nil)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: contentHost.topAnchor),
                view.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            ])
            emptyStateView = view
        }
        view.isHidden = false
        lastFocusedPane = nil
        updateWindowTitle(for: nil)
        refreshTabStrip()
        tabSidebar?.reload()
        if taskPanel == nil { openTaskPanel() }
    }

    enum CloseTabMode { case this, other, right }

    /// core close_tab：this/other/right 三种范围。
    func closeTabs(mode: CloseTabMode) {
        switch mode {
        case .this:
            closeTab(at: activeTabIndex)
        case .other:
            for i in tabs.indices.reversed() where i != activeTabIndex {
                closeTab(at: i)
            }
        case .right:
            for i in tabs.indices.reversed() where i > activeTabIndex {
                closeTab(at: i)
            }
        }
    }

    /// core goto_tab：previous/next/last/1-based 序号。
    enum GotoTab { case previous, next, last, index(Int) }

    func gotoTab(_ target: GotoTab) {
        guard tabs.count > 1 else { return }
        let destination: Int
        switch target {
        case .previous:
            destination = activeTabIndex == 0 ? tabs.count - 1 : activeTabIndex - 1
        case .next:
            destination = activeTabIndex == tabs.count - 1 ? 0 : activeTabIndex + 1
        case .last:
            destination = tabs.count - 1
        case .index(let number): // 1-based；超界落到最后一个
            destination = min(max(0, number - 1), tabs.count - 1)
        }
        selectTab(at: destination)
    }

    /// core move_tab：活跃 tab 在条内移位（环绕）。
    func moveActiveTab(by amount: Int) {
        guard tabs.count > 1, amount != 0 else { return }
        let destination = (activeTabIndex + amount % tabs.count + tabs.count) % tabs.count
        let tab = tabs.remove(at: activeTabIndex)
        tabs.insert(tab, at: destination)
        activeTabIndex = destination
        refreshTabStrip()
    }

    /// 用户重命名标签页（tab 标签双击）。OSC set_tab_title 已忽略：标签页名归用户。
    func renameTab(at index: Int, to title: String) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].title = title
        refreshTabStrip()
        if index == activeTabIndex { window?.title = title }
    }

    /// 标签页名查询（侧栏气泡"跳转"行显示 pane 位置用）。
    func tabName(of pane: PaneView) -> String? {
        tab(hosting: pane)?.title
    }

    /// 标签页列（双栏侧栏左栏）的数据快照：全部标签页 + 各自 pane 叶子序。
    func tabOverview() -> [(
        id: UUID,
        index: Int,
        title: String,
        isActive: Bool,
        panes: [PaneView]
    )] {
        tabs.enumerated().map { index, tab in
            (tab.id, index, tab.title, index == activeTabIndex, panes(in: tab))
        }
    }

    private func refreshTabStrip() {
        // 横向 tab 栏已停用（标签页导航归侧栏标签页列）；代码保留待彻底拆除。
        let visible = false && tabs.count > 1
        tabStripHeightConstraint?.constant = visible ? TabStripView.height : 0
        tabStrip.isHidden = !visible
        if visible {
            tabStrip.update(titles: tabs.map(\.title), activeIndex: activeTabIndex)
        }
        tabSidebar?.reload()
        SessionStore.shared.scheduleSave()
    }

    /// 聚焦指定 pane：先切到其所在 tab（后台 tab 的 pane 无法成为 first responder），
    /// 再交还终端焦点。侧边栏任务行点击跳转用。
    func reveal(pane: PaneView) {
        if let hostTab = tab(hosting: pane),
           let index = tabs.firstIndex(where: { $0 === hostTab }),
           index != activeTabIndex {
            selectTab(at: index)
        }
        pane.focusTerminal()
    }

    /// 跳转落点提示的聚光灯：目标 pane 不动，同标签页其余 pane 短暂压暗。
    /// 单 pane 标签页自然无事发生——本来也不存在「落在哪」的疑问。
    func spotlight(on pane: PaneView) {
        guard let hostTab = tab(hosting: pane) else { return }
        for other in panes(in: hostTab) where other !== pane {
            other.dimForSpotlight()
        }
    }

    /// 拖拽移走 pane 后清理空 tab；tab 清空即关（最后一个 tab 关窗口）。
    func pruneEmptyTabs() {
        for (i, tab) in tabs.enumerated().reversed() where panes(in: tab).isEmpty {
            closeTab(at: i)
        }
    }

    // MARK: - pane 树

    private var rootView: NSView? { activeTab?.rootView }

    private func tab(hosting view: NSView) -> TerminalTab? {
        var v: NSView? = view
        while let cur = v {
            if let tab = tabs.first(where: { $0.container === cur }) { return tab }
            v = cur.superview
        }
        return nil
    }

    private func setRoot(_ view: NSView, in tab: TerminalTab) {
        tab.container.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        tab.container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: tab.container.topAnchor),
            view.bottomAnchor.constraint(equalTo: tab.container.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: tab.container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: tab.container.trailingAnchor),
        ])
        tab.rootView = view
    }

    private func install(pane: PaneView) {
        pane.onClose = { [weak self] p in self?.close(pane: p) }
        pane.onMetadataChange = { [weak self] p in
            guard let self, self.activePane === p else { return }
            self.updateWindowTitle(for: p)
        }
        pane.onMoveRequest = { [weak self] sourceID, destination, zone in
            self?.movePane(withID: sourceID, to: destination, zone: zone) ?? false
        }
        pane.header.onDragEnded = {
            guard let state = AppState.shared else { return }
            state.windowControllers
                .flatMap { $0.panes() }
                .forEach { $0.clearDropPreview() }
        }
        pane.terminal.onFocusChange = { [weak self, weak pane] focused in
            guard focused, let self, let pane else { return }
            self.lastFocusedPane = pane
            self.updateWindowTitle(for: pane)
            self.tabSidebar?.applyActivePane(pane.dragIdentifier)
            // 「已完成」是唯一粘滞的状态，它的语义是**未读**——用户看到了就该消。
            // 焦点落到这个 pane 上就是"看到了"最直接的证据（docs/specs/pane-status.md
            // §4.3）。不清的话，下次这个 pane 再跑完就不构成状态跳变，提醒会漏发。
            PaneStatusStore.shared.markRead(pane.dragIdentifier)
        }
        pane.terminal.onWorkingDirectoryChange = { [weak self, weak pane] directory in
            guard let self, let pane else { return }
            self.tabSidebar?.applyWorkingDirectory(
                directory, for: pane.dragIdentifier)
            SessionStore.shared.scheduleSave()
        }
    }

    private func walkPanes(_ view: NSView, into result: inout [PaneView]) {
        if let pane = view as? PaneView {
            result.append(pane)
        } else if let split = view as? NSSplitView {
            split.arrangedSubviews.forEach { walkPanes($0, into: &result) }
        }
    }

    /// 窗口内全部 pane（跨所有 tab）：任务管理、跨窗口拖拽等全局操作用。
    func panes() -> [PaneView] {
        var result: [PaneView] = []
        for tab in tabs {
            if let root = tab.rootView { walkPanes(root, into: &result) }
        }
        return result
    }

    /// 单个 tab 内的 pane：分屏导航/关闭等 tab 局部操作用。
    private func panes(in tab: TerminalTab) -> [PaneView] {
        var result: [PaneView] = []
        if let root = tab.rootView { walkPanes(root, into: &result) }
        return result
    }

    private var activeTabPanes: [PaneView] {
        activeTab.map { panes(in: $0) } ?? []
    }

    var activePane: PaneView? {
        // 从 firstResponder 向上找 PaneView；找不到取活跃 tab 的第一个
        var responder: NSResponder? = window?.firstResponder
        while let r = responder {
            if let view = r as? NSView {
                var v: NSView? = view
                while let cur = v {
                    if let pane = cur as? PaneView { return pane }
                    v = cur.superview
                }
                break
            }
            responder = r.nextResponder
        }
        let inActiveTab = activeTabPanes
        if let lastFocusedPane, inActiveTab.contains(where: { $0 === lastFocusedPane }) {
            return lastFocusedPane
        }
        return inActiveTab.first
    }

    /// new_split 动作方向（对应 ghostty_action_split_direction_e）
    enum SplitDirection {
        case right, down, left, up

        var isVertical: Bool { self == .right || self == .left }
        /// 新 pane 落在当前 pane 之后（右/下）还是之前（左/上）
        var insertsAfter: Bool { self == .right || self == .down }
    }

    /// new_split：分屏。新 pane 一律未命名（不继承目标 pane 的任务——任务与
    /// pane 一一对应，命名那一刻才落盘）。cwd/font 仍走 core 的 inherited config。
    /// Ghostty 行为：新 pane 与目标 pane 对半分，其余 pane 尺寸不动。
    func split(
        _ active: PaneView,
        direction: SplitDirection,
        surfaceConfiguration: TerminalSurfaceConfiguration = .init()
    ) {
        restoreSplitZoomIfNeeded()
        let pane = PaneView(surfaceConfiguration: surfaceConfiguration)
        install(pane: pane)
        insert(pane, nextTo: active, direction: direction)
        pane.focusTerminal()
        refreshTabStrip()
    }

    /// 恢复流程「当前 tab 新 pane」：把外部构造好的 pane（已绑定任务）
    /// 插到活跃 pane 右侧；空 tab 时直接作树根。
    func addPaneToActiveTab(_ pane: PaneView) {
        // 空态下“开到当前标签页”无处可去：直接新建一个标签页承载它。
        guard activeTab != nil else { addTab(initialPane: pane); return }
        restoreSplitZoomIfNeeded()
        install(pane: pane)
        if let active = activePane {
            insert(pane, nextTo: active, direction: .right)
        } else if let tab = activeTab {
            setRoot(pane, in: tab)
        }
        lastFocusedPane = pane
        pane.focusTerminal()
        updateWindowTitle(for: pane)
        refreshTabStrip()
    }

    /// pane 移动前的原位快照，供 undo 把它移回去。
    ///
    /// 官方的 undo 靠值类型 SplitTree 整树快照还原；我们的树是活视图层级，
    /// 等价物是「记住原兄弟叶子与相对方位，undo 时走同一条 movePane 路径移回」。
    /// 原邻居随后被关掉时快照自然失效（movePane 返回 false，undo 无声无效），
    /// 比例不做精确还原——这是活树语义下对官方行为的近似。
    private struct PaneMoveRestore {
        weak var controller: TerminalWindowController?
        weak var anchor: PaneView?
        /// nil = 原来独占一个标签页，undo 走 toTabAt
        let zone: PaneDropZone?
        let tabIndex: Int
    }

    private func moveRestore(for pane: PaneView) -> PaneMoveRestore {
        let hostTab = tab(hosting: pane)
        let index = hostTab.flatMap { host in tabs.firstIndex { $0 === host } } ?? 0
        guard let parent = pane.superview as? NSSplitView,
              let paneIndex = parent.arrangedSubviews.firstIndex(of: pane) else {
            return PaneMoveRestore(controller: self, anchor: nil, zone: nil, tabIndex: index)
        }
        // 邻位子树的任一叶子都能当锚点；恒嵌套后树是二叉的，取相邻一侧
        let neighborIndex = paneIndex == 0 ? 1 : paneIndex - 1
        guard parent.arrangedSubviews.indices.contains(neighborIndex),
              let anchor = Self.firstLeaf(in: parent.arrangedSubviews[neighborIndex]) else {
            return PaneMoveRestore(controller: self, anchor: nil, zone: nil, tabIndex: index)
        }
        let before = paneIndex < neighborIndex
        // isVertical = 左右排列；否则上下排列（arranged 顺序 = 上→下）
        let zone: PaneDropZone = parent.isVertical
            ? (before ? .left : .right)
            : (before ? .top : .bottom)
        return PaneMoveRestore(controller: self, anchor: anchor, zone: zone, tabIndex: index)
    }

    private static func firstLeaf(in view: NSView) -> PaneView? {
        if let pane = view as? PaneView { return pane }
        for sub in view.subviews {
            if let pane = firstLeaf(in: sub) { return pane }
        }
        return nil
    }

    /// undo 栈注册。movePane 的反向操作也走 movePane，会再注册一次——
    /// undo 中执行时那次注册自动成为 redo（NSUndoManager 语义）。
    private func registerMoveUndo(_ restore: PaneMoveRestore, sourceID: UUID) {
        guard let undoManager = window?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { _ in
            guard let controller = restore.controller else { return }
            if let anchor = restore.anchor, let zone = restore.zone {
                controller.movePane(withID: sourceID, to: anchor, zone: zone)
            } else {
                controller.movePane(withID: sourceID, toTabAt: restore.tabIndex)
            }
        }
        undoManager.setActionName(L("Move Split"))
    }

    /// 侧栏跨标签页拖拽：把 pane 挪进指定标签页（tab），插到其最后一个 pane
    /// 右侧；空标签页直接作树根。与分屏 drag/drop 共用 detach/install 路径，
    /// PTY、cwd 与 scrollback 全保留。不跟随切换标签页——拖动是整理动作，
    /// 不该把用户从当前上下文拽走。
    @discardableResult
    func movePane(withID sourceID: UUID, toTabAt index: Int) -> Bool {
        guard tabs.indices.contains(index),
              let sourceLocation = AppState.shared.runningPanes().first(where: {
                  $0.pane.dragIdentifier == sourceID
              }) else { return false }
        let targetTab = tabs[index]
        let sourceController = sourceLocation.controller
        let source = sourceLocation.pane
        // 同标签页且只有它一个 pane：无事可做
        if sourceController === self, tab(hosting: source) === targetTab,
            panes(in: targetTab).count == 1 { return false }

        restoreSplitZoomIfNeeded()
        if sourceController !== self { sourceController.restoreSplitZoomIfNeeded() }
        let restore = sourceController.moveRestore(for: source)
        guard sourceController.detach(pane: source) else { return false }
        registerMoveUndo(restore, sourceID: sourceID)

        install(pane: source)
        if let anchor = panes(in: targetTab).last {
            insert(source, nextTo: anchor, direction: .right)
        } else {
            setRoot(source, in: targetTab)
        }
        if index == activeTabIndex {
            lastFocusedPane = source
            source.focusTerminal()
            updateWindowTitle(for: source)
        }

        pruneEmptyTabs()
        if sourceController !== self {
            sourceController.pruneEmptyTabs()
            sourceController.lastFocusedPane = sourceController.panes().first
            if let remaining = sourceController.activePane {
                sourceController.updateWindowTitle(for: remaining)
            }
        }
        refreshTabStrip()
        NotificationCenter.default.post(name: .lighttyTasksDidChange, object: nil)
        return true
    }

    /// 对齐 Ghostty `splitDidDrop`：先从原树移除 source，再按目标四边插入；
    /// PaneView/TerminalSurfaceView 本体不重建，所以 PTY、cwd 与 scrollback 全保留。
    /// internal：PaneView 落点与侧栏 pane 行落点共用。
    @discardableResult
    func movePane(
        withID sourceID: UUID,
        to destination: PaneView,
        zone: PaneDropZone
    ) -> Bool {
        guard panes().contains(where: { $0 === destination }),
              let sourceLocation = AppState.shared.runningPanes().first(where: {
                  $0.pane.dragIdentifier == sourceID
              }) else { return false }

        let sourceController = sourceLocation.controller
        let source = sourceLocation.pane
        guard source !== destination else { return false }

        restoreSplitZoomIfNeeded()
        if sourceController !== self { sourceController.restoreSplitZoomIfNeeded() }
        let restore = sourceController.moveRestore(for: source)
        guard sourceController.detach(pane: source) else { return false }
        registerMoveUndo(restore, sourceID: sourceID)

        install(pane: source)
        let direction: SplitDirection = switch zone {
        case .top: .up
        case .bottom: .down
        case .left: .left
        case .right: .right
        }
        insert(source, nextTo: destination, direction: direction)
        lastFocusedPane = source
        source.focusTerminal()
        updateWindowTitle(for: source)

        pruneEmptyTabs()
        if sourceController !== self {
            sourceController.pruneEmptyTabs()
            sourceController.lastFocusedPane = sourceController.panes().first
            if let remaining = sourceController.activePane {
                sourceController.updateWindowTitle(for: remaining)
            }
        }
        // 跨窗口移动后侧栏缓存的 (controller, pane) 映射失效，刷新重建
        NotificationCenter.default.post(name: .lighttyTasksDidChange, object: nil)
        return true
    }

    /// 把一个已存在的 pane 插到目标旁边。new_split 与 drag/drop 共用同一棵
    /// NSSplitView tree 变换，避免出现两套布局语义。
    ///
    /// 与官方 `SplitTree.inserting` 逐式对齐：**无条件**把目标叶子原位包成
    /// 新的二叉 split（内部对半分，外层各 pane 尺寸不动），同方向也不压平。
    /// 树形状决定后续分隔线拖动的分组行为——压平会让 [A|[B|C]] 退化成
    /// [A|B|C]，拖第一条线时 B、C 不再作为整体缩放，手感与官方不一致。
    private func insert(_ pane: PaneView, nextTo active: PaneView, direction: SplitDirection) {
        guard let hostTab = tab(hosting: active) else { return }
        pane.translatesAutoresizingMaskIntoConstraints = false
        let vertical = direction.isVertical
        rootContainer.layoutSubtreeIfNeeded()

        let split = makeSplit(vertical: vertical)
        let pair = direction.insertsAfter ? [active, pane] : [pane, active]
        if let parent = active.superview as? NSSplitView {
            let outerSizes = parent.arrangedSubviews.map { axisSize($0, vertical: parent.isVertical) }
            let index = parent.arrangedSubviews.firstIndex(of: active)!
            active.removeFromSuperview()
            pair.forEach { split.addArrangedSubview($0) }
            parent.insertArrangedSubview(split, at: index)
            setSizes(outerSizes, in: parent)
        } else {
            active.removeFromSuperview()
            pair.forEach { split.addArrangedSubview($0) }
            setRoot(split, in: hostTab)
        }
        equalize(split)
    }

    /// 从 split tree 摘下 pane 并递归压平单子节点；不会关闭 surface。
    /// 摘空的 tab 交由调用方 pruneEmptyTabs 收尾。
    @discardableResult
    private func detach(pane: PaneView) -> Bool {
        guard let hostTab = tab(hosting: pane) else { return false }
        if hostTab.rootView === pane {
            pane.removeFromSuperview()
            hostTab.rootView = nil
            return true
        }
        guard let parent = pane.superview as? NSSplitView else { return false }
        parent.removeArrangedSubview(pane)
        pane.removeFromSuperview()
        collapseAfterRemoval(parent, in: hostTab)
        return true
    }

    private func collapseAfterRemoval(_ split: NSSplitView, in hostTab: TerminalTab) {
        switch split.arrangedSubviews.count {
        case 0:
            if let grand = split.superview as? NSSplitView {
                grand.removeArrangedSubview(split)
                split.removeFromSuperview()
                collapseAfterRemoval(grand, in: hostTab)
            } else {
                split.removeFromSuperview()
                if hostTab.rootView === split { hostTab.rootView = nil }
            }
        case 1:
            let remaining = split.arrangedSubviews[0]
            split.removeArrangedSubview(remaining)
            remaining.removeFromSuperview()
            if let grand = split.superview as? NSSplitView,
               let index = grand.arrangedSubviews.firstIndex(of: split) {
                let outerSizes = grand.arrangedSubviews.map {
                    axisSize($0, vertical: grand.isVertical)
                }
                grand.removeArrangedSubview(split)
                split.removeFromSuperview()
                grand.insertArrangedSubview(remaining, at: index)
                setSizes(outerSizes, in: grand)
            } else {
                setRoot(remaining, in: hostTab)
            }
        default:
            break
        }
    }

    /// equalize_splits：窗口内全部 split 递归均分
    func equalizeAllSplits() {
        func walk(_ view: NSView) {
            guard let split = view as? NSSplitView else { return }
            equalize(split)
            split.arrangedSubviews.forEach(walk)
        }
        if let rootView { walk(rootView) }
    }

    /// Ghostty `toggle_split_zoom`：只放大目标 pane，再次调用原样恢复整棵树。
    /// 不移动 TerminalSurfaceView，因此 IOSurface layer 和 PTY 生命周期不变。
    @discardableResult
    func toggleSplitZoom(_ pane: PaneView) -> Bool {
        guard activeTabPanes.count > 1, let rootView else { return false }
        if zoomedPane != nil {
            restoreSplitZoomIfNeeded()
            pane.focusTerminal()
            return true
        }

        func contains(_ view: NSView, pane: PaneView) -> Bool {
            if view === pane { return true }
            guard let split = view as? NSSplitView else { return false }
            return split.arrangedSubviews.contains { contains($0, pane: pane) }
        }

        func revealOnlyPath(in view: NSView) {
            guard let split = view as? NSSplitView else { return }
            for child in split.arrangedSubviews {
                let isOnPath = contains(child, pane: pane)
                child.isHidden = !isOnPath
                if isOnPath { revealOnlyPath(in: child) }
            }
            split.adjustSubviews()
        }

        zoomedPane = pane
        revealOnlyPath(in: rootView)
        pane.focusTerminal()
        return true
    }

    private func restoreSplitZoomIfNeeded() {
        guard zoomedPane != nil, let rootView else { return }
        func reveal(_ view: NSView) {
            guard let split = view as? NSSplitView else {
                view.isHidden = false
                return
            }
            split.isHidden = false
            for child in split.arrangedSubviews {
                child.isHidden = false
                reveal(child)
            }
            split.adjustSubviews()
        }
        reveal(rootView)
        zoomedPane = nil
    }

    /// resize_split：把目标 pane 朝 direction 的边界向外推 amount 像素（贴窗口边缘时无操作）
    func resizeSplit(_ pane: PaneView, direction: SplitDirection, amount: CGFloat) {
        // 沿祖先链找轴向匹配的 split，child 是包含 pane 的那个子树
        var child: NSView = pane
        while let parent = child.superview {
            if let split = parent as? NSSplitView,
               split.isVertical == direction.isVertical,
               let index = split.arrangedSubviews.firstIndex(of: child) {
                // NSSplitView 是 flipped 坐标：位置从左/上起算
                switch direction {
                case .right where index < split.arrangedSubviews.count - 1:
                    split.setPosition(child.frame.maxX + amount, ofDividerAt: index)
                case .left where index > 0:
                    split.setPosition(child.frame.minX - amount - split.dividerThickness, ofDividerAt: index - 1)
                case .down where index < split.arrangedSubviews.count - 1:
                    split.setPosition(child.frame.maxY + amount, ofDividerAt: index)
                case .up where index > 0:
                    split.setPosition(child.frame.minY - amount - split.dividerThickness, ofDividerAt: index - 1)
                default:
                    break // 该方向已贴窗口边缘：与 Ghostty 一致，无操作
                }
                return
            }
            child = parent
        }
    }

    // MARK: - 分屏尺寸（Ghostty 行为：新 pane 与当前 pane 对半分）

    private func axisSize(_ view: NSView, vertical: Bool) -> CGFloat {
        vertical ? view.frame.width : view.frame.height
    }

    /// 按目标尺寸摆分隔线；须等布局完成后再设，故推到下一轮 runloop
    private func setSizes(_ sizes: [CGFloat], in split: NSSplitView) {
        DispatchQueue.main.async {
            split.layoutSubtreeIfNeeded()
            var pos: CGFloat = 0
            for (i, size) in sizes.dropLast().enumerated() {
                pos += size
                split.setPosition(pos, ofDividerAt: i)
                pos += split.dividerThickness
            }
        }
    }

    /// 全部子视图均分（equalize_splits / 新建反向 split 的两半）
    private func equalize(_ split: NSSplitView) {
        DispatchQueue.main.async {
            split.layoutSubtreeIfNeeded()
            let count = split.arrangedSubviews.count
            guard count > 1 else { return }
            let total = (split.isVertical ? split.bounds.width : split.bounds.height)
                - CGFloat(count - 1) * split.dividerThickness
            let each = total / CGFloat(count)
            var pos: CGFloat = 0
            for i in 0..<(count - 1) {
                pos += each
                split.setPosition(pos, ofDividerAt: i)
                pos += split.dividerThickness
            }
        }
    }

    private func makeSplit(vertical: Bool) -> PaneSplitView {
        let split = PaneSplitView()
        split.isVertical = vertical
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        return split
    }

    /// core close_surface / shell 退出：tab 内最后一个 pane 关 tab（最后一个 tab
    /// 关窗口）；否则从 split tree 摘除并解包。
    func close(pane: PaneView) {
        guard let hostTab = tab(hosting: pane) else { return }
        restoreSplitZoomIfNeeded()
        guard panes(in: hostTab).count > 1 else {
            if let index = tabs.firstIndex(where: { $0 === hostTab }) {
                closeTab(at: index)
            }
            return
        }
        guard let parent = pane.superview as? NSSplitView else { return }
        pane.removeFromSuperview()
        // split 只剩一个子视图时解包
        if parent.arrangedSubviews.count == 1 {
            let remaining = parent.arrangedSubviews[0]
            if let grand = parent.superview as? NSSplitView {
                let index = grand.arrangedSubviews.firstIndex(of: parent)!
                parent.removeFromSuperview()
                remaining.removeFromSuperview()
                grand.insertArrangedSubview(remaining, at: index)
            } else {
                remaining.removeFromSuperview()
                setRoot(remaining, in: hostTab)
            }
        }
        panes(in: hostTab).first?.focusTerminal()
        // 关掉的 pane 可能绑着任务，侧栏活跃态需要跟着退
        NotificationCenter.default.post(name: .lighttyTasksDidChange, object: nil)
    }

    // MARK: - pane 导航

    /// core goto_split previous/next：活跃 tab 内树序前后切换
    func focusPane(offset: Int) {
        let all = activeTabPanes
        guard all.count > 1, let active = activePane,
              let index = all.firstIndex(of: active) else { return }
        let next = all[(index + offset + all.count) % all.count]
        next.focusTerminal()
    }

    /// core goto_split direction：活跃 tab 内几何最近邻
    func focusPane(direction: NSDirectionalRectEdge) {
        guard let active = activePane, let rootView else { return }
        let all = activeTabPanes.filter { $0 !== active }
        guard !all.isEmpty else { return }
        let from = active.convert(active.bounds.center, to: rootView)

        var best: (pane: PaneView, distance: CGFloat)?
        for pane in all {
            let to = pane.convert(pane.bounds.center, to: rootView)
            let dx = to.x - from.x
            let dy = to.y - from.y
            let inDirection: Bool
            switch direction {
            case .leading: inDirection = dx < 0 && abs(dx) >= abs(dy)
            case .trailing: inDirection = dx > 0 && abs(dx) >= abs(dy)
            case .top: inDirection = dy > 0 && abs(dy) >= abs(dx)   // AppKit y 向上
            case .bottom: inDirection = dy < 0 && abs(dy) >= abs(dx)
            default: inDirection = false
            }
            guard inDirection else { continue }
            let distance = dx * dx + dy * dy
            if best == nil || distance < best!.distance {
                best = (pane, distance)
            }
        }
        best?.pane.focusTerminal()
    }

    // MARK: - 侧栏系统：任务浮空卡片 + 标签页侧栏（均为占位布局）
    // 概念模型：标签页↔pane 是严格层级（docked 侧栏承载其两级树）；
    // task↔pane 是绑定关系——task 卡片开在窗口最左缘、四周留边距、
    // 圆角投影（Ulysses 式"布局占位、视觉悬浮"），把标签页栏与终端整体推移。
    //
    // 侧栏按钮（sidebar.left）= task 卡片的开关（Notes 同式）：
    //   卡片开着时它住在卡片头部行右端（与红绿灯同一行），点了收起；
    //   卡片关着时回到标题栏、紧挨缩放键，点了展开。同一语义，随卡片挪位。
    // 标签页侧栏由吸边半胶囊控制（同形镜像）：开着时吸在其右边线中点的关闭钮；
    // 关着时吸在主区左缘中点的展开钮（鼠标靠近边缘带才增强）。
    // 标签页侧栏右边线同时负责调宽与越界左拖关闭。

    /// task 卡片开关（标题栏按钮 / 菜单「任务侧栏」）
    func toggleSidebar() {
        if taskPanel != nil {
            closeTaskPanel()
        } else {
            openTaskPanel()
        }
    }

    /// 标签页侧栏开关（吸边钮 / 菜单「标签页侧栏」）
    func toggleTabSidebar() {
        if tabSidebar != nil {
            closeTabSidebar()
        } else {
            openTabSidebar()
        }
    }

    /// task 卡片占位宽（卡片 + 左右边距）
    private var taskPanelReserve: CGFloat {
        ShellStyle.taskPanelWidth + ShellStyle.panelInset * 2
    }

    /// 标签页侧栏的落位 x：task 卡片开着时被推到其右侧
    private var tabSidebarOpenX: CGFloat {
        taskPanel != nil ? taskPanelReserve : 0
    }

    /// 终端主区左缘的总让位
    private var mainAreaInset: CGFloat {
        (taskPanel != nil ? taskPanelReserve : 0)
            + (tabSidebar != nil ? tabSidebarWidth : 0)
    }

    /// 红绿灯行中线距窗口顶边的距离（unified 空 toolbar 下为 26）。侧栏 chrome
    /// 都以这一行为基准：task 卡片头部行与它同线，标签页侧栏头部落在它下方。
    /// 不用 contentLayoutRect：空 toolbar 让它多让出一整行，与红绿灯无关。
    private func trafficLightRowCenterFromTop(in window: NSWindow) -> CGFloat {
        guard let zoom = window.standardWindowButton(.zoomButton),
              let titlebar = zoom.superview,
              let themeFrame = window.contentView?.superview else { return 26 }
        let frame = themeFrame.convert(zoom.frame, from: titlebar)
        let fromTop = themeFrame.bounds.maxY - frame.midY
        return fromTop > 0 ? fromTop : 26
    }

    /// 标签页侧栏（docked）的顶部避让：表头行中线对齐 task 卡片的「任务」小节
    /// 标签（卡片顶 6 + 头部行 28 高居中于红绿灯行 + 标签上距 14 + 标签半高 7），
    /// 两栏并排时是一排表头；不与红绿灯同行，卡片收起后侧栏贴窗左缘也不会撞三键。
    private func tabSidebarTopInset(in window: NSWindow) -> CGFloat {
        trafficLightRowCenterFromTop(in: window) + 21
    }

    /// 红绿灯所在的私有标题栏容器（themeFrame 直属子视图），侧栏 chrome 必须垫在
    /// 它之下：三键与标题栏按钮要浮在卡片/侧栏之上。
    private func titlebarContainer(in window: NSWindow, themeFrame: NSView) -> NSView? {
        var container: NSView? = window.standardWindowButton(.closeButton)
        while let v = container, v.superview !== themeFrame {
            container = v.superview
        }
        return container
    }

    // —— 标签页侧栏（docked）——

    func openTabSidebar(animated: Bool = true, deferLayout: Bool = false) {
        guard tabSidebar == nil, let window,
              let contentView = window.contentView,
              let themeFrame = contentView.superview else { return }
        let titlebarContainer = titlebarContainer(in: window, themeFrame: themeFrame)
        let sidebar = TabSidebarView(topInset: tabSidebarTopInset(in: window))
        sidebar.onCloseRequested = { [weak self] in self?.closeTabSidebar() }
        sidebar.onResizeBegan = { [weak self] in self?.beginTabSidebarResize() }
        sidebar.onWidthChange = { [weak self] width in
            self?.resizeTabSidebar(to: width)
        }
        sidebar.onResizeEnded = { [weak self] in self?.endTabSidebarResize() }
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        // 必须垫在 task 卡片之下：侧栏滑入/滑出时从卡片下方穿行
        if let taskPanel {
            themeFrame.addSubview(sidebar, positioned: .below, relativeTo: taskPanel)
        } else if let titlebarContainer {
            themeFrame.addSubview(sidebar, positioned: .below, relativeTo: titlebarContainer)
        } else {
            themeFrame.addSubview(sidebar)
        }
        let width = tabSidebarWidth
        let leading = sidebar.leadingAnchor.constraint(
            equalTo: themeFrame.leadingAnchor, constant: -width)
        let widthConstraint = sidebar.widthAnchor.constraint(equalToConstant: width)
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: themeFrame.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: themeFrame.bottomAnchor),
            leading,
            widthConstraint,
        ])
        tabSidebar = sidebar
        tabSidebarLeadingConstraint = leading
        tabSidebarWidthConstraint = widthConstraint
        installTabEdgeControl()  // 关闭钮钉在侧栏右边线，随滑入一起动
        guard !deferLayout else { return }  // 调用方统一编排动画
        if animated {
            themeFrame.layoutSubtreeIfNeeded()
            var targets: [(NSLayoutConstraint, CGFloat)] = [(leading, tabSidebarOpenX)]
            if let rootLeadingConstraint { targets.append((rootLeadingConstraint, mainAreaInset)) }
            animateSidebarLayout(targets)
        } else {
            leading.constant = tabSidebarOpenX
            rootLeadingConstraint?.constant = mainAreaInset
            themeFrame.layoutSubtreeIfNeeded()
        }
        installTitlebarAccessory(on: window)
    }

    func closeTabSidebar() {
        guard let sidebar = tabSidebar else { return }
        endTabSidebarResize()
        tabSidebar = nil
        // 关闭钮不跟着侧栏滑（磨砂块快速位移会拖出残影），原地淡出
        if let control = tabEdgeControl {
            tabEdgeControl = nil
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                control.animator().alphaValue = 0
            }, completionHandler: { control.removeFromSuperview() })
        }
        var targets: [(NSLayoutConstraint, CGFloat)] = []
        if let tabSidebarLeadingConstraint {
            targets.append((tabSidebarLeadingConstraint, -tabSidebarWidth))
        }
        if let rootLeadingConstraint {
            targets.append((rootLeadingConstraint, mainAreaInset))
        }
        animateSidebarLayout(targets) { [weak self] in
            sidebar.removeFromSuperview()
            self?.tabSidebarLeadingConstraint = nil
            self?.tabSidebarWidthConstraint = nil
            self?.installTabEdgeControl()  // 换成主区左缘的展开钮
            self?.activePane?.focusTerminal()
        }
    }

    private func beginTabSidebarResize() {
        guard tabSidebar != nil, !tabSidebarResizeActive else { return }
        // 若用户在打开动画尚未结束时抓住边线，先落到完整展开态再接管拖动。
        stopSidebarAnimationDriver()
        tabSidebarLeadingConstraint?.constant = tabSidebarOpenX
        rootLeadingConstraint?.constant = mainAreaInset
        window?.contentView?.superview?.layoutSubtreeIfNeeded()
        tabSidebarResizeActive = true
        panes().forEach { $0.terminal.setPromptClearOnResize(false) }
    }

    private func resizeTabSidebar(to proposedWidth: CGFloat) {
        guard tabSidebar != nil, let tabSidebarWidthConstraint else { return }
        tabSidebarWidth = TabSidebarSizing.clampedWidth(proposedWidth)
        tabSidebarWidthConstraint.constant = tabSidebarWidth
        rootLeadingConstraint?.constant = mainAreaInset
        window?.contentView?.superview?.layoutSubtreeIfNeeded()
    }

    private func endTabSidebarResize() {
        guard tabSidebarResizeActive else { return }
        tabSidebarResizeActive = false
        TabSidebarWidthPreference.setWidth(tabSidebarWidth)
        panes().forEach { $0.terminal.setPromptClearOnResize(true) }
    }

    // —— 任务浮空卡片（布局占位、视觉悬浮）——

    private func openTaskPanel(animated: Bool = true) {
        guard taskPanel == nil, let window,
              let contentView = window.contentView,
              let themeFrame = contentView.superview else { return }
        // 卡片从窗口顶边起（只留 panelInset），把红绿灯收进自己的头部行；
        // 头部行按钮与红绿灯同一水平线。
        let panel = TaskSidebar(
            headerCenterY: trafficLightRowCenterFromTop(in: window) - ShellStyle.panelInset)
        panel.onRequestClose = { [weak self] in self?.closeTaskPanel() }
        panel.translatesAutoresizingMaskIntoConstraints = false
        // 垫在标题栏容器之下（三键浮在卡片上）、标签页侧栏之上（侧栏滑动时从卡片下穿行）
        if let titlebar = titlebarContainer(in: window, themeFrame: themeFrame) {
            themeFrame.addSubview(panel, positioned: .below, relativeTo: titlebar)
        } else {
            themeFrame.addSubview(panel)
        }
        let leading = panel.leadingAnchor.constraint(
            equalTo: themeFrame.leadingAnchor, constant: -taskPanelReserve)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(
                equalTo: themeFrame.topAnchor, constant: ShellStyle.panelInset),
            panel.bottomAnchor.constraint(
                equalTo: themeFrame.bottomAnchor, constant: -ShellStyle.panelInset),
            leading,
            panel.widthAnchor.constraint(equalToConstant: ShellStyle.taskPanelWidth),
        ])
        taskPanel = panel
        taskPanelLeadingConstraint = leading
        updateSidebarButtonState()
        themeFrame.layoutSubtreeIfNeeded()
        // 四块协同推移：卡片滑入 + 标签页栏右移让位 + 终端让位 + 标签页展开钮跟着主区左缘
        var targets: [(NSLayoutConstraint, CGFloat)] = [(leading, ShellStyle.panelInset)]
        if let tabSidebarLeadingConstraint {
            targets.append((tabSidebarLeadingConstraint, tabSidebarOpenX))
        }
        if let rootLeadingConstraint {
            targets.append((rootLeadingConstraint, mainAreaInset))
        }
        if let tabEdgeLeadingConstraint {
            targets.append((tabEdgeLeadingConstraint, tabSidebarOpenX))
        }
        guard animated else {
            targets.forEach { $0.0.constant = $0.1 }
            themeFrame.layoutSubtreeIfNeeded()
            return
        }
        animateSidebarLayout(targets)
    }

    private func closeTaskPanel(animated: Bool = true) {
        guard let panel = taskPanel else { return }
        taskPanel = nil
        updateSidebarButtonState()
        let leading = taskPanelLeadingConstraint
        taskPanelLeadingConstraint = nil
        var targets: [(NSLayoutConstraint, CGFloat)] = []
        if let leading { targets.append((leading, -taskPanelReserve)) }
        if let tabSidebarLeadingConstraint {
            targets.append((tabSidebarLeadingConstraint, tabSidebarOpenX))
        }
        if let rootLeadingConstraint {
            targets.append((rootLeadingConstraint, mainAreaInset))
        }
        if let tabEdgeLeadingConstraint {
            targets.append((tabEdgeLeadingConstraint, tabSidebarOpenX))
        }
        guard animated else {
            stopSidebarAnimationDriver()
            targets.forEach { $0.0.constant = $0.1 }
            panel.removeFromSuperview()
            window?.contentView?.superview?.layoutSubtreeIfNeeded()
            return
        }
        animateSidebarLayout(targets) { [weak self] in
            panel.removeFromSuperview()
            self?.activePane?.focusTerminal()
        }
    }

    // —— 标签页侧栏的吸边开关 ——

    /// 标签页侧栏开着：关闭钮吸在其右边线中点（钉在 sidebar.trailing，随滑动）；
    /// 关着：展开钮吸在主区左缘中点（task 卡片开着时就是卡片右侧的让位线），
    /// 默认低存在感、鼠标靠近边缘带才增强。侧栏开/关时重建。
    private func installTabEdgeControl() {
        SessionStore.shared.scheduleSave()  // 标签页栏开合入快照
        guard let themeFrame = window?.contentView?.superview else { return }
        tabEdgeControl?.removeFromSuperview()
        tabEdgeControl = nil
        tabEdgeStrip?.removeFromSuperview()
        tabEdgeStrip = nil
        tabEdgeLeadingConstraint = nil

        // 两态都垫在 task 卡片之下：侧栏从卡片下方穿行，开关随行时不能浮到卡片表面
        func mount(_ v: NSView) {
            if let taskPanel {
                themeFrame.addSubview(v, positioned: .below, relativeTo: taskPanel)
            } else {
                themeFrame.addSubview(v)
            }
        }

        if let sidebar = tabSidebar {
            let button = EdgeToggleControl(pointing: .left)
            button.onTap = { [weak self] in self?.closeTabSidebar() }
            button.translatesAutoresizingMaskIntoConstraints = false
            mount(button)
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
                // 开/关两态都以整窗边界中线为纵向基准
                button.centerYAnchor.constraint(equalTo: themeFrame.centerYAnchor),
            ])
            tabEdgeControl = button
            return
        }

        let button = EdgeToggleControl(pointing: .right)
        button.onTap = { [weak self] in self?.openTabSidebar() }
        let strip = EdgeRevealStrip()
        strip.onHoverChange = { [weak button] hovered in button?.reveal(hovered) }
        for v in [strip, button] {
            v.translatesAutoresizingMaskIntoConstraints = false
            mount(v)
        }
        let leading = button.leadingAnchor.constraint(
            equalTo: themeFrame.leadingAnchor, constant: tabSidebarOpenX)
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            strip.topAnchor.constraint(equalTo: themeFrame.topAnchor),
            strip.bottomAnchor.constraint(equalTo: themeFrame.bottomAnchor),
            strip.widthAnchor.constraint(equalToConstant: 14),
            leading,
            button.centerYAnchor.constraint(equalTo: themeFrame.centerYAnchor),
        ])
        tabEdgeControl = button
        tabEdgeStrip = strip
        tabEdgeLeadingConstraint = leading
    }

    // MARK: - 会话快照（重启恢复）

    /// 本窗口的快照；没有标签页（空态）→ nil，不值得恢复。
    func snapshot() -> WindowSnapshot? {
        let tabSnapshots = tabs.compactMap { tab -> TabSnapshot? in
            guard let root = tab.rootView, let node = captureNode(root) else { return nil }
            return TabSnapshot(title: tab.title, root: node)
        }
        guard !tabSnapshots.isEmpty else { return nil }
        return WindowSnapshot(
            frame: window?.frame,
            activeTabIndex: min(max(activeTabIndex, 0), tabSnapshots.count - 1),
            tabs: tabSnapshots,
            taskPanelOpen: taskPanel != nil,
            tabSidebarOpen: tabSidebar != nil)
    }

    private func captureNode(_ view: NSView) -> SplitNodeSnapshot? {
        if let pane = view as? PaneView { return .pane(pane.snapshot()) }
        guard let split = view as? NSSplitView else { return nil }
        let children = split.arrangedSubviews.compactMap(captureNode)
        guard children.count == split.arrangedSubviews.count, !children.isEmpty else { return nil }
        if children.count == 1 { return children[0] }
        let sizes = split.arrangedSubviews.map { axisSize($0, vertical: split.isVertical) }
        let total = sizes.reduce(0, +)
        let fractions = total > 0
            ? sizes.map { Double($0 / total) }
            : Array(repeating: 1.0 / Double(children.count), count: children.count)
        return .split(vertical: split.isVertical, fractions: fractions, children: children)
    }

    /// 按快照重建整窗：第一个标签页的树序首叶作 initialPane 走常规 init，
    /// 其余叶子与分屏树、其他标签页随后装上；frame、活跃标签页、侧栏开合一并回填。
    convenience init(restoring snapshot: WindowSnapshot) {
        let firstTab = snapshot.tabs[0]
        let initialPane = PaneView.restored(from: firstTab.root.firstLeaf)
        self.init(initialPane: initialPane)
        suppressesInitialSize = true
        initialTaskPanelOpen = snapshot.taskPanelOpen
        initialTabSidebarOpen = snapshot.tabSidebarOpen

        // 标签页 0：init 已把 initialPane 挂成树根；是分屏树时摘下来重新装进树里
        tabs[0].title = firstTab.title
        if case .split = firstTab.root {
            initialPane.removeFromSuperview()
            tabs[0].rootView = nil
            var reuse: PaneView? = initialPane
            setRoot(buildNode(firstTab.root, reuse: &reuse), in: tabs[0])
        }
        for tabSnapshot in snapshot.tabs.dropFirst() {
            var reuse: PaneView? = nil
            let root = buildNode(tabSnapshot.root, reuse: &reuse)
            appendTab(root: root, select: false, title: tabSnapshot.title)
        }
        selectTab(at: min(snapshot.activeTabIndex, tabs.count - 1))
        Self.seedTabCounter(from: snapshot.tabs.map(\.title))
        PaneView.seedDefaultNameCounter(from: snapshot.tabs.flatMap { $0.root.leaves.map(\.name) })
        pendingRestore = snapshot  // frame / 比例在 init 的首帧异步块里、侧栏就位后落
    }

    /// 侧栏就位后：落窗口 frame（仍在某个屏幕上才用）、摆分隔线比例、显形。
    private func finishRestore(_ snapshot: WindowSnapshot) {
        guard let window else { return }
        if let frame = snapshot.frame,
           NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            window.setFrame(frame, display: true)
        }
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        for (tab, tabSnapshot) in zip(tabs, snapshot.tabs) {
            if let root = tab.rootView { applyFractions(root, tabSnapshot.root) }
        }
        revealWindowIfNeeded()  // 恢复窗不等 INITIAL_SIZE
    }

    /// 递归建树。`reuse` 是已经存在（且已 install）的 pane，树序第一个叶子用它。
    private func buildNode(_ node: SplitNodeSnapshot, reuse: inout PaneView?) -> NSView {
        switch node {
        case .pane(let paneSnapshot):
            if let existing = reuse {
                reuse = nil
                return existing
            }
            let pane = PaneView.restored(from: paneSnapshot)
            install(pane: pane)
            return pane
        case .split(let vertical, _, let children):
            let split = makeSplit(vertical: vertical)
            for child in children {
                let view = buildNode(child, reuse: &reuse)
                view.translatesAutoresizingMaskIntoConstraints = false
                split.addArrangedSubview(view)
            }
            return split
        }
    }

    private func applyFractions(_ view: NSView, _ node: SplitNodeSnapshot) {
        guard case .split(_, let fractions, let children) = node,
              let split = view as? NSSplitView,
              fractions.count == children.count,
              split.arrangedSubviews.count == children.count else { return }
        split.layoutSubtreeIfNeeded()
        let total = axisSize(split, vertical: split.isVertical)
            - CGFloat(children.count - 1) * split.dividerThickness
        if total > 0 {
            var position: CGFloat = 0
            for index in 0..<(children.count - 1) {
                position += CGFloat(fractions[index]) * total
                split.setPosition(position, ofDividerAt: index)
                position += split.dividerThickness
            }
            split.layoutSubtreeIfNeeded()
        }
        for (child, childNode) in zip(split.arrangedSubviews, children) {
            applyFractions(child, childNode)
        }
    }

    // MARK: - 设置页（整窗覆盖）

    func showSettings(page: SettingsView.Page = .appearance) {
        guard settingsView == nil, let window,
              let themeFrame = window.contentView?.superview else { return }
        let view = SettingsView(page: page)
        view.onDismiss = { [weak self] in self?.hideSettings() }
        // 垫在标题栏容器之下：红绿灯仍在页面左上；盖住其余一切（侧栏、终端）
        if let titlebar = titlebarContainer(in: window, themeFrame: themeFrame) {
            themeFrame.addSubview(view, positioned: .below, relativeTo: titlebar)
        } else {
            themeFrame.addSubview(view)
        }
        pinSettingsView(view, in: themeFrame)
        settingsView = view
        updateSidebarButtonState()
        window.makeFirstResponder(view)
    }

    /// 只钉左缘 + 上下，宽度给常量并随窗口同步。**不能把右缘也钉到 themeFrame**：
    /// 两侧钉死后页面内容的最小宽（一行"标签 + 开关"）就成了窗口宽度的下界，
    /// 引擎把这个自由变量取到最小值，窗口会被内容缩窄（切页时窗宽跳变）。
    private func pinSettingsView(_ view: SettingsView, in themeFrame: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        let width = view.widthAnchor.constraint(equalToConstant: themeFrame.bounds.width)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: themeFrame.topAnchor),
            view.bottomAnchor.constraint(equalTo: themeFrame.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: themeFrame.leadingAnchor),
            width,
        ])
        settingsWidthConstraint = width
    }

    func windowDidResize(_ notification: Notification) {
        guard let themeFrame = window?.contentView?.superview else { return }
        settingsWidthConstraint?.constant = themeFrame.bounds.width
        SessionStore.shared.scheduleSave()
    }

    func windowDidMove(_ notification: Notification) {
        SessionStore.shared.scheduleSave()
    }

    func hideSettings() {
        guard let view = settingsView else { return }
        settingsView = nil
        settingsWidthConstraint = nil
        view.removeFromSuperview()
        updateSidebarButtonState()
        activePane?.focusTerminal()
    }

    /// 语言变更：屏上的壳层 chrome 文案是建视图时定死的，原地重建
    /// task 卡片 / 标签页侧栏 / 标题栏按钮（无动画，位置不变）。设置页若开着，
    /// 重建后要重新提到最上层（新建的卡片会插在它之上）。
    @objc private func preferencesDidChange(_ note: Notification) {
        let kind = PreferenceKind.from(note)
        if kind == .accent {
            tabSidebar?.reload()  // 导航色随重点色变，重建行即可
            return
        }
        guard kind == .language,
              let window, let themeFrame = window.contentView?.superview else { return }
        let hadTask = taskPanel != nil
        let hadTab = tabSidebar != nil
        stopSidebarAnimationDriver()
        taskPanel?.removeFromSuperview()
        taskPanel = nil
        taskPanelLeadingConstraint = nil
        tabSidebar?.removeFromSuperview()
        tabSidebar = nil
        tabSidebarLeadingConstraint = nil
        tabSidebarWidthConstraint = nil
        titlebarChrome?.removeFromSuperview()
        titlebarChrome = nil
        if hadTab { openTabSidebar(animated: false) }
        if hadTask { openTaskPanel(animated: false) }
        installTabEdgeControl()
        installTitlebarAccessory(on: window)
        rootLeadingConstraint?.constant = mainAreaInset
        if let settingsView, let titlebar = titlebarContainer(in: window, themeFrame: themeFrame) {
            themeFrame.addSubview(settingsView, positioned: .below, relativeTo: titlebar)
            pinSettingsView(settingsView, in: themeFrame)  // 摘下再挂上，与父视图的约束已失效
        }
        themeFrame.layoutSubtreeIfNeeded()
        updateSidebarButtonState()
    }

    // MARK: - 全文搜索浮层（⇧⇧）

    private var searchPalette: SearchPaletteView?

    func toggleSearchPalette() {
        if searchPalette != nil { dismissSearchPalette() } else { showSearchPalette() }
    }

    private func showSearchPalette() {
        // 挂 themeFrame：浮层覆盖整窗（侧栏在 themeFrame 层级，挂 contentView
        // 会被它盖住且定位不含标题栏区）
        guard let themeFrame = window?.contentView?.superview else { return }
        let palette = SearchPaletteView(controller: self)
        palette.onDismiss = { [weak self] in self?.dismissSearchPalette() }
        // 铺满用 autoresizing 而非约束：对 themeFrame 的约束会反向驱动窗口尺寸
        palette.frame = themeFrame.bounds
        palette.autoresizingMask = [.width, .height]
        themeFrame.addSubview(palette)
        searchPalette = palette
        palette.focusSearch()
    }

    private func dismissSearchPalette() {
        searchPalette?.removeFromSuperview()
        searchPalette = nil
        activePane?.focusTerminal()
    }

    // MARK: - hook 安装引导

    private var hookSetupOverlay: HookSetupOverlay?

    /// 与搜索浮层同款挂载：themeFrame + autoresizing。挂 contentView 会被侧栏盖住，
    /// 建约束会反向驱动窗口尺寸。
    func presentHookSetup() {
        guard hookSetupOverlay == nil,
              let themeFrame = window?.contentView?.superview else { return }
        let overlay = HookSetupOverlay()
        overlay.onDismiss = { [weak self] in self?.dismissHookSetup() }
        overlay.frame = themeFrame.bounds
        overlay.autoresizingMask = [.width, .height]
        themeFrame.addSubview(overlay)
        hookSetupOverlay = overlay
    }

    private func dismissHookSetup() {
        hookSetupOverlay?.removeFromSuperview()
        hookSetupOverlay = nil
        activePane?.focusTerminal()
    }

    func windowWillClose(_ notification: Notification) {
        let others = AppState.shared.windowControllers.filter { $0 !== self }
        if others.isEmpty {
            // 最后一个窗口：关窗即退出，此刻的现场就是下次启动要恢复的会话。
            // 必须在 pane 树拆掉之前定格，并防止随后的 applicationWillTerminate
            // 用空窗口列表把它覆盖掉。
            let windows = [snapshot()].compactMap { $0 }
            SessionStore.shared.freeze(with: SessionSnapshot(windows: windows))
        }
        AppState.shared.windowControllers.removeAll { $0 === self }
        // 主动关掉其中一个窗口 = 不要它了：快照只留其余窗口
        if !others.isEmpty { SessionStore.shared.saveNow() }
        // 整窗的绑定 pane 一起消失，其他窗口的侧栏活跃态需要跟着退
        NotificationCenter.default.post(name: .lighttyTasksDidChange, object: nil)
    }
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}
