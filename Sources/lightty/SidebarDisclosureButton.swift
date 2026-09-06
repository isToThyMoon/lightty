import AppKit
import QuartzCore

/// Native button sizing/accessibility, with a separate centered, interruptible chevron layer.
final class SidebarDisclosureButton: NSButton {
    private let chevron = ChevronView()
    private(set) var expanded = true
    private(set) var disclosureLayer: CALayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        cell = DisclosureCell(textCell: "")
        isBordered = false
        font = .systemFont(ofSize: 12, weight: .medium)
        imagePosition = .imageTrailing
        image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        contentTintColor = ShellStyle.primaryText
        addSubview(chevron)
        disclosureLayer = chevron.glyph
        setExpanded(true, animated: false)
    }
    convenience init(title: String) { self.init(frame: .zero); self.title = title }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let rect = cell?.imageRect(forBounds: bounds) ?? .zero
        chevron.frame = NSRect(x: rect.midX - 6, y: bounds.midY - 6, width: 12, height: 12)
    }

    func setExpanded(_ value: Bool, animated: Bool) {
        expanded = value
        setAccessibilityValue(value ? L("Expanded") : L("Collapsed"))
        guard let layer = disclosureLayer else { return }
        let angle = value ? CGFloat.pi / 2 : 0
        let previous = (layer.presentation() ?? layer).value(forKeyPath: "transform.rotation.z") as? CGFloat ?? 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(angle, forKeyPath: "transform.rotation.z")
        CATransaction.commit()
        layer.removeAnimation(forKey: "disclosure")
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.fromValue = previous
            animation.toValue = angle
            animation.duration = ShellStyle.animationDuration
            animation.timingFunction = ShellStyle.easeInOutCubic
            layer.add(animation, forKey: "disclosure")
        }
    }

    private final class DisclosureCell: NSButtonCell {
        // Reserve native image space; the child layer renders the icon instead.
        override func drawImage(_ image: NSImage, withFrame frame: NSRect, in controlView: NSView) {}
    }
    /// Rotate a sublayer, never the AppKit-owned backing layer (whose anchor/position
    /// AppKit changes during layout). That keeps the rotation pivot at the icon's center.
    private final class ChevronView: NSView {
        let glyph = CAShapeLayer()
        override var isFlipped: Bool { true }
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 4, y: 2))
            path.addLine(to: CGPoint(x: 8, y: 6))
            path.addLine(to: CGPoint(x: 4, y: 10))
            glyph.path = path
            glyph.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
            glyph.fillColor = nil
            glyph.lineWidth = 1.4
            glyph.lineCap = .round
            glyph.lineJoin = .round
            layer?.addSublayer(glyph)
            applyColors()
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glyph.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColors() }
        private func applyColors() { glyph.strokeColor = ShellStyle.primaryText.shellResolvedCGColor(for: effectiveAppearance) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
