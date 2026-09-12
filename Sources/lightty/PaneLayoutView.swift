import AppKit
import LighttyCore

/// 一个标签页的 pane 容器：按 `PaneLayout` 直接用 frame 摆放 pane 与分隔线。
///
/// 为什么不再用 NSSplitView：它用约束排布子视图，短时间内连续改动子视图（摘掉一个
/// pane、解包、把剩下的挂到别处）会让它的内部约束与 Auto Layout 求解器对不上，
/// 求解器直接抛 NSInternalInconsistencyException。实测把整棵分屏树先摘离窗口再拆
/// 也照样炸，只有每摘一个子视图就先让它重新布局一次才能躲过——那是在猜 AppKit 的
/// 内部时序。这里整个排布只有 frame：pane 在标签页之间搬家就是一次 addSubview，
/// 不经过任何排布约束，这一整类问题不存在。
///
/// 模型不归这个视图管：它只渲染控制器给的排布，分隔线拖动算出新排布后交回控制器，
/// 由控制器写回模型再渲染回来。
final class PaneLayoutView: NSView {
    static let dividerThickness: CGFloat = 1
    /// 拖分隔线时单个 pane 不小于这个尺寸：再窄终端连一行字都放不下，
    /// 0 尺寸的 surface 还会让内核的尺寸计算出怪值。
    static let minimumPaneSize: CGFloat = 40

    /// 分隔线拖出的新排布（拖动过程中逐帧回调）。
    var onLayoutChange: ((PaneLayout) -> Void)?
    /// 一次分隔线拖动结束：比例定型，适合落盘。
    var onLayoutChangeEnded: (() -> Void)?

    private(set) var layoutModel: PaneLayout?
    private(set) var zoomedPane: UUID?
    private var panes: [UUID: PaneView] = [:]
    private var dividers: [PaneDividerView] = []

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        // 分隔线颜色取自终端配置（split-divider-color），配置重载后要重画。
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshDividerAppearance),
            name: .ghosttyGlobalConfigDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// 渲染一份排布。`lookup` 是整个窗口的 pane 注册表，不只是本标签页的。
    ///
    /// 树里的 pane 挂进来：从别的标签页或别的窗口搬来，就是换个父视图。
    /// 已经不在注册表里的 pane（被关掉、或搬去了别的窗口）摘掉。
    /// 还在注册表里、只是不归本标签页的 pane 留给它的新容器来接：同一次提交里新容器
    /// 渲染时直接把它接走，它一刻也不离开窗口；先摘再接会让终端 surface 白白脱离一次窗口。
    /// 摆完 frame 才返回，调用方拿到的几何已经就位。
    func render(_ layout: PaneLayout?, zoomed: UUID?, panes lookup: [UUID: PaneView]) {
        layoutModel = layout
        let ids = layout?.panes ?? []
        zoomedPane = zoomed.flatMap { ids.contains($0) ? $0 : nil }
        for case let pane as PaneView in subviews where lookup[pane.dragIdentifier] == nil {
            pane.removeFromSuperview()
        }
        var next: [UUID: PaneView] = [:]
        for id in ids {
            guard let pane = lookup[id] else { continue }
            next[id] = pane
            guard pane.superview !== self else { continue }
            pane.translatesAutoresizingMaskIntoConstraints = true
            pane.autoresizingMask = []
            // 分隔线的命中区压在 pane 边缘上，pane 必须在它们下面。
            addSubview(pane, positioned: .below, relativeTo: dividers.first)
        }
        panes = next
        applyGeometry()
    }

    override func layout() {
        super.layout()
        applyGeometry()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyGeometry()
    }

    @objc private func refreshDividerAppearance() {
        dividers.forEach { $0.needsDisplay = true }
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    private func applyGeometry() {
        guard let layout = layoutModel, bounds.width > 0, bounds.height > 0 else {
            dividers.forEach { $0.isHidden = true }
            return
        }
        if let zoomed = zoomedPane {
            for (id, pane) in panes {
                pane.isHidden = id != zoomed
                if id == zoomed { setFrame(bounds, of: pane) }
            }
            dividers.forEach { $0.isHidden = true }
            return
        }
        let geometry = layout.geometry(in: bounds, dividerThickness: Self.dividerThickness, scale: scale)
        for (id, pane) in panes {
            pane.isHidden = false
            if let frame = geometry.panes[id] { setFrame(frame, of: pane) }
        }
        syncDividers(to: geometry.dividers)
    }

    /// frame 没变就不写：每次赋值都会让终端 surface 重算一次尺寸。
    private func setFrame(_ frame: NSRect, of view: NSView) {
        if view.frame != frame { view.frame = frame }
    }

    private func syncDividers(to specs: [PaneLayoutGeometry.Divider]) {
        while dividers.count < specs.count {
            let divider = PaneDividerView()
            divider.onDrag = { [weak self, weak divider] position in
                guard let self, let divider else { return }
                self.dragDivider(divider.spec, to: position)
            }
            divider.onDragEnded = { [weak self] in self?.onLayoutChangeEnded?() }
            addSubview(divider)  // 恒在 pane 之上
            dividers.append(divider)
        }
        for (index, divider) in dividers.enumerated() {
            guard specs.indices.contains(index) else {
                divider.isHidden = true
                continue
            }
            divider.isHidden = false
            divider.apply(specs[index])
        }
    }

    private func dragDivider(_ spec: PaneLayoutGeometry.Divider, to position: CGFloat) {
        guard let layout = layoutModel else { return }
        let moved = layout.movingDivider(
            at: spec.path, index: spec.index, to: position, in: bounds,
            dividerThickness: Self.dividerThickness, scale: scale, minimumSize: Self.minimumPaneSize)
        guard moved != layout else { return }
        onLayoutChange?(moved)
    }
}

