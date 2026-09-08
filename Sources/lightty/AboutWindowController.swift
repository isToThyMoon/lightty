import AppKit

/// A small, reusable window. Opening About never creates a terminal or touches preferences.
final class AboutWindowController: NSWindowController {
    static let greeting = "Thank you for finding lightty."
    static let message = "This is my first Swift app.\nIt will always be free and open source.\nI hope it makes your everyday work a little easier."

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 390),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = ShellStyle.sidebarBackground
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        guard let window else { return }
        // Refresh localized copy on opening, including after a language change in Settings.
        window.title = L("About lightty")
        window.contentView = makeContent()
        if !window.isVisible { window.center() }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func makeContent() -> NSView {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 390))
        let icon = NSImageView()
        icon.image = AppBranding.icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityLabel("lightty")
        let title = label("lightty", size: 26, weight: .semibold)
        let version = label(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            .map { String(describing: $0) } ?? L("Development build"), size: 11, color: ShellStyle.secondaryText)
        let greeting = label(L(Self.greeting), size: 16, weight: .medium)
        let message = label(L(Self.message), size: 13, color: ShellStyle.secondaryText)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 6
        message.attributedStringValue = NSAttributedString(string: L(Self.message), attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: ShellStyle.secondaryText,
            .paragraphStyle: paragraph,
        ])
        let stack = NSStackView(views: [icon, title, version, greeting, message])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(24, after: version)
        stack.setCustomSpacing(12, after: greeting)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 100),
            icon.heightAnchor.constraint(equalToConstant: 100),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 38),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.widthAnchor.constraint(equalToConstant: 356),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -30),
        ])
        return content
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                       color: NSColor = ShellStyle.primaryText) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.alignment = .center
        label.isSelectable = false
        return label
    }
}
