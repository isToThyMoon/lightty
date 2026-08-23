import AppKit
import LighttyCore

/// 一个终端窗口：内部是嵌套 NSSplitView 的 pane 树。
/// 层级（HANDOVER 8.2）：window（aerospace 管）→ 分屏布局（纯布局）→ pane（任务绑定点）。
/// cmd+T 新任务 pane 加在顶层右侧；cmd+D/cmd+shift+D 分屏继承当前任务；
/// 方向一致插相邻位、方向不同原位包反向 split。
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    private let rootContainer = NSView()
    private var sidebarView: TaskSidebar?
    private var sidebarClickMonitor: Any?

    init(initialPane: PaneView = PaneView()) {
        let window = TerminalWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640))
        super.init(window: window)
        window.delegate = self
        window.center()

        rootContainer.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = rootContainer
        install(pane: initialPane)
        setRoot(initialPane)
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

    // MARK: - 任务侧边栏：悬浮左侧卡片，任务管理唯一入口（cmd+K）

    func toggleSidebar() {
        if let sidebar = sidebarView {
            guard !sidebar.isDirty else { NSSound.beep(); return } // 脏编辑钉住
            sidebar.removeFromSuperview()
            sidebarView = nil
            removeSidebarClickMonitor()
            activePane?.focusTerminal()
            return
        }
        guard let contentView = window?.contentView else { return }
        let sidebar = TaskSidebar()
        sidebar.onRequestClose = { [weak self] in self?.toggleSidebar() }
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(sidebar) // 加在 rootContainer 之后 → 悬浮于 pane 之上
        let inset = TaskSidebar.inset
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: PaneHeaderView.height + inset),
            sidebar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -inset),
            sidebar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: inset),
            sidebar.widthAnchor.constraint(equalToConstant: TaskSidebar.width),
        ])
        sidebarView = sidebar
        sidebar.focusSearch()

        // 点击卡片外的空白处（终端区域）自动收起；脏编辑时钉住不关
        sidebarClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let sidebar = self.sidebarView,
                  event.window === self.window else { return event }
            let point = sidebar.convert(event.locationInWindow, from: nil)
            if !sidebar.bounds.contains(point), !sidebar.isDirty {
                self.toggleSidebar()
            }
            return event
        }
    }

    private func removeSidebarClickMonitor() {
        if let monitor = sidebarClickMonitor {
            NSEvent.removeMonitor(monitor)
            sidebarClickMonitor = nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        removeSidebarClickMonitor()
        AppState.shared.windowControllers.removeAll { $0 === self }
    }
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}
