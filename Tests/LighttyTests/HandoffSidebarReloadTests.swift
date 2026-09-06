import AppKit
import XCTest
import LighttyCore
@testable import lightty

/// Handoff 列表原来每次任务变更都全量 `reloadData()`，并且顺手把选中打回第 0 行——
/// 用户正看着的那一条会被抢走。现在跟会话侧栏同一个形状：稳定标识决定增删，
/// 行值决定要不要重配，选中跟着那一行走。
@MainActor
final class HandoffSidebarReloadTests: XCTestCase {
    private func pump(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// 先把 AppState 立起来（任务要经它的 store 建），再造视图。
    private func makeStore(_ directory: URL) -> TaskStore {
        _ = NSApplication.shared
        AppState.shared = AppState(taskDirectory: directory, sweepStalePanes: false)
        return AppState.shared.taskStore
    }

    private func makeContent(_ directory: URL) throws -> (HandoffSidebarContent, NSTableView) {
        let content = HandoffSidebarContent()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = content
        content.reload()
        content.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let table = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first)
        return (content, table)
    }

    func testSelectionSurvivesATaskChangeInsteadOfSnappingBackToTheFirstRow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory)
        for name in ["第一个任务", "第二个任务", "第三个任务"] {
            _ = try store.create(name: name, workdir: directory.path)
        }
        let (content, table) = try makeContent(directory)
        XCTAssertEqual(table.numberOfRows, 3)

        // 用户选中了第三行。
        table.selectRowIndexes([2], byExtendingSelection: false)
        let chosen = table.selectedRow
        XCTAssertEqual(chosen, 2)

        // 任务发生变更（另一个任务改名），列表重算。
        content.reload()
        pump()
        XCTAssertEqual(table.selectedRow, 2, "选中不该被打回第一行")

        // 选中那一行整行被删掉：不干预，表格自己落到相邻行——
        // 关键是**不能一律打回第一行**（那是原来的做法）。
        let third = try XCTUnwrap(store.list().tasks.first { $0.task.name == "第三个任务" })
        try FileManager.default.removeItem(at: third.fileURL)
        content.reload()
        pump()
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertNotEqual(table.selectedRow, 0, "删掉选中行不该把选中打回第一行")
    }

    /// 单元格现在走复用。同一批内容重复重算时，行视图必须是同一批对象——
    /// 否则悬停、tracking area 每次任务变更都要重来一遍。
    func testUnchangedRowsKeepTheirCellsAcrossReloads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory)
        for name in ["甲", "乙"] {
            _ = try store.create(name: name, workdir: directory.path)
        }
        let (content, table) = try makeContent(directory)
        table.layoutSubtreeIfNeeded()
        let first = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        content.reload()
        pump()
        table.layoutSubtreeIfNeeded()
        XCTAssertTrue(table.view(atColumn: 0, row: 0, makeIfNecessary: false) === first,
                      "内容没变的行不该被重建")
    }
}
