import AppKit

/// 文件路径默认只占一行；需要排查来源时再展开可选择、可滚动的完整路径。
final class BrowserFileLocationsView: NSView {
    private let disclosure = NSButton(title: "", target: nil, action: nil)
    private let summary = NSTextField(labelWithString: "")
    private let scroll = NSTextView.scrollableTextView()
    var textView: NSTextView { scroll.documentView as! NSTextView }
    var onResize: (() -> Void)?
    var title = "" { didSet { disclosure.title = title; needsLayout = true } }
    private var expanded = false
    var preferredHeight: CGFloat { expanded ? 108 : 24 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.bezelStyle = .recessed
        disclosure.isBordered = false
        disclosure.font = SkillsStyle.summaryFont
        disclosure.imagePosition = .imageLeading
        disclosure.target = self
        disclosure.action = #selector(toggle)
        summary.font = SkillsStyle.summaryFont
        summary.textColor = ShellStyle.tertiaryText
        summary.lineBreakMode = .byTruncatingMiddle
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.isHidden = true
        for view in [disclosure, summary, scroll] { addSubview(view) }
        updateDisclosure()
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func refreshSummary() {
        let first = textView.string.components(separatedBy: "\n").first ?? ""
        summary.stringValue = first.split(separator: "/").suffix(2).joined(separator: "/")
        summary.toolTip = textView.string
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let buttonWidth = min(bounds.width, ceil(disclosure.intrinsicContentSize.width) + 8)
        disclosure.frame = NSRect(x: 0, y: 0, width: buttonWidth, height: 24)
        summary.frame = NSRect(x: buttonWidth + 8, y: 5,
                               width: max(0, bounds.width - buttonWidth - 8), height: 18)
        scroll.frame = NSRect(x: 0, y: 32, width: bounds.width, height: max(0, bounds.height - 32))
    }

    @objc private func toggle() {
        expanded.toggle()
        scroll.isHidden = !expanded
        summary.isHidden = expanded
        updateDisclosure()
        onResize?()
    }

    private func updateDisclosure() {
        disclosure.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right",
                                   accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .medium))
        disclosure.setAccessibilityValue(expanded ? 1 : 0)
    }
}
