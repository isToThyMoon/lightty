import AppKit
import LighttyCore
import QuartzCore

/// Native button interaction and image layout; only the owned symbol layer rotates.
/// AppKit owns the backing layer's geometry, including its rotation anchor.
/// https://developer.apple.com/library/archive/releasenotes/AppKit/RN-AppKit/#10_13Layer-backed%20Views
final class RefreshButton: NSButton {
    private let glyph = CALayer()
    private static let spinKey = "refresh.spin"
    private static let spinTurn: CFTimeInterval = 0.9
    var isRefreshing = false {
        didSet {
            guard oldValue != isRefreshing else { return }
            updateAnimation()
        }
    }
    private lazy var spinStops = Coalescer(.debounce(Self.spinTurn)) { [weak self] in
        guard let self, !self.isRefreshing else { return }
        self.glyph.removeAnimation(forKey: Self.spinKey)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        cell = SymbolCell(textCell: "")
        isBordered = false
        imagePosition = .imageOnly
        contentTintColor = ShellStyle.secondaryText
        image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: L("Refresh"))
        wantsLayer = true
        glyph.contentsGravity = .resizeAspect
        layer?.addSublayer(glyph)
        updateSymbol()
        updateAnimation()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateAnimation),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    override func layout() {
        super.layout()
        guard let image, let cell else { return }
        // NSCell returns the symbol's alignment rect, not its full image canvas.
        // Draw the canvas at native size, offset by its alignment metadata, as NSButton does.
        // https://developer.apple.com/documentation/appkit/nsimage/alignmentrect
        let aligned = cell.imageRect(forBounds: bounds)
        let yInset = isFlipped ? image.size.height - image.alignmentRect.maxY : image.alignmentRect.minY
        let rect = CGRect(x: aligned.minX - image.alignmentRect.minX,
                          y: aligned.minY - yInset,
                          width: image.size.width, height: image.size.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyph.bounds = CGRect(origin: .zero, size: rect.size)
        glyph.position = CGPoint(x: rect.midX, y: rect.midY)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSymbol()
        updateAnimation()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSymbol()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateSymbol()
    }

    private func updateSymbol() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // NSImage renders lazily, outside this drawing-appearance scope.
            let color = NSColor(cgColor: ShellStyle.secondaryText.cgColor) ?? ShellStyle.secondaryText
            let symbol = image?.withSymbolConfiguration(.init(paletteColors: [color]))
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glyph.contentsScale = window?.backingScaleFactor ?? 2
            glyph.contents = symbol
            CATransaction.commit()
        }
    }

    @objc private func updateAnimation() {
        let title = isRefreshing ? L("Cancel") : L("Refresh")
        toolTip = title
        setAccessibilityLabel(title)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        alphaValue = isRefreshing && reduceMotion ? 0.45 : 1
        guard window != nil, !reduceMotion else {
            spinStops.cancel()
            glyph.removeAnimation(forKey: Self.spinKey)
            return
        }
        guard isRefreshing else {
            // Finish the current revolution before returning to the unrotated symbol.
            guard let animation = glyph.animation(forKey: Self.spinKey) else { return }
            let elapsed = max(0, glyph.convertTime(CACurrentMediaTime(), from: nil) - animation.beginTime)
            spinStops.schedule(delay: Self.spinTurn - elapsed.truncatingRemainder(dividingBy: Self.spinTurn))
            return
        }
        spinStops.cancel()
        guard glyph.animation(forKey: Self.spinKey) == nil else { return }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        // NSButton's flipped (y-down) coordinates make positive angles clockwise onscreen.
        rotation.toValue = 2 * Double.pi
        rotation.beginTime = glyph.convertTime(CACurrentMediaTime(), from: nil)
        rotation.duration = Self.spinTurn
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        glyph.add(rotation, forKey: Self.spinKey)
    }

    private final class SymbolCell: NSButtonCell {
        // Keep AppKit's image sizing; the owned layer draws that image at every angle.
        override func drawImage(_ image: NSImage, withFrame frame: NSRect, in controlView: NSView) {}
    }
}
