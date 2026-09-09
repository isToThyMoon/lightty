import AppKit
import XCTest
@testable import lightty

@MainActor
final class TextEditingShortcutTests: XCTestCase {
    func testOrdinaryFieldsAndSearchFields() throws {
        _ = NSApplication.shared
        for field in [NSTextField(), NSSearchField()] as [NSTextField] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
                                  styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            field.frame = NSRect(x: 10, y: 10, width: 240, height: 24)
            field.stringValue = "中文 title"
            window.contentView?.addSubview(field)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(field)
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.setSelectedRange(NSRange(location: 2, length: 0))
            XCTAssertTrue(TextEditingShortcuts.handle(try event("a", .command, window)))
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 8))
            XCTAssertTrue(TextEditingShortcuts.handle(try event("a", .control, window)))
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0))
            XCTAssertTrue(TextEditingShortcuts.handle(try event("e", .control, window)))
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 8, length: 0))
            XCTAssertFalse(TextEditingShortcuts.handle(try event("a", [.command, .option], window)))
            window.makeFirstResponder(nil)
            XCTAssertFalse(TextEditingShortcuts.handle(try event("a", .command, window)),
                           "An unfocused field must leave terminal shortcuts alone")
        }
    }

    func testTerminalSearchHandlesEditingBeforeForwardingToCore() throws {
        _ = NSApplication.shared
        let bar = TerminalSearchBar(needle: "find me")
        bar.frame = NSRect(x: 0, y: 0, width: 360, height: 40)
        let window = PaneIdentityWindow(content: bar)
        defer { window.orderOut(nil) }
        window.makeKeyAndOrderFront(nil)
        bar.focus()
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertTrue(TextEditingShortcuts.handle(try event("a", .command, window)))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 7))
        XCTAssertTrue(TextEditingShortcuts.handle(try event("a", .control, window)))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertTrue(TextEditingShortcuts.handle(try event("e", .control, window)))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 7, length: 0))
    }

    func testPlainTextViewNeedsNoCustomFieldClass() throws {
        _ = NSApplication.shared
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        editor.string = "ordinary editor"
        let window = PaneIdentityWindow(content: editor)
        defer { window.orderOut(nil) }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        XCTAssertTrue(TextEditingShortcuts.handle(try event("a", .command, window)))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 15))
        editor.isEditable = false
        XCTAssertFalse(TextEditingShortcuts.handle(try event("x", .command, window)))
        XCTAssertFalse(TextEditingShortcuts.handle(try event("v", .command, window)))
        XCTAssertFalse(TextEditingShortcuts.handle(try event("k", .command, window)))
        XCTAssertEqual(editor.string, "ordinary editor")
    }

    private func event(_ text: String, _ flags: NSEvent.ModifierFlags, _ window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: text == "e" ? 14 : 0))
    }

    func testIdentityFieldEditingShortcuts() throws {
        _ = NSApplication.shared
        let shortcuts = TextEditingShortcuts()
        defer { withExtendedLifetime(shortcuts) {} }
        let panel = PaneIdentityPanel()
        panel.frame = NSRect(x: 0, y: 0, width: 272, height: 400)
        panel.update(paneName: "下单归因治理", taskName: "Task", dot: .gray, agent: nil)
        let window = PaneIdentityWindow(content: panel)
        defer { window.orderOut(nil) }
        window.makeKeyAndOrderFront(nil)
        panel.focusInitialField()
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        let length = (editor.string as NSString).length
        XCTAssertGreaterThan(length, 0)
        editor.setSelectedRange(NSRange(location: length, length: 0))
        func key(_ character: String, _ flags: NSEvent.ModifierFlags, _ code: UInt16) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: code))
        }
        let selectAll = try key("a", .command, 0)
        NSApp.sendEvent(selectAll)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: length), "Cmd+A")
        editor.setSelectedRange(NSRange(location: length, length: 0))
        let home = try key("\u{1}", .control, 0)
        NSApp.sendEvent(home)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0), "Ctrl+A")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        let end = try key("\u{5}", .control, 14)
        NSApp.sendEvent(end)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: length, length: 0), "Ctrl+E")
    }
}
