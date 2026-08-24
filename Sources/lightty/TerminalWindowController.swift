import AppKit
import LighttyCore

/// 一个终端窗口：内部是嵌套 NSSplitView 的 pane 树。
/// 层级（HANDOVER 8.2）：window（aerospace 管）→ 分屏布局（纯布局）→ pane（任务绑定点）。
/// cmd+T 新任务 pane 加在顶层右侧；cmd+D/cmd+shift+D 分屏继承当前任务；
/// 方向一致插相邻位、方向不同原位包反向 split。
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    private let rootContainer = NSView()
    private var sidebarView: TaskSidebar?
    private weak var sidebarButton: NSButton?

    init(initialPane: PaneView = PaneView()) {
        let window = TerminalWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640))
        super.init(window: window)
        window.delegate = self
        window.center()

        rootContainer.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = rootContainer
        installTitlebarBackdrop(on: window)
        installTitlebarAccessory(on: window)
        install(pane: initialPane)
        setRoot(initialPane)
    }

    /// 标题栏条的水洗底：与终端/pane header 同公式（background × background-opacity），
    /// 否则透明标题栏露出裸模糊壁纸，与下方内容割裂。侧边栏展开时其自身水洗层
    /// 覆盖左段，同色无缝。
    private func installTitlebarBackdrop(on window: NSWindow) {
        guard let contentView = window.contentView,
              let themeFrame = contentView.superview else { return }
        let cfg = GhosttyRuntime.shared.configValues
        let wash = NSView()
        wash.wantsLayer = true
        wash.layer?.backgroundColor = cfg.backgroundColor
            .withAlphaComponent(cfg.backgroundOpacity).cgColor
        wash.translatesAutoresizingMaskIntoConstraints = false
        themeFrame.addSubview(wash, positioned: .below, relativeTo: contentView)
        NSLayoutConstraint.activate([
            wash.topAnchor.constraint(equalTo: themeFrame.topAnchor),
            wash.leadingAnchor.constraint(equalTo: themeFrame.leadingAnchor),
            wash.trailingAnchor.constraint(equalTo: themeFrame.trailingAnchor),
            wash.bottomAnchor.constraint(equalTo: contentView.topAnchor),
        ])
    }

    /// 标题栏操作区：三键之后放侧边栏开关（对不惯快捷键的用户可见可点）。
    /// 直接挂进标题栏视图并以缩放键锚点对齐，保证与红绿灯严格同一水平线。
    /// ⚠️ 标题栏是私有视图，会在侧边栏插拔/全屏切换时重建并丢掉外来子视图——
    /// 所以做成幂等的 ensure：掉了就重装（toggle 与窗口激活时都会调）。
    private func installTitlebarAccessory(on window: NSWindow) {
        if let button = sidebarButton, button.superview != nil { return }
        guard let zoomButton = window.standardWindowButton(.zoomButton),
              let titlebar = zoomButton.superview else { return }

        let button = NSButton(
            image: NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "任务侧边栏")!,
            target: self,
            action: #selector(toggleSidebarFromTitlebar))
        button.isBordered = false
        button.toolTip = "任务侧边栏 (⌘K)"
        button.contentTintColor = GhosttyRuntime.shared.configValues.foregroundColor
            .withAlphaComponent(0.75)
        button.translatesAutoresizingMaskIntoConstraints = false
        titlebar.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: zoomButton.trailingAnchor, constant: 10),
            button.centerYAnchor.constraint(equalTo: zoomButton.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 22),
            button.heightAnchor.constraint(equalToConstant: 20),
        ])
        sidebarButton = button
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let window { installTitlebarAccessory(on: window) }
    }

    @objc private func toggleSidebarFromTitlebar() {
        toggleSidebar()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - pane 树

    private var rootView: NSView? { rootContainer.subviews.first }

    private func setRoot(_ view: NSView) {
        rootContainer.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        rootContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: rootContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: rootContainer.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: rootContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: rootContainer.trailingAnchor),
        ])
    }

    private func install(pane: PaneView) {
        pane.onClose = { [weak self] p in self?.close(pane: p) }
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
        return panes().first
    }

    /// cmd+T：新任务 pane，顶层右侧并排
    func newTaskPaneRight() {
        let pane = PaneView()
        install(pane: pane)
        guard let rootView else { setRoot(pane); return }
        if let split = rootView as? NSSplitView, split.isVertical {
            split.addArrangedSubview(pane)
            equalize(split)
        } else {
            let split = makeSplit(vertical: true)
            rootView.removeFromSuperview()
            split.addArrangedSubview(rootView)
            split.addArrangedSubview(pane)
            setRoot(split)
            equalize(split)
        }
        pane.focusTerminal()
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
    func split(_ active: PaneView, direction: SplitDirection) {
        let pane = PaneView()
        install(pane: pane)
        if let url = active.taskFileURL {
            pane.bind(to: url, name: active.header.title, status: .active)
            pane.header.dot = active.header.dot // 继承任务连同状态点，不重置
        }
        let vertical = direction.isVertical

        if let parent = active.superview as? NSSplitView, parent.isVertical == vertical {
            // 方向一致：插在当前 pane 相邻位
            let index = parent.arrangedSubviews.firstIndex(of: active) ?? parent.arrangedSubviews.count - 1
            var sizes = parent.arrangedSubviews.map { axisSize($0, vertical: parent.isVertical) }
            let half = (sizes[index] - parent.dividerThickness) / 2
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
        pane.focusTerminal()
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

    /// 全部子视图均分（cmd+T 顶层各列 / 新建反向 split 的两半）
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

    /// cmd+W / shell 退出
    func close(pane: PaneView) {
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

    /// cmd+] / cmd+[：树序前后切换
    func focusPane(offset: Int) {
        let all = panes()
        guard all.count > 1, let active = activePane,
              let index = all.firstIndex(of: active) else { return }
        let next = all[(index + offset + all.count) % all.count]
        next.focusTerminal()
    }

    /// cmd+alt+方向：几何最近邻
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

    // MARK: - 任务侧边栏：一体式覆盖层（cmd+K / 标题栏按钮）
    // 与透明化标题栏连成一片（红绿灯/按钮浮于其上始终可点），
    // **覆盖**在终端之上——不推挤布局，terminal 不发生 resize（推挤实测有闪烁）。
    // 常驻直到手动收起（按钮/cmd+K/Esc）。

    func toggleSidebar() {
        guard let window, let contentView = window.contentView else { return }
        if let sidebar = sidebarView {
            guard !sidebar.isDirty else { NSSound.beep(); return } // 脏编辑钉住
            sidebar.removeFromSuperview()
            sidebarView = nil
            activePane?.focusTerminal()
            installTitlebarAccessory(on: window)
            return
        }
        guard let themeFrame = contentView.superview else { return }
        // 顶到窗口最上缘、垫在标题栏容器之下（三键与侧边栏按钮浮于其上可点）。
        // 不靠私有类名匹配：从关闭按钮向上溯源到 themeFrame 的直接子视图才可靠。
        var titlebarContainer: NSView? = window.standardWindowButton(.closeButton)
        while let v = titlebarContainer, v.superview !== themeFrame {
            titlebarContainer = v.superview
        }
        let titlebarHeight = window.frame.height - contentView.frame.height

        let sidebar = TaskSidebar(topInset: max(titlebarHeight, 28))
        sidebar.onRequestClose = { [weak self] in self?.toggleSidebar() }
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        if let titlebarContainer {
            themeFrame.addSubview(sidebar, positioned: .below, relativeTo: titlebarContainer)
        } else {
            themeFrame.addSubview(sidebar)
        }
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: themeFrame.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: themeFrame.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: themeFrame.leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: TaskSidebar.width),
        ])
        sidebarView = sidebar
        sidebar.focusSearch()
        installTitlebarAccessory(on: window)
    }

    func windowWillClose(_ notification: Notification) {
        AppState.shared.windowControllers.removeAll { $0 === self }
    }
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}
