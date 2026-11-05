import AppKit
import XCTest
import LighttyCore
@testable import lightty

/// Handoff 协议规定 Agent 直接写任务文件，所以外部写入要经目录事件走到侧栏列表。
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
}
