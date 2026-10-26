import AppKit
import LighttyCore

/// A window-local, disposable observer of the focused Agent's session log.
/// It only reads the file the hook reported; the Agent and PTY never depend on it.
final class AgentOutputMeterView: NSView {
    private let pet = CALayer()
    private var sprite: PixelSprite?
    private var pixels: [(layer: CALayer, ink: PixelSprite.Ink)] = []
    /// One container per `PixelSprite.frames` key; animating them alternates or blinks the group.
    private var frameLayers: [CALayer] = []
    private let speed = NSTextField(labelWithString: "")
    private var timer: Timer?
    private var thinking = false
    private var streaming = false
    /// The log being followed. `meter` itself lives on `readQueue` only.
    private var source: (pane: UUID, url: URL)?
    private var meter: TranscriptSpeedMeter?
    private let readQueue = DispatchQueue(label: "lightty.output-meter", qos: .utility)
    private var controller: TerminalWindowController? {
        window?.windowController as? TerminalWindowController
    }

    private static let explanation = L("Output speed of recent model requests in the selected terminal: output tokens divided by the time from sending each request to its completion, including the wait for the first token. Read from the Agent's session log; updates when a request finishes.")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(pet)
        show(agent: nil)
        speed.font = .monospacedDigitSystemFont(ofSize: ShellStyle.Font.body.pointSize, weight: .medium)
        speed.textColor = ShellStyle.secondaryText
        speed.lineBreakMode = .byClipping
        addSubview(speed)
        toolTip = Self.explanation
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L("Output speed unavailable"))
        setAccessibilityHelp(Self.explanation)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification, .lighttySessionLibraryDidChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: name, object: nil)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refresh),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private var isVisible: Bool {
        guard let window else { return false }
        return window.isKeyWindow && window.occlusionState.contains(.visible)
            && !isHiddenOrHasHiddenAncestor
    }

    @objc private func refresh() {
        let pane = controller?.activePane
        let state = pane?.sessionState
        let agent = state?.sessionKey?.agent
        let available = agent != nil && state?.status?.event != "SessionEnd"
        show(agent: agent)
        thinking = state?.status?.state == .thinking
        guard isVisible, available, let pane, let agent,
              let path = pane.sessionLibrary.transcriptPath(for: pane.dragIdentifier) else {
            stop(hasAgent: available)
            return
        }
        let url = URL(fileURLWithPath: path)
        if source?.pane != pane.dragIdentifier || source?.url != url {
            source = (pane.dragIdentifier, url)
            let format = agent.spec.transcriptFormat
            readQueue.async { [weak self] in self?.meter = TranscriptSpeedMeter(url: url, format: format) }
            render(nil, hasAgent: true)
            poll()
        }
        updateAnimation()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh(); self?.poll() }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .default)
        self.timer = timer
    }

    /// Reads only bytes appended since the last poll, off the main thread.
    private func poll() {
        guard let url = source?.url else { return }
        readQueue.async { [weak self] in
            guard let self, let meter = self.meter, meter.url == url else { return }
            let window = meter.poll()
            DispatchQueue.main.async {
                guard self.source?.url == url else { return }
                self.render(window.tokensPerSecond, hasAgent: true, latest: window.latest,
                            characters: window.charactersPerSecond, following: true)
            }
        }
    }

    private func stop(hasAgent: Bool) {
        timer?.invalidate()
        timer = nil
        source = nil
        readQueue.async { [weak self] in self?.meter = nil }
        render(nil, hasAgent: hasAgent)
    }

    /// `following`: the log is readable but may hold no request long enough to measure yet.
    /// `characters`: visible text per second, comparable across Agents whose tokenizers differ.
    func render(_ value: Double?, hasAgent: Bool, latest: TranscriptSpeedSample? = nil,
                characters: Double? = nil, following: Bool = false) {
        let value = value.flatMap { $0.isFinite && $0 > 0 && hasAgent ? $0 : nil }
        pet.isHidden = !hasAgent
        let text = value.map { $0 < 1 ? "<1 tok/s" : "\(Int(min($0.rounded(), 999_999))) tok/s" }
            ?? (following && hasAgent ? "– tok/s" : "")
        if speed.stringValue != text {
            speed.stringValue = text
            needsLayout = true
            setAccessibilityLabel(value == nil ? L("Output speed unavailable") : L("Output speed: %@", text))
        }
        let rate = characters.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }.map {
            L("Text: %@ characters/s. Characters compare across Agents; tokens do not, because each tokenizer splits text differently.", "\(Int($0.rounded()))")
        }
        let detail = latest.map { sample in
            let tokens = sample.reasoningTokens.map { $0 > 0 ? L("%1$@ tokens, %2$@ of them thinking", "\(sample.outputTokens)", "\($0)") : nil }
                ?? nil
            return L("Last request: %1$@, %2$@ characters of text, %3$@ s",
                     tokens ?? L("%@ tokens", "\(sample.outputTokens)"), "\(sample.visibleCharacters)",
                     String(format: "%.1f", sample.duration))
        } ?? (following && hasAgent ? L("No request long enough to measure yet. Replies under %@ output tokens are mostly waiting for the first token and are not counted.", "\(TranscriptSpeedWindow.minimumTokens)") : nil)
        toolTip = [Self.explanation, rate, detail].compactMap { $0 }.joined(separator: "\n\n")
        setAccessibilityValue(rate)
        streaming = value != nil
        updateAnimation()
    }

    /// Pixel art for the focused Agent; unknown Agents get a neutral blob.
    func show(agent: SessionAgent?) {
        let next = agent?.spec.sprite ?? Self.genericSprite
        guard next != sprite else { return }
        sprite = next
        // New layers would otherwise fade in from transparent.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        pet.sublayers?.forEach { $0.removeFromSuperlayer() }
        frameLayers = next.frames.map { _ in CALayer() }
        frameLayers.forEach(pet.addSublayer)
        pixels = next.pixels.compactMap { pixel in
            guard let ink = next.inks[pixel.key] else { return nil }
            let layer = CALayer()
            layer.setValue(CGPoint(x: pixel.column, y: pixel.row), forKey: "cell")
            (next.frames.firstIndex(of: pixel.key).map { frameLayers[$0] } ?? pet).addSublayer(layer)
            return (layer, ink)
        }
        applyColors()
        needsLayout = true
        updateAnimation(restart: true)
    }

    private static let genericSprite = PixelSprite(
        rows: ["..BBBBBB..", ".BBBBBBBB.", "BBEBBBBEBB", "BBEBBBBEBB", "BBBBBBBBBB", ".BBBBBBBB."],
        inks: ["B": .faint, "E": .foreground])

    /// The pet only moves while the Agent is generating; speed never drives its frequency.
    /// At rest the first frame group stays visible (feet planted, cursor shown).
    private func updateAnimation(restart: Bool = false) {
        let moving = streaming && thinking && isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if restart || !moving {
            pet.removeAnimation(forKey: "float")
            frameLayers.forEach { $0.removeAnimation(forKey: "frame") }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, layer) in frameLayers.enumerated() { layer.opacity = index == 0 ? 1 : 0 }
        CATransaction.commit()
        guard moving, pet.animation(forKey: "float") == nil else { return }
        let float = CABasicAnimation(keyPath: "transform.translation.y")
        float.fromValue = 0
        float.toValue = 2
        float.duration = 1.4
        float.autoreverses = true
        float.repeatCount = .infinity
        float.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pet.add(float, forKey: "float")
        // Two groups alternate (stepping); a single group blinks (cursor).
        let count = max(frameLayers.count, 2)
        for (index, layer) in frameLayers.enumerated() {
            let frame = CAKeyframeAnimation(keyPath: "opacity")
            frame.values = (0..<count).map { $0 == index ? 1 : 0 }
            frame.keyTimes = (0..<count).map { NSNumber(value: Double($0) / Double(count)) }
            frame.calculationMode = .discrete
            frame.duration = frameLayers.count == 1 ? 1.0 : 0.6
            frame.repeatCount = .infinity
            layer.add(frame, forKey: "frame")
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let columns = CGFloat(sprite?.columns ?? 1), rows = CGFloat(sprite?.rows.count ?? 1)
        let cell = max(1, floor(min(26 / columns, 22 / rows)))
        let size = NSSize(width: columns * cell, height: rows * cell)
        // Left edge follows the sidebar content start; every sprite is centered on the titlebar midline.
        pet.frame = NSRect(x: 0, y: floor((bounds.height - size.height) / 2),
                           width: size.width, height: size.height)
        for layer in [pet] + frameLayers where layer !== pet { layer.frame = pet.bounds }
        for (layer, _) in pixels {
            guard let point = layer.value(forKey: "cell") as? CGPoint else { continue }
            // Rows read top-down; layer y grows upward.
            layer.frame = NSRect(x: point.x * cell, y: size.height - (point.y + 1) * cell, width: cell, height: cell)
        }
        CATransaction.commit()
        // Center the digits' cap height on the same midline as the sprite and the traffic lights.
        let font = speed.font ?? ShellStyle.Font.body
        let height = ceil(speed.intrinsicContentSize.height)
        speed.frame = NSRect(x: 36, y: 0, width: max(0, bounds.width - 36), height: height)
        let baseline = bounds.midY - font.capHeight / 2
        let scale = window?.backingScaleFactor ?? 2
        speed.frame.origin.y = ((baseline - (height - speed.firstBaselineOffsetFromTop)) * scale).rounded() / scale
    }

    private func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (layer, ink) in pixels {
            let color: NSColor
            switch ink {
            case .rgb(let value):
                color = NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
            case .foreground: color = ShellStyle.secondaryText
            case .faint: color = ShellStyle.secondaryText.withAlphaComponent(0.18)
            }
            layer.backgroundColor = color.shellResolvedCGColor(for: effectiveAppearance)
        }
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refresh() }
    override func viewDidHide() { super.viewDidHide(); refresh() }
    override func viewDidUnhide() { super.viewDidUnhide(); refresh() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColors() }
}
