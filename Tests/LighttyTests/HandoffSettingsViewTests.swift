import AppKit
import LighttyCore
import Testing
@testable import lightty

/// Handoff 设置页：一页里把「进行中」「已归档」「协议」三段合起来。
///
/// 全部走临时目录：用户真正的 `~/.lightty/tasks/` 是他自己的交接文档，测试一个字
/// 都不能碰。`TaskBindings` 也用私有的 NotificationCenter 和空的目录监听立起来，
/// 免得这一页的归档动作惊动别的测试里还活着的任务列表。
@Suite(.serialized)
@MainActor
struct HandoffSettingsViewTests {
    /// 归档、恢复、永久删除三个动作都落到磁盘上，并且当场重读两栏。
    @Test func archiveRestoreAndPermanentDeleteReachDiskAndReloadBothLists() throws {
        let (view, store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let created = try store.create(name: "改写启动浮层", workdir: root.path)
        view.reload()

        try click(L("Archive task"), in: view)
        #expect(view.listedNames.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: created.fileURL.path))
        #expect(try store.archivedFiles().count == 1)
        #expect(counts(in: view) == [0, 1])


        view.select(.archived)
        #expect(view.listedNames == ["改写启动浮层"])
        try click(L("Restore"), in: view)
        #expect(view.listedNames.isEmpty)
        #expect(store.list().tasks.map { $0.task.name } == ["改写启动浮层"])
        #expect(counts(in: view) == [1, 0])

        view.select(.inProgress)
        try click(L("Archive task"), in: view)
        view.select(.archived)
        let archived = try #require(try store.archivedFiles().first)
        view.confirmPermanentDelete = { false }
        try click(L("Delete permanently…"), in: view)
        #expect(FileManager.default.fileExists(atPath: archived.path), "取消就是什么都不做")
        view.confirmPermanentDelete = { true }
        try click(L("Delete permanently…"), in: view)
        #expect(!FileManager.default.fileExists(atPath: archived.path))
        #expect(view.listedNames.isEmpty)
        #expect(counts(in: view) == [0, 0])
    }

    // MARK: - 夹具

    private func fixture() throws -> (HandoffSettingsView, TaskStore, URL) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("handoff-view-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = TaskStore(directory: root.appendingPathComponent("tasks"), trash: { _ in })
        let bindings = TaskBindings(store: store, notificationCenter: NotificationCenter(),
                                    folderChanges: { _, _ in NSObject() })
        let view = HandoffSettingsView(
            bindings: bindings,
            preferences: FilePreferences(fileURL: root.appendingPathComponent("layout.json")))
        // 不进窗口：这一页要的只是布局一次好让三栏各就各位，没有需要「在屏幕上」
        // 的语义（成为 key、field editor、按 windowNumber 投递的事件）。
        view.frame = NSRect(x: 0, y: 0, width: 1200, height: 760)
        view.layoutSubtreeIfNeeded()
        return (view, store, root)
    }

    /// 左栏每一行的数量，顺序是「进行中、已归档」；协议行不显示数量。
    private func counts(in view: HandoffSettingsView) -> [Int] {
        view.navigation.filter { $0.showsCount }.map(\.count)
    }

    /// 按详情栏上那个按钮，与用户点它走同一段代码。
    private func click(_ label: String, in view: HandoffSettingsView) throws {
        let button = try #require(descendants(view).compactMap { $0 as? ShellTextButton }
            .first { $0.label == label && !$0.isHiddenOrHasHiddenAncestor })
        #expect(NSApp.sendAction(try #require(button.action), to: button.target, from: button))
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
