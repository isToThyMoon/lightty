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

    override func tile() {
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
