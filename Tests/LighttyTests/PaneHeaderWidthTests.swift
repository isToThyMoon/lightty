import AppKit
import XCTest
@testable import lightty

/// pane 身份胶囊不许决定 pane 的宽度。标题由 agent 写，长度不可信；一旦
/// "标题宽度 + 内边距"成了 pane 的最小宽度，同 tab 的兄弟 pane 会被挤扁，
/// 分割线连拖都拖不动（NSSplitView 默认 holding priority 只有 250）。
@MainActor
final class PaneHeaderWidthTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        _ = NSApplication.shared
        if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        AppState.shared = AppState(taskDirectory: directory, sweepStalePanes: false)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    func testANarrowPaneTruncatesTheTitleInsteadOfOverflowing() {
        let header = PaneHeaderView()
        header.title = String(repeating: "很长的标题", count: 40)
        header.frame = NSRect(x: 0, y: 0, width: 260, height: PaneHeaderView.height)
        header.layoutSubtreeIfNeeded()
        let nameLabel = descendants(header).compactMap { $0 as? NSTextField }
            .max { $0.frame.width < $1.frame.width }
        let label = nameLabel!
        XCTAssertLessThan(label.frame.width, label.intrinsicContentSize.width,
                          "窄 pane 里标题要截断，而不是按固有宽度摊开")
        XCTAssertLessThanOrEqual(header.capsuleFrame.maxX, header.bounds.width,
                                 "胶囊不该溢出 pane")
    }

    func testCapsuleStaysWithinItsShareOfThePane() {
        let header = PaneHeaderView()
        header.title = String(repeating: "长标题", count: 30)
        for width in [200.0, 400.0, 900.0] as [CGFloat] {
            header.frame = NSRect(x: 0, y: 0, width: width, height: PaneHeaderView.height)
            header.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(
                header.capsuleFrame.width,
                width * PaneHeaderView.capsuleWidthRatio + 0.5,
                "\(width)pt 宽的 pane 里胶囊越界了")
        }
    }

    func testALongTitleNeitherSqueezesTheSiblingNorJamsTheDivider() throws {
        let controller = TerminalWindowController()
        defer { controller.window?.close() }
        let first = try XCTUnwrap(controller.activePane)
        controller.split(first, direction: .right)
        let container = try XCTUnwrap(first.superview as? PaneLayoutView)
        let host = try XCTUnwrap(controller.window?.contentView)
        host.layoutSubtreeIfNeeded()
        let sibling = try XCTUnwrap(controller.panes().first { $0 !== first })
        let balanced = sibling.frame.width
        XCTAssertGreaterThan(balanced, 0)

        // 标题变长不许动已有的分屏比例。
        first.header.title = String(repeating: "长标题", count: 30)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(sibling.frame.width, balanced, accuracy: 1,
                       "长标题不该把兄弟 pane 挤扁")

        // 分割线要真的动得了：把长标题那侧拖窄，宽度得跟着走。
        let divider = try XCTUnwrap(container.subviews.compactMap { $0 as? PaneDividerView }.first { !$0.isHidden })
        divider.onDrag?(200)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(first.frame.width, 200, accuracy: 1,
                       "长标题的 pane 仍然要能被拖窄")
    }
}
