import AppKit
import XCTest
import LighttyCore
@testable import lightty

/// Handoff 列表原来每次任务变更都全量 `reloadData()`，并且顺手把选中打回第 0 行——
/// 用户正看着的那一条会被抢走。现在跟会话侧栏同一个形状：稳定标识决定增删，
/// 行值决定要不要重配，选中跟着那一行走。
@MainActor
final class HandoffSidebarReloadTests: XCTestCase {
    // `HandoffSidebarContent.reload()` 是同步重算，目录变更到列表也不合流：不需要转事件循环。

    /// 手动触发的任务目录变更：代替 `PathWatcher` 防抖后的一次目录事件。
    private var fireFolderChange: (() -> Void)?

    /// 先把 AppState 立起来（任务要经它的 store 建），再造视图。
    private func makeStore(_ directory: URL) -> TaskStore {
        _ = NSApplication.shared
        AppState.shared = AppState(taskDirectory: directory, sweepStalePanes: false,
                                   taskFolderChanges: { [unowned self] _, onChange in
                                       fireFolderChange = onChange
                                       return NSObject()
                                   })
        return AppState.shared.taskBindings.store
    }

    /// 每行的任务名：单元格里第一个文本框是标题。
    private func names(in table: NSTableView) -> [String] {
        (0..<table.numberOfRows).compactMap { row in
            table.view(atColumn: 0, row: row, makeIfNecessary: true)?.subviews
                .compactMap { $0 as? NSTextField }.first?.stringValue
        }
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

    /// 第一侧栏行尾同样不为隐藏的 ⋯ 留白：长名字平时越过按钮位；行 hover 时 ⋯ 浮上来、
    /// 名字只被渐隐遮住不重排；移开后遮罩撤掉。Sessions 行走同一套 `onRevealChange` + 遮罩。
    func testRowTextReachesTheRowEndAndFadesUnderTheRevealedAction() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory)
        let name = String(repeating: "搜索结果页商卡 title 对齐", count: 4)
        _ = try store.create(name: name, workdir: directory.path)
        let (_, table) = try makeContent(directory)
        let rowView = try XCTUnwrap(table.rowView(atRow: 0, makeIfNecessary: true) as? ShellTableRowView)
        let cell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let button = try XCTUnwrap((cell as? SidebarRowActionContent)?.rowActionButton)
        let title = try XCTUnwrap(cell.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == name })
        cell.layoutSubtreeIfNeeded()

        XCTAssertFalse(button.isRevealed)
        let resting = title.frame
        XCTAssertGreaterThan(resting.maxX, button.frame.minX, "名字越过隐藏的 ⋯ 位、铺到行尾")
        XCTAssertNotNil(title.layer)
        XCTAssertNil(title.layer?.mask)

        rowView.setSidebarHovered(true)
        cell.layoutSubtreeIfNeeded()
        XCTAssertTrue(button.isRevealed)
        XCTAssertEqual(title.frame, resting, "hover 不重排文字")
        let mask = try XCTUnwrap(title.layer?.mask as? CAGradientLayer, "⋯ 下的文字要遮住")
        let clearFrom = try XCTUnwrap(mask.locations?[2]).doubleValue * cell.bounds.width
        XCTAssertEqual(clearFrom, button.frame.minX, accuracy: 0.5, "⋯ 左缘起文字完全透明")

        rowView.setSidebarHovered(false)
        cell.layoutSubtreeIfNeeded()
        XCTAssertNil(title.layer?.mask, "移开后撤掉遮罩")
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
        XCTAssertEqual(table.selectedRow, 2, "选中不该被打回第一行")

        // 选中那一行整行被删掉：不干预，表格自己落到相邻行——
        // 关键是**不能一律打回第一行**（那是原来的做法）。
        let third = try XCTUnwrap(store.list().tasks.first { $0.task.name == "第三个任务" })
        try FileManager.default.removeItem(at: third.fileURL)
        content.reload()
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
        table.layoutSubtreeIfNeeded()
        XCTAssertTrue(table.view(atColumn: 0, row: 0, makeIfNecessary: false) === first,
                      "内容没变的行不该被重建")
    }

    /// Agent 按交接协议直接写任务文件，lightty 不经手：列表靠目录变更跟上，
    /// 不再靠开关标签页之类的窗口结构广播「顺带」重读。
    func testTheListFollowsTaskFilesWrittenOutsideLightty() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory)
        let first = try store.create(name: "Agent 之前", workdir: directory.path)
        let (_, table) = try makeContent(directory)
        XCTAssertEqual(names(in: table), ["Agent 之前"])

        var edited = first.task
        edited.name = "Agent 改过"
        try store.update(at: first.fileURL, task: edited)
        _ = try store.create(name: "Agent 新建", workdir: directory.path)
        NotificationCenter.default.post(name: .lighttyWindowArrangementDidChange, object: nil)
        XCTAssertEqual(names(in: table), ["Agent 之前"], "窗口结构变化不再顺带重读任务目录")

        try XCTUnwrap(fireFolderChange)()
        XCTAssertEqual(Set(names(in: table)), ["Agent 改过", "Agent 新建"])
    }

    /// 设置里恢复归档任务：Handoff 设置页自己立刻重读，侧栏的 Handoff 列表经目录变更跟上。
    func testRestoringAnArchivedTaskReachesTheListThroughTheFolderChange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory)
        let task = try store.create(name: "归档过的", workdir: directory.path)
        try AppState.shared.taskBindings.archiveTask(at: task.fileURL)
        let (_, table) = try makeContent(directory)
        XCTAssertEqual(names(in: table), [])

        // 不按 object 过滤，壳层要是自己再发一条也数得到；只排除别的测试留下的 TaskBindings。
        let bindings = ObjectIdentifier(AppState.shared.taskBindings)
        var posted = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .lighttyTasksDidChange, object: nil, queue: nil) { note in
            guard let sender = note.object as? TaskBindings else { posted += 1; return }
            if ObjectIdentifier(sender) == bindings { posted += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let settings = HandoffSettingsView(
            bindings: AppState.shared.taskBindings,
            preferences: FilePreferences(fileURL: directory.appendingPathComponent("settings.json")))
        settings.select(.archived)
        XCTAssertEqual(settings.listIDs.count, 1)
        settings.selectList(id: settings.listIDs.first)
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let restore = try XCTUnwrap(descendants(settings).compactMap { $0 as? NSButton }
            .first { $0.title == L("Restore") })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(restore.action), to: restore.target, from: restore))
        XCTAssertTrue(settings.listIDs.isEmpty, "设置页自己同步重读，不等目录事件")
        XCTAssertEqual(posted, 0, "任务列表变化只由 TaskBindings 发出")

        try XCTUnwrap(fireFolderChange)()
        XCTAssertEqual(posted, 1)
        XCTAssertEqual(names(in: table), ["归档过的"])
    }
}
