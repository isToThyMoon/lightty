import AppKit
import XCTest
@testable import lightty

/// `InvisibleWindowTestSupport` 的回归保护：经它 order 出来的窗口必须不可见，
/// 同时保留测试依赖的 key 语义；生产代码把 alpha 改回 1 也要被钉住。
@MainActor
final class InvisibleWindowTests: XCTestCase {
    func testTitledWindowStaysInvisibleYetHostsAFieldEditor() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 240, height: 24))
        field.stringValue = "abc"
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFrontInvisibly()
        XCTAssertTrue(window.isVisible, "PaneLauncher 靠 isVisible 确认宿主窗口还在")
        XCTAssertEqual(window.alphaValue, 0)
        XCTAssertTrue(window.isPinnedInvisible)
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertNotNil(field.currentEditor() as? NSTextView, "alpha 0 不影响 field editor")

        // 生产代码的显形（如 TerminalWindowController.revealWindowIfNeeded）不能把它露出来。
        window.alphaValue = 1
        XCTAssertEqual(window.alphaValue, 0, "alpha 被钉在 0")
        window.animator().alphaValue = 1
        XCTAssertEqual(window.alphaValue, 0)
    }

    func testIdentityPanelBecomesKeyWithoutShowing() throws {
        _ = NSApplication.shared
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        editor.string = "ordinary editor"
        let window = PaneIdentityWindow(content: editor)
        defer { window.orderOut(nil) }
        window.makeKeyAndOrderFrontInvisibly()
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.alphaValue, 0)
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertTrue(window.firstResponder === editor)
    }

    func testOrderFrontInvisiblyDoesNotRequireKey() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.orderFrontInvisibly()
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.alphaValue, 0)
        window.orderOut(nil)
        window.orderFrontInvisibly()
        XCTAssertEqual(window.alphaValue, 0, "重复 order 仍旧不可见")
    }
}
