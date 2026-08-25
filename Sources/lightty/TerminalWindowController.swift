import AppKit
import LighttyCore

/// 一个原生 tab 对应一个 controller，内部是嵌套 NSSplitView 的 pane 树。
/// 层级（HANDOVER 8.2）：window（aerospace 管）→ native tab → 分屏布局 → pane。
/// core new_tab 由 AppState 加进 macOS tab group；new_split 才改这里的 pane tree，
/// 并继承当前任务；方向一致插相邻位、方向不同原位包反向 split。
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    /// core `new_tab` 创建的 controller 不应用 INITIAL_SIZE；tab group 沿用父窗口 frame。
    let isNativeTab: Bool

    private enum SidebarPresentation {
        case hidden
        case preview
        case pinned
    }

    private let rootContainer = NSView()
    /// pinned 侧栏是 docked layout：root pane 从侧栏右缘开始；preview 保持 overlay。
    private var rootLeadingConstraint: NSLayoutConstraint?
    private var sidebarView: TaskSidebar?
    private weak var sidebarButton: ShellIconButton?
    private weak var sidebarDismissView: SidebarDismissView?
    private var sidebarLeadingConstraint: NSLayoutConstraint?
    private var sidebarIsAnimating = false
    private var sidebarPresentation: SidebarPresentation = .hidden
    private var sidebarButtonHovered = false
    private var sidebarHovered = false
    private var sidebarHoverDismissWorkItem: DispatchWorkItem?

    private weak var titlebarChrome: NSView?
    private weak var newTabButton: ShellIconButton?
    private var newTabButtonWidthConstraint: NSLayoutConstraint?
    private weak var lastFocusedPane: PaneView?
    private weak var zoomedPane: PaneView?

    init(initialPane: PaneView = PaneView(), isNativeTab: Bool = false) {
        self.isNativeTab = isNativeTab
        let window = TerminalWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640))
        super.init(window: window)
        window.delegate = self
        window.center()

        rootContainer.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = rootContainer
        installTitlebarBackdrop(on: window)
        install(pane: initialPane)
        lastFocusedPane = initialPane
        setRoot(initialPane)
        installTitlebarAccessory(on: window)
        updateWindowTitle(for: initialPane)
        // AppKit 会在 makeKeyAndOrderFront 前后替换一次私有标题栏树；下一轮布局后
        // 再 ensure，避免控件只存在于已脱离窗口的旧 titlebar 中。
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.installTitlebarAccessory(on: window)
            self.updateWindowTitle(for: self.activePane)
        }
    }

    /// 标题栏是应用 chrome，不继承 terminal background/background-opacity。
    /// 参考 Codex 的浅色顶栏使用近白实底和 1pt 底边，终端透明度只留在 content 区。
    private func installTitlebarBackdrop(on window: NSWindow) {
        guard let contentView = window.contentView,
              let themeFrame = contentView.superview else { return }
        let wash = NSView()
        wash.wantsLayer = true
        wash.layer?.backgroundColor = ShellStyle.titlebarBackground.cgColor
        wash.translatesAutoresizingMaskIntoConstraints = false
        // 原生 tab bar 会在首次 new_tab 时动态插入 titlebar container。wash 必须
        // 永远位于整个 container 下方；若只相对 contentView 排序，新 tab 首帧会被
        // 这块不透明底色盖住，直到切换 tab 触发 AppKit 重排。
        var titlebarContainer: NSView? = window.standardWindowButton(.closeButton)
        while let view = titlebarContainer, view.superview !== themeFrame {
            titlebarContainer = view.superview
        }
        if let titlebarContainer {
            themeFrame.addSubview(wash, positioned: .below, relativeTo: titlebarContainer)
        } else {
            themeFrame.addSubview(wash, positioned: .below, relativeTo: contentView)
        }

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = ShellStyle.divider.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        wash.addSubview(divider)
        NSLayoutConstraint.activate([
            wash.topAnchor.constraint(equalTo: themeFrame.topAnchor),
            wash.leadingAnchor.constraint(equalTo: themeFrame.leadingAnchor),
            wash.trailingAnchor.constraint(equalTo: themeFrame.trailingAnchor),
            wash.bottomAnchor.constraint(equalTo: contentView.topAnchor),
            divider.leadingAnchor.constraint(equalTo: wash.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: wash.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: wash.bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    /// 标题栏操作区：三键后是抽屉开关，右侧是高频的新 tab 与分屏。任务名只在
    /// pane header 显示，避免同一名字在 titlebar 与 pane 重复。
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

        let chrome = NSView()
        // Aqua 只属于 lightty 的标题栏控件，不设置到承载 terminal surface 的窗口。
        chrome.appearance = NSAppearance(named: .aqua)
        chrome.translatesAutoresizingMaskIntoConstraints = false
        titlebar.addSubview(chrome)

        let button = ShellIconButton(
            symbol: "sidebar.left", accessibilityLabel: "任务侧边栏", target: self,
            action: #selector(toggleSidebarFromTitlebar))
        button.onHoverChange = { [weak self] hovered in
            self?.sidebarButtonHoverChanged(hovered)
        }

        let newTaskButton = ShellIconButton(
            symbol: "plus", accessibilityLabel: "新标签页", target: self,
            action: #selector(newTaskFromTitlebar))
        let splitButton = ShellIconButton(
            symbol: "rectangle.split.2x1", accessibilityLabel: "向右分 pane", target: self,
            action: #selector(splitFromTitlebar))

        for view in [button, splitButton, newTaskButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            chrome.addSubview(view)
        }
        let newTabWidth = newTaskButton.widthAnchor.constraint(equalToConstant: 28)
        NSLayoutConstraint.activate([
            chrome.leadingAnchor.constraint(equalTo: titlebar.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: titlebar.trailingAnchor),
            chrome.topAnchor.constraint(equalTo: titlebar.topAnchor),
            chrome.bottomAnchor.constraint(equalTo: titlebar.bottomAnchor),

            button.leadingAnchor.constraint(equalTo: zoomButton.trailingAnchor, constant: 9),
            button.centerYAnchor.constraint(equalTo: zoomButton.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 24),

            newTaskButton.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -10),
            newTaskButton.centerYAnchor.constraint(equalTo: zoomButton.centerYAnchor),
            newTabWidth,
            newTaskButton.heightAnchor.constraint(equalToConstant: 24),

            splitButton.trailingAnchor.constraint(equalTo: newTaskButton.leadingAnchor, constant: -3),
            splitButton.centerYAnchor.constraint(equalTo: newTaskButton.centerYAnchor),
            splitButton.widthAnchor.constraint(equalToConstant: 28),
            splitButton.heightAnchor.constraint(equalToConstant: 24),
        ])

        titlebarChrome = chrome
        sidebarButton = button
        newTabButton = newTaskButton
        newTabButtonWidthConstraint = newTabWidth
        updateSidebarButtonState()
        updateNewTabButtonVisibility()
    }

    private func updateWindowTitle(for pane: PaneView?) {
        guard let pane, let window else { return }
        let title = pane.header.title
        window.tab.title = title
        if (window.tabGroup?.windows.count ?? 1) > 1 {
            // 标准 tab bar 需要 visible title mode 才能在每个选中 window 上稳定绘制；
            // 实际系统标题留空，任务名只进入 tab label 与 pane header，不在顶栏重复。
            window.titleVisibility = .visible
            window.title = ""
        } else {
            window.titleVisibility = .hidden
            window.title = title
        }
    }

    private func updateSidebarButtonState() {
        sidebarButton?.isActive = sidebarPresentation == .pinned
    }

    /// 两个以上原生 tab 时，系统 tab bar 已自带「+」；收起自绘入口避免重复。
    /// 回到单 tab、系统 tab bar 自动隐藏后，再恢复标题栏入口。
    private func updateNewTabButtonVisibility() {
        let nativeTabBarOwnsNewTab = window?.tabGroup?.isTabBarVisible ?? false
        newTabButton?.isHidden = nativeTabBarOwnsNewTab
        newTabButtonWidthConstraint?.constant = nativeTabBarOwnsNewTab ? 0 : 28
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window else { return }
        installTitlebarAccessory(on: window)
        updateNewTabButtonVisibility()
        updateWindowTitle(for: activePane)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.installTitlebarAccessory(on: window)
            self.updateNewTabButtonVisibility()
            self.updateWindowTitle(for: self.activePane)
        }
    }

    /// 私有标题栏可能在 becomeKey 回调之后才完成替换；windowDidUpdate 是稳定的
    /// 最终兜底。ensure 有对象身份保护，正常帧不会重复创建控件。
    func windowDidUpdate(_ notification: Notification) {
        guard let window else { return }
        installTitlebarAccessory(on: window)
        updateNewTabButtonVisibility()
        updateWindowTitle(for: activePane)
    }

    @objc private func toggleSidebarFromTitlebar() {
        toggleSidebar()
    }

    @objc private func newTaskFromTitlebar() {
        activePane?.terminal.performBindingAction("new_tab")
    }

    @objc private func splitFromTitlebar() {
        activePane?.terminal.performBindingAction("new_split:right")
    }

    /// 原生 tab bar 的「+」也必须先回到 libghostty；不能绕过 core 直接造窗口。
    override func newWindowForTab(_ sender: Any?) {
        activePane?.terminal.performBindingAction("new_tab")
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - pane 树

    private var rootView: NSView? { rootContainer.subviews.first }

    private func setRoot(_ view: NSView) {
        rootContainer.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        rootContainer.addSubview(view)
        let leading = view.leadingAnchor.constraint(
            equalTo: rootContainer.leadingAnchor,
            constant: sidebarPresentation == .pinned ? TaskSidebar.width : 0)
        rootLeadingConstraint = leading
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: rootContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: rootContainer.bottomAnchor),
            leading,
            view.trailingAnchor.constraint(equalTo: rootContainer.trailingAnchor),
        ])
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
        }
    }

    func panes() -> [PaneView] {
        var result: [PaneView] = []
        func walk(_ view: NSView) {
            if let pane = view as? PaneView {
                result.append(pane)
            } else if let split = view as? NSSplitView {
                split.arrangedSubviews.forEach(walk)
            }
        }
        if let rootView { walk(rootView) }
        return result
    }

    var activePane: PaneView? {
        // 从 firstResponder 向上找 PaneView；找不到取第一个
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
        if let lastFocusedPane, panes().contains(where: { $0 === lastFocusedPane }) {
            return lastFocusedPane
        }
        return panes().first
    }

    /// new_split 动作方向（对应 ghostty_action_split_direction_e）
    enum SplitDirection {
        case right, down, left, up

        var isVertical: Bool { self == .right || self == .left }
        /// 新 pane 落在当前 pane 之后（右/下）还是之前（左/上）
        var insertsAfter: Bool { self == .right || self == .down }
    }

    /// new_split：分屏，新 pane 继承目标 pane 的任务（辅助 shell）。
    /// Ghostty 行为：新 pane 与目标 pane 对半分，其余 pane 尺寸不动。
    func split(
        _ active: PaneView,
        direction: SplitDirection,
        surfaceConfiguration: TerminalSurfaceConfiguration = .init()
    ) {
        restoreSplitZoomIfNeeded()
        let pane = PaneView(surfaceConfiguration: surfaceConfiguration)
        install(pane: pane)
        if let url = active.taskFileURL {
            pane.bind(to: url, name: active.header.title, status: .active)
            pane.header.dot = active.header.dot // 继承任务连同状态点，不重置
        }
        insert(pane, nextTo: active, direction: direction)
        pane.focusTerminal()
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

        if sourceController !== self {
            sourceController.lastFocusedPane = sourceController.panes().first
            if let remaining = sourceController.activePane {
                sourceController.updateWindowTitle(for: remaining)
            } else {
                sourceController.window?.close()
            }
        }
        return true
    }

    /// 把一个已存在的 pane 插到目标旁边。new_split 与 drag/drop 共用同一棵
    /// NSSplitView tree 变换，避免出现两套布局语义。
    private func insert(_ pane: PaneView, nextTo active: PaneView, direction: SplitDirection) {
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
                setRoot(split)
            }
            equalize(split)
        }
    }

    /// 从 split tree 摘下 pane 并递归压平单子节点；不会关闭 surface。
    @discardableResult
    private func detach(pane: PaneView) -> Bool {
        guard panes().contains(where: { $0 === pane }) else { return false }
        if rootView === pane {
            pane.removeFromSuperview()
            rootLeadingConstraint = nil
            return true
        }
        guard let parent = pane.superview as? NSSplitView else { return false }
        parent.removeArrangedSubview(pane)
        pane.removeFromSuperview()
        collapseAfterRemoval(parent)
        return true
    }

    private func collapseAfterRemoval(_ split: NSSplitView) {
        switch split.arrangedSubviews.count {
        case 0:
            if let grand = split.superview as? NSSplitView {
                grand.removeArrangedSubview(split)
                split.removeFromSuperview()
                collapseAfterRemoval(grand)
            } else {
                split.removeFromSuperview()
                rootLeadingConstraint = nil
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
                setRoot(remaining)
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
        guard panes().count > 1, let rootView else { return false }
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

    /// core close_surface / shell 退出
    func close(pane: PaneView) {
        restoreSplitZoomIfNeeded()
        let all = panes()
        guard all.count > 1 else {
            window?.close()
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
                setRoot(remaining)
            }
        }
        panes().first?.focusTerminal()
    }

    // MARK: - pane 导航

    /// core goto_split previous/next：树序前后切换
    func focusPane(offset: Int) {
        let all = panes()
        guard all.count > 1, let active = activePane,
              let index = all.firstIndex(of: active) else { return }
        let next = all[(index + offset + all.count) % all.count]
        next.focusTerminal()
    }

    /// core goto_split direction：几何最近邻
    func focusPane(direction: NSDirectionalRectEdge) {
        guard let active = activePane, let rootView else { return }
        let all = panes().filter { $0 !== active }
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

    // MARK: - 任务侧边栏：hover 预览 / click 钉住
    // 与独立浅色标题栏拼成同一套应用 chrome（红绿灯/按钮浮于其上始终可点）。
    // hover 是临时 overlay，不改变 terminal；click 钉住后变成 docked layout，
    // terminal 从侧栏右缘开始并真实缩窄，空白点击不收起。
    // cmd+K 保留给 Ghostty clear_screen，不再属于侧栏。

    func toggleSidebar() {
        guard let window else { return }
        switch sidebarPresentation {
        case .hidden:
            sidebarPresentation = .pinned
            showSidebar(in: window, withOutsideDismiss: false)
        case .preview:
            sidebarPresentation = .pinned
            cancelSidebarHoverDismiss()
            sidebarDismissView?.removeFromSuperview()
            sidebarDismissView = nil
            updateSidebarButtonState()
            setDockedTerminalInset(TaskSidebar.width, animated: true)
            if !sidebarIsAnimating { sidebarView?.focusSearch() }
        case .pinned:
            requestSidebarClose()
        }
    }

    private func sidebarButtonHoverChanged(_ hovered: Bool) {
        sidebarButtonHovered = hovered
        if hovered {
            cancelSidebarHoverDismiss()
            guard sidebarPresentation == .hidden, let window else { return }
            sidebarPresentation = .preview
            showSidebar(in: window, withOutsideDismiss: true)
        } else {
            scheduleSidebarHoverDismissIfNeeded()
        }
    }

    private func sidebarHoverChanged(_ hovered: Bool) {
        sidebarHovered = hovered
        if hovered {
            cancelSidebarHoverDismiss()
        } else {
            scheduleSidebarHoverDismissIfNeeded()
        }
    }

    private func scheduleSidebarHoverDismissIfNeeded() {
        cancelSidebarHoverDismiss()
        guard sidebarPresentation == .preview,
              !sidebarButtonHovered, !sidebarHovered else { return }
        let work = DispatchWorkItem { [weak self] in self?.dismissSidebarPreviewIfNeeded() }
        sidebarHoverDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
    }

    private func cancelSidebarHoverDismiss() {
        sidebarHoverDismissWorkItem?.cancel()
        sidebarHoverDismissWorkItem = nil
    }

    private func dismissSidebarPreviewIfNeeded() {
        guard sidebarPresentation == .preview,
              !sidebarButtonHovered, !sidebarHovered else { return }
        if sidebarIsAnimating {
            scheduleSidebarHoverDismissIfNeeded()
            return
        }
        requestSidebarClose()
    }

    private func showSidebar(in window: NSWindow, withOutsideDismiss: Bool) {
        guard !sidebarIsAnimating, sidebarView == nil,
              let contentView = window.contentView else { return }
        guard let themeFrame = contentView.superview else { return }
        // 顶到窗口最上缘、垫在标题栏容器之下（三键与侧边栏按钮浮于其上可点）。
        // 不靠私有类名匹配：从关闭按钮向上溯源到 themeFrame 的直接子视图才可靠。
        var titlebarContainer: NSView? = window.standardWindowButton(.closeButton)
        while let v = titlebarContainer, v.superview !== themeFrame {
            titlebarContainer = v.superview
        }
        let titlebarHeight = window.frame.height - contentView.frame.height

        var dismissView: SidebarDismissView?
        if withOutsideDismiss {
            let view = SidebarDismissView()
            view.onDismiss = { [weak self] in self?.dismissSidebarPreviewFromOutside() }
            view.translatesAutoresizingMaskIntoConstraints = false
            if let titlebarContainer {
                themeFrame.addSubview(view, positioned: .below, relativeTo: titlebarContainer)
            } else {
                themeFrame.addSubview(view)
            }
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: contentView.topAnchor),
                view.bottomAnchor.constraint(equalTo: themeFrame.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: themeFrame.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: themeFrame.trailingAnchor),
            ])
            dismissView = view
        }

        let sidebar = TaskSidebar(topInset: max(titlebarHeight, 28))
        sidebar.onRequestClose = { [weak self] in self?.requestSidebarClose() }
        sidebar.onRequestNewTask = { [weak self] in
            guard let self else { return }
            self.requestSidebarClose()
            self.activePane?.terminal.performBindingAction("new_tab")
        }
        sidebar.onHoverChange = { [weak self] hovered in self?.sidebarHoverChanged(hovered) }
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.alphaValue = 1
        if let dismissView {
            themeFrame.addSubview(sidebar, positioned: .above, relativeTo: dismissView)
        } else if let titlebarContainer {
            themeFrame.addSubview(sidebar, positioned: .below, relativeTo: titlebarContainer)
        } else {
            themeFrame.addSubview(sidebar)
        }
        let leading = sidebar.leadingAnchor.constraint(
            equalTo: themeFrame.leadingAnchor, constant: -TaskSidebar.width)
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: themeFrame.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: themeFrame.bottomAnchor),
            leading,
            sidebar.widthAnchor.constraint(equalToConstant: TaskSidebar.width),
        ])

        sidebarView = sidebar
        sidebarDismissView = dismissView
        sidebarLeadingConstraint = leading
        sidebarIsAnimating = true
        themeFrame.layoutSubtreeIfNeeded()
        leading.constant = 0
        rootLeadingConstraint?.constant = sidebarPresentation == .pinned
            ? TaskSidebar.width : 0
        updateSidebarButtonState()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = ShellStyle.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            themeFrame.layoutSubtreeIfNeeded()
        } completionHandler: { [weak self, weak sidebar] in
            guard let self else { return }
            self.sidebarIsAnimating = false
            // hover preview 不偷走 terminal 键盘焦点；只有点击钉住才进搜索框。
            if self.sidebarPresentation == .pinned { sidebar?.focusSearch() }
        }
        installTitlebarAccessory(on: window)
    }

    private func dismissSidebarPreviewFromOutside() {
        guard sidebarPresentation == .preview else { return }
        requestSidebarClose()
    }

    private func requestSidebarClose() {
        guard let window, let sidebar = sidebarView else {
            sidebarPresentation = .hidden
            setDockedTerminalInset(0, animated: false)
            updateSidebarButtonState()
            return
        }
        guard !sidebar.isDirty else { NSSound.beep(); return }
        guard !sidebarIsAnimating else {
            scheduleSidebarHoverDismissIfNeeded()
            return
        }
        sidebarPresentation = .hidden
        cancelSidebarHoverDismiss()
        closeSidebar(sidebar, in: window)
    }

    private func closeSidebar(_ sidebar: TaskSidebar, in window: NSWindow) {
        guard let themeFrame = window.contentView?.superview else { return }
        sidebarIsAnimating = true
        let dismissView = sidebarDismissView
        sidebarView = nil // 先切语义状态，标题栏 context 同步向左归位
        sidebarLeadingConstraint?.constant = -TaskSidebar.width
        rootLeadingConstraint?.constant = 0
        updateSidebarButtonState()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = ShellStyle.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            themeFrame.layoutSubtreeIfNeeded()
        } completionHandler: { [weak self] in
            sidebar.removeFromSuperview()
            dismissView?.removeFromSuperview()
            self?.sidebarLeadingConstraint = nil
            self?.sidebarDismissView = nil
            self?.sidebarIsAnimating = false
            self?.sidebarHovered = false
            self?.activePane?.focusTerminal()
            self?.installTitlebarAccessory(on: window)
        }
    }

    private func setDockedTerminalInset(_ inset: CGFloat, animated: Bool) {
        guard let rootLeadingConstraint,
              rootLeadingConstraint.constant != inset else { return }
        rootLeadingConstraint.constant = inset
        guard animated,
              let themeFrame = window?.contentView?.superview else {
            rootContainer.layoutSubtreeIfNeeded()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = ShellStyle.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            themeFrame.layoutSubtreeIfNeeded()
        }
    }

    func windowWillClose(_ notification: Notification) {
        AppState.shared.windowControllers.removeAll { $0 === self }
    }
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}
