import AppKit

/// One application-wide route for native text editing, including system dialogs
/// and newly added fields. Ghostty surfaces are not NSTextViews and pass through.
final class TextEditingShortcuts {
    private var monitor: Any?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            Self.handle(event) ? nil : event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    static func handle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              let editor = event.window?.firstResponder as? NSTextView,
              editor.isSelectable else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        // Borderless panels need an explicit route for the standard line motions.
        if modifiers == .control {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a", "\u{1}": editor.moveToBeginningOfLine(nil)
            case "e", "\u{5}": editor.moveToEndOfLine(nil)
            default: return false
            }
            return true
        }
        guard modifiers == .command || modifiers == [.command, .shift] else { return false }
        switch (event.charactersIgnoringModifiers?.lowercased(), modifiers.contains(.shift)) {
        case ("a", false): editor.selectAll(nil)
        case ("c", false): editor.copy(nil)
        case ("x", false) where editor.isEditable: editor.cut(nil)
        case ("v", false) where editor.isEditable: editor.paste(nil)
        case ("z", false) where editor.isEditable: editor.undoManager?.undo()
        case ("z", true) where editor.isEditable: editor.undoManager?.redo()
        default: return false
        }
        return true
    }
}
