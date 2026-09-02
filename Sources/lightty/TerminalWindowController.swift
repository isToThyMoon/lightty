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
    /// 工作区名：会话态，双击 tab 标签改，不从 pane/任务派生、不落盘。
    var title = L("Workspace")

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
    private var activeTab: TerminalTab? {
        tabs.indices.contains(activeTabIndex) ? tabs[activeTabIndex] : nil
    }
    var tabCount: Int { tabs.count }
    /// pinned 侧栏是 docked layout：主体区从侧栏右缘开始；preview 保持 overlay。
    private var rootLeadingConstraint: NSLayoutConstraint?
    private weak var sidebarButton: ShellIconButton?
    private var workspaceSidebar: WorkspaceSidebarView?
    private var workspaceSidebarLeadingConstraint: NSLayoutConstraint?
    private var workspaceSidebarWidthConstraint: NSLayoutConstraint?
    private var workspaceSidebarWidth = WorkspaceSidebarWidthPreference.width()
    private var workspaceSidebarResizeActive = false
    private var taskPanel: TaskSidebar?
    private var taskPanelLeadingConstraint: NSLayoutConstraint?
    private var edgeExpandButton: EdgeToggleControl?
    private var edgeExpandStrip: EdgeRevealStrip?
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
    }

    private weak var titlebarChrome: NSView?
    private weak var lastFocusedPane: PaneView?
    private weak var zoomedPane: PaneView?

    init(initialPane: PaneView = PaneView()) {
        let window = TerminalWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640))
        super.init(window: window)
        window.delegate = self
        window.center()

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
            self.openWorkspaceSidebar(animated: false)
            self.updateEdgeExpandButton()
        }
    }

    /// 标题栏操作区：三键后只保留抽屉开关。新工作区与分屏操作归入工作区侧栏
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
            symbol: "sidebar.left", accessibilityLabel: L("Workspace Sidebar"), target: self,
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
        // tab 名 = 工作区名（用户所有），不再从 pane/任务派生。
        // 系统标题不显示；window.title 只喂 cmd-tab、Mission Control 等系统 UI。
        _ = pane
        window.titleVisibility = .hidden
        window.title = activeTab?.title ?? "lightty"
    }

    /// 亮着 = 点一下会收起东西（工作区栏或 task 卡片任一开着）。
    private func updateSidebarButtonState() {
        sidebarButton?.isActive = workspaceSidebar != nil || taskPanel != nil
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

    /// 工作区默认名计数器（跨窗口全局，与「终端 N」的 pane 计数同策略）：
    /// 工作区是语义单元、窗口只是展示容器，默认名必须全局唯一才能在
    /// 侧栏跳转行里直接当身份用，窗口层不需要另起名字。
    private static var workspaceCounter = 0

    /// core `new_tab`：当前窗口追加一个 tab（工作区 = 新的 pane 树容器）。
    func addTab(initialPane: PaneView, select: Bool = true, installPane: Bool = true) {
        if installPane { install(pane: initialPane) }
        let tab = TerminalTab()
        Self.workspaceCounter += 1
        tab.title = L("Workspace %d", Self.workspaceCounter)
        contentHost.addSubview(tab.container)
        NSLayoutConstraint.activate([
            tab.container.topAnchor.constraint(equalTo: contentHost.topAnchor),
            tab.container.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
            tab.container.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            tab.container.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
        ])
        tabs.append(tab)
        setRoot(initialPane, in: tab)
        if select {
            selectTab(at: tabs.count - 1)
        } else {
            tab.container.isHidden = tabs.count > 1
            refreshTabStrip()
        }
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
        guard tabs.count > 1 else {
            window?.close()
            return
        }
        let tab = tabs.remove(at: index)
        tab.container.removeFromSuperview()
        if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        } else if index < activeTabIndex {
            activeTabIndex -= 1
        }
        selectTab(at: activeTabIndex)
        // tab 里可能有绑定任务的 pane，侧栏活跃态需要跟着退
        NotificationCenter.default.post(name: .lighttyTasksDidChange, object: nil)
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

    /// 用户重命名工作区（tab 标签双击）。OSC set_tab_title 已忽略：工作区名归用户。
    func renameTab(at index: Int, to title: String) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].title = title
        refreshTabStrip()
        if index == activeTabIndex { window?.title = title }
    }

    /// 工作区名查询（侧栏气泡"跳转"行显示 pane 位置用）。
    func workspaceName(of pane: PaneView) -> String? {
        tab(hosting: pane)?.title
    }

    /// 工作区列（双栏侧栏左栏）的数据快照：全部工作区 + 各自 pane 叶子序。
    func workspaceOverview() -> [(
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
        // 横向 tab 栏已停用（工作区导航归侧栏工作区列）；代码保留待彻底拆除。
        let visible = false && tabs.count > 1
        tabStripHeightConstraint?.constant = visible ? TabStripView.height : 0
        tabStrip.isHidden = !visible
        if visible {
            tabStrip.update(titles: tabs.map(\.title), activeIndex: activeTabIndex)
        }
        workspaceSidebar?.reload()
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
            self.workspaceSidebar?.applyActivePane(pane.dragIdentifier)
            // 「已完成」是唯一粘滞的状态，它的语义是**未读**——用户看到了就该消。
            // 焦点落到这个 pane 上就是"看到了"最直接的证据（docs/specs/pane-status.md
            // §4.3）。不清的话，下次这个 pane 再跑完就不构成状态跳变，提醒会漏发。
            PaneStatusStore.shared.markRead(pane.dragIdentifier)
        }
        pane.terminal.onWorkingDirectoryChange = { [weak self, weak pane] directory in
            guard let self, let pane else { return }
            self.workspaceSidebar?.applyWorkingDirectory(
                directory, for: pane.dragIdentifier)
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

    /// 对齐 Ghostty `splitDidDrop`：先从原树移除 source，再按目标四边插入；
    /// PaneView/TerminalSurfaceView 本体不重建，所以 PTY、cwd 与 scrollback 全保留。
    @discardableResult
    private func movePane(
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
        guard sourceController.detach(pane: source) else { return false }

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
    private func insert(_ pane: PaneView, nextTo active: PaneView, direction: SplitDirection) {
        guard let hostTab = tab(hosting: active) else { return }
        pane.translatesAutoresizingMaskIntoConstraints = false
        let vertical = direction.isVertical
        rootContainer.layoutSubtreeIfNeeded()

        if let parent = active.superview as? NSSplitView, parent.isVertical == vertical {
            // 方向一致：插在当前 pane 相邻位
            let index = parent.arrangedSubviews.firstIndex(of: active) ?? parent.arrangedSubviews.count - 1
            var sizes = parent.arrangedSubviews.map { axisSize($0, vertical: parent.isVertical) }
            let half = max(1, (sizes[index] - parent.dividerThickness) / 2)
            sizes[index] = half
            let insertAt = direction.insertsAfter ? index + 1 : index
            sizes.insert(half, at: insertAt)
            parent.insertArrangedSubview(pane, at: insertAt)
            setSizes(sizes, in: parent)
        } else {
            // 方向不同：原位包一层反向 split，内部对半分；外层各 pane 尺寸不动
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

    // MARK: - 侧栏系统：任务浮空卡片 + 工作区侧栏（均为占位布局）
    // 概念模型：工作区↔pane 是严格层级（docked 侧栏承载其两级树）；
    // task↔pane 是绑定关系——task 卡片开在窗口最左缘、四周留边距、
    // 圆角投影（Ulysses 式"布局占位、视觉悬浮"），把工作区栏与终端整体推移。
    //
    // 标题栏侧栏按钮 = 工作区侧栏的开关；task 卡片开着时点它是「全关」：
    //   task 开             → 全关（task + 工作区，一组动画）
    //   task 关、工作区开    → 关工作区
    //   两者皆关            → 开工作区
    // task 卡片由专属边缘钮控制（贴边半胶囊，同形镜像）：卡片关着时窗口左缘
    // 中点展开钮（只开 task）；开着时卡片右缘中点关闭钮。
    // 工作区侧栏没有自己的边缘钮，右边线负责调宽与越界左拖关闭。

    func toggleSidebar() {
        if taskPanel != nil {
            closeAllSidebars()
        } else if workspaceSidebar != nil {
            closeWorkspaceSidebar()
        } else {
            openWorkspaceSidebar()
        }
    }

    /// task 卡片占位宽（卡片 + 左右边距）
    private var taskPanelReserve: CGFloat {
        ShellStyle.taskPanelWidth + ShellStyle.panelInset * 2
    }

    /// 工作区侧栏的落位 x：task 卡片开着时被推到其右侧
    private var workspaceSidebarOpenX: CGFloat {
        taskPanel != nil ? taskPanelReserve : 0
    }

    /// 终端主区左缘的总让位
    private var mainAreaInset: CGFloat {
        (taskPanel != nil ? taskPanelReserve : 0)
            + (workspaceSidebar != nil ? workspaceSidebarWidth : 0)
    }

    /// fullSizeContentView 让 contentView 铺满整个窗口；侧栏 chrome 仍需避让原生
    /// 标题栏。contentLayoutRect 是 AppKit 给出的安全区，不能再从 contentView 推算。
    private func titlebarSafeInset(in window: NSWindow) -> CGFloat {
        max(window.frame.height - window.contentLayoutRect.height, 28)
    }

    // —— 工作区侧栏（docked）——

    func openWorkspaceSidebar(animated: Bool = true, deferLayout: Bool = false) {
        guard workspaceSidebar == nil, let window,
              let contentView = window.contentView,
              let themeFrame = contentView.superview else { return }
        var titlebarContainer: NSView? = window.standardWindowButton(.closeButton)
        while let v = titlebarContainer, v.superview !== themeFrame {
            titlebarContainer = v.superview
        }
        let sidebar = WorkspaceSidebarView(topInset: titlebarSafeInset(in: window))
        sidebar.onCloseRequested = { [weak self] in self?.closeWorkspaceSidebar() }
        sidebar.onResizeBegan = { [weak self] in self?.beginWorkspaceSidebarResize() }
        sidebar.onWidthChange = { [weak self] width in
            self?.resizeWorkspaceSidebar(to: width)
        }
        sidebar.onResizeEnded = { [weak self] in self?.endWorkspaceSidebarResize() }
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        // 必须垫在 task 卡片之下：侧栏滑入/滑出时从卡片下方穿行
        if let taskPanel {
            themeFrame.addSubview(sidebar, positioned: .below, relativeTo: taskPanel)
        } else if let titlebarContainer {
            themeFrame.addSubview(sidebar, positioned: .below, relativeTo: titlebarContainer)
        } else {
            themeFrame.addSubview(sidebar)
        }
        let width = workspaceSidebarWidth
        let leading = sidebar.leadingAnchor.constraint(
            equalTo: themeFrame.leadingAnchor, constant: -width)
        let widthConstraint = sidebar.widthAnchor.constraint(equalToConstant: width)
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: themeFrame.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: themeFrame.bottomAnchor),
            leading,
            widthConstraint,
        ])
        workspaceSidebar = sidebar
        workspaceSidebarLeadingConstraint = leading
        workspaceSidebarWidthConstraint = widthConstraint
        updateSidebarButtonState()
        guard !deferLayout else { return }  // 调用方统一编排动画
        if animated {
            themeFrame.layoutSubtreeIfNeeded()
            var targets: [(NSLayoutConstraint, CGFloat)] = [(leading, workspaceSidebarOpenX)]
            if let rootLeadingConstraint { targets.append((rootLeadingConstraint, mainAreaInset)) }
            animateSidebarLayout(targets)
        } else {
            leading.constant = workspaceSidebarOpenX
            rootLeadingConstraint?.constant = mainAreaInset
            themeFrame.layoutSubtreeIfNeeded()
        }
        installTitlebarAccessory(on: window)
    }

    func closeWorkspaceSidebar() {
        guard let sidebar = workspaceSidebar else { return }
        endWorkspaceSidebarResize()
        workspaceSidebar = nil
        updateSidebarButtonState()
        var targets: [(NSLayoutConstraint, CGFloat)] = []
        if let workspaceSidebarLeadingConstraint {
            targets.append((workspaceSidebarLeadingConstraint, -workspaceSidebarWidth))
        }
        if let rootLeadingConstraint {
            targets.append((rootLeadingConstraint, mainAreaInset))
        }
        animateSidebarLayout(targets) { [weak self] in
            sidebar.removeFromSuperview()
            self?.workspaceSidebarLeadingConstraint = nil
            self?.workspaceSidebarWidthConstraint = nil
            self?.activePane?.focusTerminal()
        }
    }

    private func beginWorkspaceSidebarResize() {
        guard workspaceSidebar != nil, !workspaceSidebarResizeActive else { return }
        // 若用户在打开动画尚未结束时抓住边线，先落到完整展开态再接管拖动。
        stopSidebarAnimationDriver()
        workspaceSidebarLeadingConstraint?.constant = workspaceSidebarOpenX
        rootLeadingConstraint?.constant = mainAreaInset
        window?.contentView?.superview?.layoutSubtreeIfNeeded()
        workspaceSidebarResizeActive = true
        panes().forEach { $0.terminal.setPromptClearOnResize(false) }
    }

    private func resizeWorkspaceSidebar(to proposedWidth: CGFloat) {
        guard workspaceSidebar != nil, let workspaceSidebarWidthConstraint else { return }
        workspaceSidebarWidth = WorkspaceSidebarSizing.clampedWidth(proposedWidth)
        workspaceSidebarWidthConstraint.constant = workspaceSidebarWidth
        rootLeadingConstraint?.constant = mainAreaInset
        window?.contentView?.superview?.layoutSubtreeIfNeeded()
    }

    private func endWorkspaceSidebarResize() {
        guard workspaceSidebarResizeActive else { return }
        workspaceSidebarResizeActive = false
        WorkspaceSidebarWidthPreference.setWidth(workspaceSidebarWidth)
        panes().forEach { $0.terminal.setPromptClearOnResize(true) }
    }

    // —— 任务浮空卡片（布局占位、视觉悬浮）——

    private func openTaskPanel() {
        guard taskPanel == nil, let window,
              let contentView = window.contentView,
              let themeFrame = contentView.superview else { return }
        let panel = TaskSidebar()
        panel.onRequestClose = { [weak self] in self?.closeTaskPanel() }
        panel.translatesAutoresizingMaskIntoConstraints = false
        themeFrame.addSubview(panel)  // 顶层：工作区侧栏滑动时从其下穿行
        let leading = panel.leadingAnchor.constraint(
            equalTo: themeFrame.leadingAnchor, constant: -taskPanelReserve)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(
                equalTo: themeFrame.topAnchor,
                constant: titlebarSafeInset(in: window) + ShellStyle.panelInset),
            panel.bottomAnchor.constraint(
                equalTo: themeFrame.bottomAnchor, constant: -ShellStyle.panelInset),
            leading,
            panel.widthAnchor.constraint(equalToConstant: ShellStyle.taskPanelWidth),
        ])
        // 关闭钮提升到 themeFrame 直属、贴卡片右缘吸附：它的命中区向右溢出卡片
        // bounds（容错），做子视图会被裁断，且卡片 layer 有圆角遮罩。
        let cc = panel.closeControl
        cc.translatesAutoresizingMaskIntoConstraints = false
        themeFrame.addSubview(cc)
        NSLayoutConstraint.activate([
            cc.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            // 开/关两态都以整窗边界中线为纵向基准。卡片自身为避让标题栏
            // 上下并不对称，跟随 panel.centerY 会让关闭钮比展开钮偏下。
            cc.centerYAnchor.constraint(equalTo: themeFrame.centerYAnchor),
        ])
        taskPanel = panel
        taskPanelLeadingConstraint = leading
        updateEdgeExpandButton()
        updateSidebarButtonState()
        themeFrame.layoutSubtreeIfNeeded()
        // 三块协同推移：卡片滑入 + 工作区栏右移让位 + 终端让位
        var targets: [(NSLayoutConstraint, CGFloat)] = [(leading, ShellStyle.panelInset)]
        if let workspaceSidebarLeadingConstraint {
            targets.append((workspaceSidebarLeadingConstraint, workspaceSidebarOpenX))
        }
        if let rootLeadingConstraint {
            targets.append((rootLeadingConstraint, mainAreaInset))
        }
        animateSidebarLayout(targets)
    }

    private func closeTaskPanel() {
        guard let panel = taskPanel else { return }
        taskPanel = nil
        updateSidebarButtonState()
        let leading = taskPanelLeadingConstraint
        taskPanelLeadingConstraint = nil
        var targets: [(NSLayoutConstraint, CGFloat)] = []
        if let leading { targets.append((leading, -taskPanelReserve)) }
        if let workspaceSidebarLeadingConstraint {
            targets.append((workspaceSidebarLeadingConstraint, workspaceSidebarOpenX))
        }
        if let rootLeadingConstraint {
            targets.append((rootLeadingConstraint, mainAreaInset))
        }
        animateSidebarLayout(targets) { [weak self] in
            panel.closeControl.removeFromSuperview()
            panel.removeFromSuperview()
            self?.updateEdgeExpandButton()
            self?.activePane?.focusTerminal()
        }
    }

    /// 全关：task 卡片与工作区栏一组动画同时收。
    ///
    /// 不能串行调 closeTaskPanel + closeWorkspaceSidebar：animateSidebarLayout 启动时
    /// 会掐掉上一个驱动器，前一个的 completion 永远不跑，卡片视图就留在 themeFrame 上。
    private func closeAllSidebars() {
        guard let panel = taskPanel else {
            closeWorkspaceSidebar()
            return
        }
        let sidebar = workspaceSidebar
        endWorkspaceSidebarResize()
        taskPanel = nil
        workspaceSidebar = nil
        updateSidebarButtonState()
        let panelLeading = taskPanelLeadingConstraint
        taskPanelLeadingConstraint = nil
        var targets: [(NSLayoutConstraint, CGFloat)] = []
        if let panelLeading { targets.append((panelLeading, -taskPanelReserve)) }
        if let workspaceSidebarLeadingConstraint {
            targets.append((workspaceSidebarLeadingConstraint, -workspaceSidebarWidth))
        }
        if let rootLeadingConstraint {
            targets.append((rootLeadingConstraint, mainAreaInset))
        }
        animateSidebarLayout(targets) { [weak self] in
            panel.closeControl.removeFromSuperview()
            panel.removeFromSuperview()
            sidebar?.removeFromSuperview()
            self?.workspaceSidebarLeadingConstraint = nil
            self?.workspaceSidebarWidthConstraint = nil
            self?.updateEdgeExpandButton()
            self?.activePane?.focusTerminal()
        }
    }

    // —— task 卡片关着时的左缘展开钮 ——

    /// task 卡片关着时，其展开胶囊吸附在窗口左缘中点（工作区栏开着时正好落在
    /// 它 12pt 的左边沟里）。卡片开/关时重建。
    private func updateEdgeExpandButton() {
        guard let themeFrame = window?.contentView?.superview else { return }
        edgeExpandButton?.removeFromSuperview()
        edgeExpandButton = nil
        edgeExpandStrip?.removeFromSuperview()
        edgeExpandStrip = nil
        guard taskPanel == nil else { return }

        let button = EdgeToggleControl(pointing: .right)
        button.onTap = { [weak self] in self?.openTaskPanel() }
        // 默认隐形；鼠标靠近边界带才浮现
        let strip = EdgeRevealStrip()
        strip.onHoverChange = { [weak button] hovered in button?.reveal(hovered) }
        for v in [strip, button] {
            v.translatesAutoresizingMaskIntoConstraints = false
            themeFrame.addSubview(v)
        }
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: themeFrame.leadingAnchor),
            strip.topAnchor.constraint(equalTo: themeFrame.topAnchor),
            strip.bottomAnchor.constraint(equalTo: themeFrame.bottomAnchor),
            strip.widthAnchor.constraint(equalToConstant: 14),
            button.leadingAnchor.constraint(equalTo: themeFrame.leadingAnchor),
            button.centerYAnchor.constraint(equalTo: themeFrame.centerYAnchor),
        ])
        edgeExpandButton = button
        edgeExpandStrip = strip
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
        AppState.shared.windowControllers.removeAll { $0 === self }
        // 整窗的绑定 pane 一起消失，其他窗口的侧栏活跃态需要跟着退
        NotificationCenter.default.post(name: .lighttyTasksDidChange, object: nil)
    }
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}
