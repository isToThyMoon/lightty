import AppKit
import XCTest
@testable import lightty

@MainActor
final class PaneHeaderViewTests: XCTestCase {
    func testHeaderHasNoManualHandoffControls() {
        _ = NSApplication.shared
        if GhosttyRuntime.shared == nil {
            GhosttyRuntime.shared = GhosttyRuntime()
        }

        let header = PaneHeaderView()
        let manualControls = header.subviews.compactMap { $0 as? ShellTextButton }

        XCTAssertTrue(
            manualControls.isEmpty,
            "handoff 由 hook 自动注入，pane header 不应再显示 Restore/Handoff 按钮")
    }

    func testIdentityCapsuleIsCenteredWithinPaneHeader() {
        _ = NSApplication.shared
        if GhosttyRuntime.shared == nil {
            GhosttyRuntime.shared = GhosttyRuntime()
        }

        let header = PaneHeaderView()
        header.title = "Terminal 12"
        header.frame = NSRect(x: 0, y: 0, width: 420, height: PaneHeaderView.height)
        header.layoutSubtreeIfNeeded()

        XCTAssertEqual(header.capsuleFrame.midX, header.bounds.midX, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(header.capsuleFrame.minX, 4)
        XCTAssertLessThanOrEqual(header.capsuleFrame.maxX, header.bounds.maxX - 4)
    }
}
