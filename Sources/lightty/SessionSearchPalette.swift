import AppKit

/// A window-local search surface; the catalog and resume behavior remain in the session list.
final class SessionSearchPalette: NSView {
    var onDismiss: (() -> Void)?
    private let card = ShellBackdropView(fill: ShellStyle.sidebarBackground)
    private let content: SessionsSidebarContent

    init(library: SessionLibrary) {
        content = SessionsSidebarContent(library: library, searchMode: true)
        super.init(frame: .zero)
        addSubview(card)
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
        ])
        content.onRequestDismiss = { [weak self] in self?.onDismiss?() }
        content.activate()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        SearchPaletteStyle.decorate(card)
    }
    override func layout() {
        super.layout()
        card.frame = SearchPaletteStyle.frame(in: bounds, flipped: isFlipped)
    }
    func focusSearch() { content.focusSearch() }
    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { onDismiss?() }
    }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
}