/// 分隔线：画 1pt 的线，命中区两侧各放宽几 pt（与 NSSplitView 细分隔线手感一致）。
final class PaneDividerView: NSView {
    /// 命中区在线条两侧各放宽的距离。
    static let hitSlop: CGFloat = 3

    var onDrag: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    private(set) var spec = PaneLayoutGeometry.Divider(path: [], index: 0, axis: .horizontal, rect: .zero)

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ next: PaneLayoutGeometry.Divider) {
        let axisChanged = next.axis != spec.axis
        spec = next
        let slop = Self.hitSlop
        let hit = next.axis == .horizontal
            ? next.rect.insetBy(dx: -slop, dy: 0)
            : next.rect.insetBy(dx: 0, dy: -slop)
        if frame != hit {
            frame = hit
            needsDisplay = true
        }
        if axisChanged {
            setAccessibilityOrientation(next.axis == .horizontal ? .vertical : .horizontal)
            window?.invalidateCursorRects(for: self)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        GhosttyRuntime.shared.configValues.splitDividerColor.setFill()
        let slop = Self.hitSlop
        let line = spec.axis == .horizontal
            ? NSRect(x: slop, y: 0, width: bounds.width - slop * 2, height: bounds.height)
            : NSRect(x: 0, y: slop, width: bounds.width, height: bounds.height - slop * 2)
        line.fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: spec.axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    /// 自建跟踪循环：位置直接跟到光标，每帧交给容器重算排布。抓取点相对线条起点的
    /// 偏移保持不变，线不会在按下那一刻跳到光标下。
    override func mouseDown(with event: NSEvent) {
        guard let host = superview else { return }
        let horizontal = spec.axis == .horizontal
        func coordinate(_ e: NSEvent) -> CGFloat {
            let point = host.convert(e.locationInWindow, from: nil)
            return horizontal ? point.x : point.y
        }
        let lineStart = horizontal ? spec.rect.minX : spec.rect.minY
        let grab = coordinate(event) - lineStart
        while let next = NSApp.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture,
            inMode: .eventTracking, dequeue: true
        ) {
            if next.type == .leftMouseUp { break }
            onDrag?(coordinate(next) - grab)
        }
        onDragEnded?()
    }
}
