import AppKit
import XCTest
@testable import lightty

/// 单 pane 标签页在第二侧栏里压成一条叶子行；分屏后才展开成两级树。
@MainActor
final class LeafTabRowTests: XCTestCase {
    private var directory: URL!
    private var controller: TerminalWindowController!
    private var column: TabColumnView!
    private var table: NSTableView!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        _ = NSApplication.shared
        AppState.shared = AppState(taskDirectory: directory, sweepStalePanes: false)
        if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }
        controller = TerminalWindowController()
        column = TabColumnView()
        controller.window!.contentView!.addSubview(column)
        column.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        table = try XCTUnwrap(descendants(column).compactMap { $0 as? NSTableView }.first)
        layout()
    }

    override func tearDown() {
        controller.window?.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func testDefaultTitleDetection() {
        XCTAssertEqual(TerminalTab.defaultTitleNumber(L("Tab %d", 7)), 7)
        XCTAssertNil(TerminalTab.defaultTitleNumber("skills"))
        XCTAssertNil(TerminalTab.defaultTitleNumber(""))
    }

    func testSinglePaneTabShowsPaneTitleWithoutContainerRow() throws {
        let pane = try XCTUnwrap(controller.activePane)
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertTrue(labels().contains(pane.sessionState.title), "\(labels())")
        XCTAssertFalse(labels().contains(L("Tab %d", 1)), "默认标签页名不该出现：\(labels())")
        XCTAssertFalse(labels().contains("1"), "计数 1 是空信息，不该出现")
    }

    func testRenamedTabUsesItsOwnNameOnTheLeafRow() throws {
        let pane = try XCTUnwrap(controller.activePane)
        controller.renameTab(at: 0, to: "深夜改稿")
        layout()
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertTrue(labels().contains("深夜改稿"), "\(labels())")
        XCTAssertFalse(labels().contains(pane.sessionState.title), "pane 名让位给用户起的标签页名")
    }

    func testSplittingExpandsIntoContainerAndPaneRows() throws {
        let pane = try XCTUnwrap(controller.activePane)
        controller.split(pane, direction: .down)
        layout()
        XCTAssertEqual(table.numberOfRows, 3)
        XCTAssertTrue(labels().contains(L("Tab %d", 1)), "多 pane 标签页要有容器行：\(labels())")
        XCTAssertTrue(labels().contains("2"), "容器行显示 pane 计数")

        // 关掉一个分屏又收回成叶子行。
        let extra = try XCTUnwrap(controller.panes().first { $0 !== pane })
        controller.close(pane: extra)
        layout()
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertFalse(labels().contains(L("Tab %d", 1)))
    }

    func testMixedTabsKeepContainerRowsOnlyWhereSplit() throws {
        let first = try XCTUnwrap(controller.activePane)
        controller.split(first, direction: .right)
        controller.addTab(initialPane: PaneView())
        layout()
        // 标签页 1：容器 + 2 pane；标签页 2：叶子。
        XCTAssertEqual(table.numberOfRows, 4)
        XCTAssertTrue(labels().contains(L("Tab %d", 1)))
        XCTAssertFalse(labels().contains(L("Tab %d", 2)))
    }

    // MARK: - helpers

    private func layout() {
        column.reload()
        column.layoutSubtreeIfNeeded()
        table.layoutSubtreeIfNeeded()
    }

    private func labels() -> [String] {
        descendants(table).compactMap { ($0 as? NSTextField)?.stringValue }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
