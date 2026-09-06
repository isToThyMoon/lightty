import AppKit
import Testing
@testable import lightty

@MainActor
@Test func aboutWindowLoadsBrandIconAndFitsCopy() throws {
    _ = NSApplication.shared
    let controller = AboutWindowController()
    let window = try #require(controller.window)
    defer { window.close() }
    #expect(AppBranding.icon?.isValid == true)
    let content = controller.makeContent()
    window.contentView = content
    content.layoutSubtreeIfNeeded()
    let stack = try #require(content.subviews.first as? NSStackView)
    let message = try #require(stack.arrangedSubviews.last as? NSTextField)
    #expect(message.stringValue == L(AboutWindowController.message))
    #expect(message.frame.height >= message.fittingSize.height)
    #expect(stack.frame.minY >= 30)
    #expect(stack.frame.maxY <= content.bounds.maxY)
    #expect(window.styleMask.contains(.closable))
    #expect(!window.styleMask.contains(.resizable))
}
