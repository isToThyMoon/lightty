import AppKit
import XCTest
@testable import lightty

@MainActor
final class TextEditingShortcutTests: XCTestCase {
    /// 每一种输入框上 Cmd+A / Ctrl+A / Ctrl+E 的选区结果一致；Cmd+Opt+A 不吃；失焦后不吃。
    /// 字段种类只差怎么造出来：普通 NSTextField、NSSearchField、终端搜索条（TerminalSearchBar）。
    func testEditingShortcutsApplyInEveryFieldKind() throws {
        _ = NSApplication.shared
        typealias Focused = (window: NSWindow, editor: NSTextView, length: Int)
        let kinds: [(name: String, focus: () throws -> Focused)] = [
            ("NSTextField", { try self.focusedField(NSTextField()) }),
            ("NSSearchField", { try self.focusedField(NSSearchField()) }),
            // 终端搜索条：编辑快捷键先于转发给 core 处理
            ("TerminalSearchBar", {
                let bar = TerminalSearchBar(needle: "find me")
                bar.frame = NSRect(x: 0, y: 0, width: 360, height: 40)
                let window = PaneIdentityWindow(content: bar)
                window.makeKeyAndOrderFrontInvisibly()
                bar.focus()
                let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
                return (window, editor, 7)
            }),
        ]
        for kind in kinds {
            let (window, editor, length) = try kind.focus()
            defer { window.orderOut(nil) }
            editor.setSelectedRange(NSRange(location: 2, length: 0))
            XCTAssertTrue(TextEditingShortcuts.handle(try event("a", .command, window)), "\(kind.name): Cmd+A")
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: length), "\(kind.name): Cmd+A")
            XCTAssertTrue(TextEditingShortcuts.handle(try event("a", .control, window)), "\(kind.name): Ctrl+A")
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0), "\(kind.name): Ctrl+A")
            XCTAssertTrue(TextEditingShortcuts.handle(try event("e", .control, window)), "\(kind.name): Ctrl+E")
            XCTAssertEqual(editor.selectedRange(), NSRange(location: length, length: 0), "\(kind.name): Ctrl+E")
            XCTAssertFalse(TextEditingShortcuts.handle(try event("a", [.command, .option], window)), "\(kind.name): Cmd+Opt+A")
            window.makeFirstResponder(nil)
            XCTAssertFalse(TextEditingShortcuts.handle(try event("a", .command, window)),
                           "\(kind.name): An unfocused field must leave terminal shortcuts alone")
        }
    }

    private func focusedField(_ field: NSTextField) throws -> (NSWindow, NSTextView, Int) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        field.frame = NSRect(x: 10, y: 10, width: 240, height: 24)
        field.stringValue = "中文 title"
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFrontInvisibly()
        window.makeFirstResponder(field)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        return (window, editor, 8)
    }

    private func event(_ text: String, _ flags: NSEvent.ModifierFlags, _ window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: text == "e" ? 14 : 0))
    }
}
