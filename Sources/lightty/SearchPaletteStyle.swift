import AppKit

/// Shared chrome for both search modes; only their result data and actions differ.
enum SearchPaletteStyle {
    static func configure(_ field: NSTextField) {
        field.font = .systemFont(ofSize: 15)
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = ShellStyle.primaryText
        (field.cell as? NSTextFieldCell)?.usesSingleLineMode = true
    }

    static func icon() -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        view.contentTintColor = ShellStyle.tertiaryText
        return view
    }

    static func frame(in bounds: NSRect, flipped: Bool) -> NSRect {
        let width = min(bounds.width * ShellStyle.paletteWidthRatio, ShellStyle.paletteMaxWidth)
        let height = min(bounds.height * ShellStyle.paletteHeightRatio, ShellStyle.paletteMaxHeight)
        let top = bounds.height * ShellStyle.paletteTopRatio
        return NSRect(x: (bounds.width - width) / 2,
                      y: flipped ? top : bounds.height - top - height,
                      width: width, height: height).integral
    }

    static func decorate(_ card: NSView) {
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1
        card.layer?.borderColor = ShellStyle.divider.shellResolvedCGColor(for: card.effectiveAppearance)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
        shadow.shadowBlurRadius = 48
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        card.shadow = shadow
    }
}
