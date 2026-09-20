import AppKit
import XCTest
import LighttyCore
@testable import lightty

/// 真实 PaneView 上的任务绑定：终端不再自己持有绑定真值，header 由 `TaskBindings` 的变更派生；
/// 指针走默认的磁盘 adapter，也就是 hook 真正读的那份文件。
@MainActor
final class PaneTaskBindingsTests: XCTestCase {
    private var root: URL!
    private var previous: AppState?
    /// 手动触发的任务目录变更：代替 `PathWatcher` 防抖后的一次目录事件。
    private var fireFolderChange: (() -> Void)?

    override func setUpWithError() throws {
        _ = NSApplication.shared
        ensureTerminalRuntime()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pane-bindings-\(UUID().uuidString)", isDirectory: true)
        previous = AppState.shared
        AppState.shared = AppState(taskDirectory: root, sweepStalePanes: false,
                                   taskFolderChanges: { [unowned self] _, onChange in
                                       fireFolderChange = onChange
                                       return NSObject()
                                   })
    }

    override func tearDownWithError() throws {
        AppState.shared = previous ?? AppState.shared
        try? FileManager.default.removeItem(at: root)
    }

    private var bindings: TaskBindings { AppState.shared.taskBindings }

    private func pointer(of pane: PaneView) -> String? {
        let file = PaneRuntimeDirectory.taskPointerFile(for: pane.dragIdentifier.uuidString)
        return (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testRenameShowsTheNewNameInEveryBoundPane() throws {
        let task = try AppState.shared.taskBindings.store.create(name: "Before", workdir: root.path)
        let panes = [PaneView(), PaneView()]
        for pane in panes { pane.bind(to: task.fileURL, name: task.task.name) }
        XCTAssertEqual(panes.map(\.header.titleOfBoundTask), ["Before", "Before"])

        let renamed = try bindings.renameTask(at: task.fileURL, to: "After")
        for pane in panes {
            XCTAssertEqual(pane.header.titleOfBoundTask, "After")
            XCTAssertEqual(pane.boundTask?.name, "After")
            XCTAssertEqual(pane.taskFileURL, renamed)
            XCTAssertEqual(pointer(of: pane), renamed.path)
        }
    }

    /// 用户在编辑器里改了任务文件的 name：终端标题跟上，文件暂时不在则保持原样、不解绑。
    func testAnExternalRenameShowsInEveryBoundPaneAndAVanishedFileStaysBound() throws {
        let store = bindings.store
        let task = try store.create(name: "Before", workdir: root.path)
        let panes = [PaneView(), PaneView()]
        for pane in panes { pane.bind(to: task.fileURL, name: "Before") }

        var edited = task.task
        edited.name = "Edited outside"
        try store.update(at: task.fileURL, task: edited)
        XCTAssertEqual(panes.map(\.header.titleOfBoundTask), ["Before", "Before"], "目录事件到来之前不变")
        try XCTUnwrap(fireFolderChange)()
        for pane in panes {
            XCTAssertEqual(pane.header.titleOfBoundTask, "Edited outside")
            XCTAssertEqual(pane.taskFileURL, task.fileURL)
            XCTAssertEqual(pointer(of: pane), task.fileURL.path)
        }

        try FileManager.default.removeItem(at: task.fileURL)
        try XCTUnwrap(fireFolderChange)()
        for pane in panes {
            XCTAssertEqual(pane.header.titleOfBoundTask, "Edited outside")
            XCTAssertEqual(pane.taskFileURL, task.fileURL)
        }
    }

    func testArchiveAndDeleteUnbindEveryPane() throws {
        let archived = try AppState.shared.taskBindings.store.create(name: "Archived", workdir: root.path)
        let deleted = try AppState.shared.taskBindings.store.create(name: "Deleted", workdir: root.path)
        let archivedPanes = [PaneView(), PaneView()]
        let deletedPanes = [PaneView(), PaneView()]
        for pane in archivedPanes { pane.bind(to: archived.fileURL, name: "Archived") }
        for pane in deletedPanes { pane.bind(to: deleted.fileURL, name: "Deleted") }
        XCTAssertEqual(archivedPanes.map(\.header.dot), [.active, .active])

        try bindings.archiveTask(at: archived.fileURL)
        for pane in archivedPanes {
            XCTAssertNil(pane.taskFileURL)
            XCTAssertNil(pane.header.titleOfBoundTask)
            XCTAssertEqual(pane.header.dot, .unnamed)
            XCTAssertNil(pointer(of: pane))
        }
        XCTAssertEqual(deletedPanes.map(\.taskFileURL), [deleted.fileURL, deleted.fileURL])

        // 删除换一个不碰真实废纸篓的 store：只看解绑是否传导到每个终端。
        let fixture = TaskBindings(store: TaskStore(directory: root, trash: { try FileManager.default.removeItem(at: $0) }))
        let isolated = [PaneView(taskBindings: fixture), PaneView(taskBindings: fixture)]
        for pane in isolated { pane.bind(to: deleted.fileURL, name: "Deleted") }
        try fixture.deleteTask(at: deleted.fileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: deleted.fileURL.path))
        for pane in isolated {
            XCTAssertNil(pane.taskFileURL)
            XCTAssertNil(pane.header.titleOfBoundTask)
            XCTAssertNil(pointer(of: pane))
        }
    }

    func testReleasingABoundPaneClosesTheTask() throws {
        let task = try AppState.shared.taskBindings.store.create(name: "Closing", workdir: root.path)
        autoreleasepool {
            let pane = PaneView()
            pane.bind(to: task.fileURL, name: "Closing")
            XCTAssertTrue(bindings.isOpen(task.fileURL))
        }
        XCTAssertFalse(bindings.isOpen(task.fileURL), "终端释放后任务不再算已打开")
    }
}
