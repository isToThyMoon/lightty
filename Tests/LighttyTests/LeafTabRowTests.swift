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
        ensureTerminalRuntime()
        controller = TerminalWindowController()
        column = TabColumnView()
        controller.window!.contentView!.addSubview(column)
        column.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        try controller.waitForInitialLayout()
        table = try XCTUnwrap(descendants(column).compactMap { $0 as? NSTableView }.first)
        layout()
    }

    override func tearDown() {
        controller.window?.close()
        try? FileManager.default.removeItem(at: directory)
    }

    /// 标签页默认名是全局身份：侧栏跳转行直接拿它当位置说明，两个窗口不能各有一个「标签页 1」。
    func testASecondWindowDoesNotRepeatTheFirstWindowsDefaultTabName() throws {
        let other = TerminalWindowController()
        defer { other.window?.close() }
        XCTAssertNotEqual(other.tabOverview().first?.title, controller.tabOverview().first?.title)
    }

    /// 「用户改过名」是存下来的事实，不是拿标题去匹配当前语言的默认名格式反推出来的。
    /// 以前的反推两头都错：切一次语言，默认名全被当成改过名；用户亲手起名「标签页 7」，
    /// 又被当成默认名。这里验后一半——前一半不再有「反推」可言（`TabTitle` 只存序号，
    /// 见 `WindowArrangementTests.testTitleParsingAndSnapshotMigration`）。
    ///
    /// 刻意不在测试里调 `LanguagePreference.set`：它广播全局的语言切换，全量运行时之前
    /// 测试留下的每个窗口都跟着重建，曾稳定地让测试进程卡死在释放终端上。
    func testCustomTitleIsStoredRatherThanInferredFromTheTitleText() throws {
        XCTAssertEqual(controller.tabOverview().first?.hasCustomTitle, false)
        let tabID = try XCTUnwrap(controller.tabOverview().first?.id)
        controller.renameTab(withID: tabID, to: L("Tab %d", 7))
        XCTAssertEqual(controller.tabOverview().first?.hasCustomTitle, true,
                       "用户起的名字恰好长得像默认名，也仍是用户起的名字")
    }

    /// 行尾不为隐藏的 ⋯/✕ 预留空白：长名字平时铺到行尾；hover 时按钮浮上来，
    /// 名字只被渐隐遮住、不重新截断，移开后遮罩撤掉。
    func testRowTextReachesTheRowEndAndFadesUnderHoverActions() throws {
        let pane = try XCTUnwrap(controller.activePane)
        pane.rename(to: String(repeating: "搜索结果页商卡 title 对齐 ", count: 4))
        layout()
        let rowView = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: false))
        let row = try XCTUnwrap(([rowView] + descendants(rowView)).first { $0 is SidebarHoverRow })
        let name = try XCTUnwrap(descendants(row).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == pane.sessionState.title })
        row.layoutSubtreeIfNeeded()
        let restingFrame = name.frame
        let slotMinX = try XCTUnwrap(descendants(row).compactMap { $0 as? NSButton }
            .filter { $0.frame.width > 0 }.map(\.frame.minX).min())
        XCTAssertGreaterThan(restingFrame.maxX, slotMinX, "名字越过隐藏的按钮位、铺到行尾")
        XCTAssertNotNil(name.layer)
        XCTAssertNil(name.layer?.mask)

        (row as? SidebarHoverRow)?.setSidebarHovered(true)
        row.layoutSubtreeIfNeeded()
        XCTAssertEqual(name.frame, restingFrame, "hover 不重排文字")
        let buttons = descendants(row).compactMap { $0 as? NSButton }.filter { !$0.isHidden }
        XCTAssertFalse(buttons.isEmpty)
        let actionsMinX = try XCTUnwrap(buttons.map(\.frame.minX).min())
        let mask = try XCTUnwrap(name.layer?.mask as? CAGradientLayer, "按钮下的文字要遮住")
        let clearFrom = try XCTUnwrap(mask.locations?[2]).doubleValue * row.bounds.width
        XCTAssertLessThanOrEqual(clearFrom, actionsMinX + 0.5, "按钮左缘起文字完全透明")

        (row as? SidebarHoverRow)?.setSidebarHovered(false)
        row.layoutSubtreeIfNeeded()
        XCTAssertNil(name.layer?.mask, "移开后撤掉遮罩")
    }

    /// 没进 agent 的终端，行里固定的图标位放提示符「>」补位，不留一格空白。
    func testAPaneWithoutAnAgentShowsThePromptGlyph() throws {
        let pane = try XCTUnwrap(controller.activePane)
        XCTAssertNil(pane.sessionState.displayAgent)
        let prompt = try XCTUnwrap(AgentSessionIcon.terminalPrompt, "提示符字形随包打进资源")
        XCTAssertTrue(prompt.isTemplate)
        let rowView = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: false))
        let icons = ([rowView] + descendants(rowView)).compactMap { $0 as? NSImageView }
        XCTAssertTrue(icons.contains { $0.image === prompt && !$0.isHidden }, "\(icons.map(\.image))")
    }

    func testSinglePaneTabShowsPaneTitleWithoutContainerRow() throws {
        let pane = try XCTUnwrap(controller.activePane)
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertTrue(labels().contains(pane.sessionState.title), "\(labels())")
        XCTAssertFalse(labels().contains(L("Tab %d", 1)), "默认标签页名不该出现：\(labels())")
        XCTAssertFalse(labels().contains("1"), "计数 1 是空信息，不该出现")
    }

    func testRenamedTabGetsItsContainerRowBack() throws {
        let pane = try XCTUnwrap(controller.activePane)
        controller.renameTab(at: 0, to: "深夜改稿")
        layout()
        // 用户起了名字的标签页有自己的身份：容器行 + pane 行，名字一直看得见。
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertTrue(labels().contains("深夜改稿"), "\(labels())")
        XCTAssertTrue(labels().contains(pane.sessionState.title), "\(labels())")
    }

    /// 容器行当且仅当分屏：分屏展开成容器 + pane 行，别的标签页不受牵连，关掉分屏又收回。
    func testSplittingExpandsIntoContainerAndPaneRows() throws {
        let pane = try XCTUnwrap(controller.activePane)
        controller.split(pane, direction: .down)
        let extra = try XCTUnwrap(controller.panes().first { $0 !== pane })
        layout()
        XCTAssertEqual(table.numberOfRows, 3)
        XCTAssertTrue(labels().contains(L("Tab %d", 1)), "多 pane 标签页要有容器行：\(labels())")
        XCTAssertTrue(labels().contains("2"), "容器行显示 pane 计数")

        // 再开一个单 pane 标签页：标签页 1 仍是容器 + 2 pane，标签页 2 压成叶子行。
        controller.addTab(initialPane: PaneView())
        layout()
        XCTAssertEqual(table.numberOfRows, 4)
        XCTAssertTrue(labels().contains(L("Tab %d", 1)))
        XCTAssertFalse(labels().contains(L("Tab %d", 2)), "没分屏的标签页不该有容器行：\(labels())")

        // 关掉一个分屏又收回成叶子行：两个标签页各一行。
        controller.close(pane: extra)
        layout()
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertFalse(labels().contains(L("Tab %d", 1)))
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
