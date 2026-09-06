import AppKit

protocol SidebarHoverRow: AnyObject {
    func setSidebarHovered(_ value: Bool)
}

extension NSView {
    func sidebarHoverEntered() {
        if let scroll = enclosingScrollView as? SidebarListScrollView { scroll.hoverEntered(self) }
        else { (self as? SidebarHoverRow)?.setSidebarHovered(true) }
    }
    func sidebarHoverExited() {
        if let scroll = enclosingScrollView as? SidebarListScrollView { scroll.hoverExited(self) }
        else { (self as? SidebarHoverRow)?.setSidebarHovered(false) }
    }
}

/// Both sidebars share a separate trailing rail: overlay scrollers never cover rows.
class SidebarListScrollView: NSScrollView {
    static let leadingMargin: CGFloat = 12
    static let trailingMargin: CGFloat = 2
    static let railWidth: CGFloat = 16
    private weak var hoveredRow: NSView?
    private var settlingTimer: Timer?
    private var lastScroll: TimeInterval = 0
    private var liveScrolling = false
    var suppressesPointerFeedback: Bool { liveScrolling || settlingTimer != nil }

    func hoverEntered(_ row: NSView) {
        guard !suppressesPointerFeedback, !ShellHoverGate.suppressed else { return }
        changeHover(to: row)
    }

    func hoverExited(_ row: NSView) {
        if hoveredRow === row { changeHover(to: nil) }
    }

    private func changeHover(to row: NSView?) {
        guard hoveredRow !== row else { return }
        (hoveredRow as? SidebarHoverRow)?.setSidebarHovered(false)
        hoveredRow = row
        (row as? SidebarHoverRow)?.setSidebarHovered(true)
    }

    @objc private func didScroll() {
        lastScroll = ProcessInfo.processInfo.systemUptime
        guard !liveScrolling, settlingTimer == nil else { return }
        changeHover(to: nil)
        clearPointerCursor()
        // One timer per scroll burst, including momentum and scrollbar dragging.
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard ProcessInfo.processInfo.systemUptime - self.lastScroll >= 0.08 else { return }
            timer.invalidate()
            self.settlingTimer = nil
            self.restorePointerHover()
        }
        settlingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func willStartLiveScroll() {
        liveScrolling = true
        settlingTimer?.invalidate()
        settlingTimer = nil
        changeHover(to: nil)
        clearPointerCursor()
    }

    @objc private func didEndLiveScroll() {
        liveScrolling = false
        didScroll() // Keep the gate closed through trailing bounds / momentum updates.
    }

    private func clearPointerCursor() {
        guard let window, !isHiddenOrHasHiddenAncestor,
              contentView.frame.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { return }
        NSCursor.arrow.set()
    }

    private func restorePointerHover() {
        guard let window, window.isKeyWindow, !isHiddenOrHasHiddenAncestor,
              !ShellHoverGate.suppressed else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard contentView.frame.contains(point) else { return }
        var candidate = hitTest(convert(point, to: superview))
        while let view = candidate, view !== self {
            if view is SidebarHoverRow {
                changeHover(to: view)
                NSCursor.pointingHand.set()
                return
            }
            candidate = view.superview
        }
        NSCursor.arrow.set()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        hasVerticalScroller = true
        verticalScroller = SidebarScroller()
        autohidesScrollers = true
        drawsBackground = false
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(didScroll),
            name: NSView.boundsDidChangeNotification, object: contentView)
        // Do not override scrollWheel: AppKit treats that as opting out of responsive scrolling.
        NotificationCenter.default.addObserver(self, selector: #selector(willStartLiveScroll),
            name: NSScrollView.willStartLiveScrollNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(didEndLiveScroll),
            name: NSScrollView.didEndLiveScrollNotification, object: self)
        updateScrollerStyle()
        NotificationCenter.default.addObserver(self, selector: #selector(updateScrollerStyle),
            name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit {
        settlingTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func updateScrollerStyle() {
        scrollerStyle = NSScroller.preferredScrollerStyle
        verticalScroller?.controlSize = .small
        tile()
    }

    /// 重入闸。**没有它会 100% CPU 打死**（2026-09-09 两次采样确认），环是这样的：
    ///
    /// ```
    /// tile() → super.tile() → _setContentViewFrame: → NSClipView.setFrameSize:
    ///   → NSTableView.resizeWithOldSuperviewSize: → setFrameSize:
    ///   → _postFrameChangeNotification → _reflectDocumentViewFrameChange
    ///   → reflectScrolledClipView: → _tileWithoutRecursing → 回到 tile()
    /// ```
    ///
    /// `_tileWithoutRecursing` 本来就是 AppKit 的防重入闸，但它挡的是自己那条路；
    /// 我们在被重入调进来的那一层又调一次 `super.tile()`，等于从闸的外面绕回去。
    /// 每一圈 `super.tile()` 把 clip 宽度按 bounds 算回满宽、我们再减掉导轨，两个
    /// 值来回翻，下面那句 `if` 永远不成立，于是转到天荒地老。
    ///
    /// 栈里还夹着 `_fitsWidthInAutohideScrollersScrollView:`——滚动条自动隐藏要
    /// 按宽度决定显不显示，而显不显示又改变可用宽度，这是让两个值真的翻起来的
    /// 那个推手。所以它只在特定行数/宽度组合下发作，平时看不出来。
    private var isTiling = false

    override func tile() {
        // 重入时直接返回：外层那一次还没走完，它的 `super.tile()` 会把这一轮该做的
        // 布局做完，回来再统一收窄。这里再调一次 `super.tile()` 就是重新点火。
        guard !isTiling else { return }
        isTiling = true
        defer { isTiling = false }
        super.tile()
        // Reserve the same rail even while hidden, so rows don't jump as scrolling starts.
        var frame = contentView.frame
        frame.size.width = max(0, min(frame.width, bounds.width - Self.railWidth - frame.minX))
        if contentView.frame != frame { contentView.frame = frame }
    }
}

/// Keep native scrolling/hit testing, with a quieter thumb than the system default.
final class SidebarScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnob() {
        let rect = rect(for: .knob)
        guard !rect.isEmpty else { return }
        let width = min(rect.width, 6)
        let thumb = NSRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: rect.height)
        ShellStyle.sidebarScrollThumb.setFill()
        NSBezierPath(roundedRect: thumb, xRadius: width / 2, yRadius: width / 2).fill()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // The sidebar already provides a dedicated rail; no additional dark track is needed.
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
