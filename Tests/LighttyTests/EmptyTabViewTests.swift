import AppKit
import Testing
@testable import lightty

@MainActor
struct EmptyTabViewTests {
    @Test func subtitleStaysOnOneLine() throws {
        _ = NSApplication.shared
        if GhosttyRuntime.shared == nil {
            GhosttyRuntime.shared = GhosttyRuntime()
        }

        let view = EmptyTabView()
        view.frame = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        view.layoutSubtreeIfNeeded()

        let subtitle = try #require(descendants(of: view)
            .compactMap { $0 as? NSTextField }
            .first { $0.stringValue == L("Open a task from the sidebar, or create a new tab.") })
        #expect(subtitle.maximumNumberOfLines == 1)
        #expect(subtitle.cell?.wraps == false)
        #expect(subtitle.frame.width >= subtitle.attributedStringValue.size().width)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
