import AppKit
import GhosttyKit

/// Ghostty core `start_search` 动作的 AppKit 宿主视图。
/// 搜索命令仍通过 `ghostty_surface_binding_action` 返回 core；这里不定义键位。
final class TerminalSearchBar: NSView, NSSearchFieldDelegate {
    var onNeedleChange: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?
    weak var terminal: TerminalSurfaceView?

    private let searchField = NSSearchField()
    private let resultLabel = NSTextField(labelWithString: "")
    private var debounceWorkItem: DispatchWorkItem?

    init(needle: String?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        applyAppearanceColors()
        shadow = NSShadow()
        shadow?.shadowBlurRadius = 8
        shadow?.shadowOffset = NSSize(width: 0, height: -2)
        shadow?.shadowColor = NSColor.black.withAlphaComponent(0.12)

        let persisted = NSPasteboard(name: .find).string(forType: .string)
        searchField.stringValue = needle?.isEmpty == false ? needle! : (persisted ?? "")
        searchField.placeholderString = "Search"
        searchField.delegate = self
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 13)

        resultLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        resultLabel.textColor = ShellStyle.secondaryText
        resultLabel.alignment = .right

        let previous = makeButton(symbol: "chevron.down", action: #selector(previousResult))
        let next = makeButton(symbol: "chevron.up", action: #selector(nextResult))
        let close = makeButton(symbol: "xmark", action: #selector(closeSearch))

        for view in [searchField, resultLabel, previous, next, close] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 190),

            resultLabel.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 4),
            resultLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            resultLabel.widthAnchor.constraint(equalToConstant: 48),

            previous.leadingAnchor.constraint(equalTo: resultLabel.trailingAnchor, constant: 2),
            previous.centerYAnchor.constraint(equalTo: centerYAnchor),
            previous.widthAnchor.constraint(equalToConstant: 26),
            previous.heightAnchor.constraint(equalToConstant: 26),

            next.leadingAnchor.constraint(equalTo: previous.trailingAnchor, constant: 1),
            next.centerYAnchor.constraint(equalTo: centerYAnchor),
            next.widthAnchor.constraint(equalToConstant: 26),
            next.heightAnchor.constraint(equalToConstant: 26),

            close.leadingAnchor.constraint(equalTo: next.trailingAnchor, constant: 1),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 26),
            close.heightAnchor.constraint(equalToConstant: 26),

            heightAnchor.constraint(equalToConstant: 42),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyAppearanceColors() {
        layer?.backgroundColor =
            ShellStyle.titlebarBackground.shellResolvedCGColor(for: effectiveAppearance)
        layer?.borderColor =
            ShellStyle.divider.shellResolvedCGColor(for: effectiveAppearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
    }

    deinit { debounceWorkItem?.cancel() }

    private func makeButton(symbol: String, action: Selector) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!,
            target: self,
            action: action)
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = ShellStyle.secondaryText
        return button
    }

    func focus() {
        window?.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectedRange = NSRange(
            location: 0,
            length: searchField.stringValue.utf16.count)
        needleDidChange(searchField.stringValue)
    }

    func setNeedle(_ needle: String) {
        searchField.stringValue = needle
        focus()
    }

    func update(selected: Int?, total: Int?) {
        if let selected {
            resultLabel.stringValue = "\(selected + 1)/\(total.map(String.init) ?? "?")"
        } else if let total {
            resultLabel.stringValue = "-/\(total)"
        } else {
            resultLabel.stringValue = ""
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        let needle = searchField.stringValue
        NSPasteboard(name: .find).clearContents()
        NSPasteboard(name: .find).setString(needle, forType: .string)
        needleDidChange(needle)
    }

    private func needleDidChange(_ needle: String) {
        debounceWorkItem?.cancel()
        if needle.isEmpty || needle.count >= 3 {
            onNeedleChange?(needle)
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.onNeedleChange?(needle) }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                onPrevious?()
            } else {
                onNext?()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }

    /// 文本编辑器未消费的 key-equivalent 继续交给 core keybind 表。
    /// 因此搜索框聚焦时的用户自定义 binding 也不需 lightty 复制。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        terminal?.routeKeyEquivalentFromShell(event) ?? false
    }

    @objc private func previousResult() { onPrevious?() }
    @objc private func nextResult() { onNext?() }
    @objc private func closeSearch() { onClose?() }
}
