import AppKit
import LighttyCore

/// Native text, with color-only emphasis for unread status reminders. AppKit owns
/// text layout and animation timing; neither the row nor its geometry animates.
final class PaneStatusLabel: NSTextField, NSAnimationDelegate {
    private(set) var activity: PaneActivity?
    private var isUnread = false
    private(set) var breath: StatusColorAnimation?

    /// Presentation receives activity and acknowledgement together from the shared model.
    func apply(_ status: PaneStatus?, isUnread: Bool) {
        activity = status?.state
        self.isUnread = isUnread
        let text = TabPaneStatusPresentation.text(for: status)
        isHidden = text == nil
        stringValue = text.map { activity == .done ? "✓ \($0)" : $0 } ?? ""
        setAccessibilityLabel(text)
        font = emphasizedColor != nil
            ? .systemFont(ofSize: 11.5, weight: .semibold)
            : .systemFont(ofSize: 10.5, weight: .medium)
        updateAnimation()
        applyColor(progress: breath?.currentProgress ?? 0)
    }

    private var emphasizedColor: NSColor? {
        switch activity {
        case .done: return ShellStyle.statusDone
        case .attention: return ShellStyle.statusAttention
        default: return nil
        }
    }

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBezeled = false
        isBordered = false
        drawsBackground = false
        isHidden = true
        font = .systemFont(ofSize: 10.5, weight: .medium)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateAnimation),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateAnimation),
            name: NSWindow.didChangeOcclusionStateNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit {
        breath?.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateAnimation() }
    override func viewDidHide() { super.viewDidHide(); updateAnimation() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateAnimation() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor(progress: breath?.currentProgress ?? 0)
    }

    @objc private func updateAnimation() {
        let animate = emphasizedColor != nil && isUnread && !isHiddenOrHasHiddenAncestor
            && window?.occlusionState.contains(.visible) == true
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animate {
            guard breath == nil else { return }
            let animation = StatusColorAnimation(label: self)
            breath = animation
            animation.delegate = self
            animation.start()
        } else {
            breath?.stop()
            breath = nil
            applyColor(progress: 0)
        }
    }

    func animationDidEnd(_ animation: NSAnimation) {
        guard animation === breath else { return }
        breath = nil
        updateAnimation()
    }

    fileprivate func applyColor(progress: NSAnimation.Progress) {
        guard let color = emphasizedColor else { textColor = ShellStyle.secondaryText; return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // Keep at least 80% of the status accent, even at the quietest phase.
            let fraction = 0.1 * (1 - cos(2 * .pi * CGFloat(progress)))
            textColor = color.blended(withFraction: fraction, of: ShellStyle.secondaryText) ?? color
        }
    }
}

/// Apple's documented NSAnimation subclass seam: override currentProgress and
/// update the native control. No custom drawing, layer replacement or polling.
/// https://developer.apple.com/documentation/appkit/nsanimation
final class StatusColorAnimation: NSAnimation {
    private weak var label: PaneStatusLabel?
    init(label: PaneStatusLabel) {
        self.label = label
        super.init(duration: 3.2, animationCurve: .linear)
        animationBlockingMode = .nonblocking
        frameRate = 30
    }
    required init?(coder: NSCoder) { fatalError() }
    override var currentProgress: NSAnimation.Progress {
        didSet { label?.applyColor(progress: currentProgress) }
    }
}
