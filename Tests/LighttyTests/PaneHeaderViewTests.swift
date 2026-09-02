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
}
