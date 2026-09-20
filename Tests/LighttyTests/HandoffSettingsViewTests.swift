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
    /// 两栏的内容都是从 store 读出来的，不是构造时塞进去的。
    @Test func theActionRowFitsItsButtonsAndKeepsTheIconLast() throws {
        let (view, store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.create(name: "改写启动浮层", workdir: root.path)
        view.reload()
        view.select(.inProgress)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        let texts = descendants(view).compactMap { $0 as? ShellTextButton }
            .filter { !$0.isHiddenOrHasHiddenAncestor }
        let open = try #require(texts.first { $0.label == L("Open file") })
        let archive = try #require(texts.first { $0.label == L("Archive task") })
        let folder = try #require(descendants(view).compactMap { $0 as? ShellIconButton }
            .first { !$0.isHiddenOrHasHiddenAncestor })
        // 一行按钮：文字按钮各自够宽、互不重叠，图标收在最后。
        #expect(open.frame.width >= ceil(open.attributedTitle.size().width))
        #expect(archive.frame.width >= ceil(archive.attributedTitle.size().width))
        #expect(open.frame.maxX < archive.frame.minX)
        #expect(archive.frame.maxX < folder.frame.minX)
        #expect(open.frame.minY == archive.frame.minY)
        #expect(open.frame.minY == folder.frame.minY)
    }

    @Test func bothListsAreReadFromTheStore() throws {
        let (view, store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.create(name: "改写启动浮层", workdir: root.path)
        let second = try store.create(name: "侧栏回弹", workdir: root.path)
        let third = try store.create(name: "打包脚本", workdir: root.path)
        _ = try store.archive(at: third.fileURL)
        view.reload()

        #expect(Set(view.listedNames) == ["改写启动浮层", "侧栏回弹"])
        #expect(view.documentTable.numberOfRows == 2)
        #expect(counts(in: view) == [2, 1])

        view.select(.archived)
        #expect(view.listedNames == ["打包脚本"])

        _ = try store.archive(at: second.fileURL)
        view.reload()
        #expect(Set(view.listedNames) == ["打包脚本", "侧栏回弹"])
        #expect(counts(in: view) == [1, 2])
    }

    /// 选中一份文档，右栏给出**磁盘上的全文**和**完整路径**。
    @Test func selectingADocumentShowsItsBodyAndCompletePath() throws {
        let (view, store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let created = try store.create(name: "改写启动浮层", workdir: root.path,
                                       body: "## Next steps\n- 把摘要接到 TaskStore\n")
        view.reload()

        #expect(view.selectedDocumentPath == created.fileURL.path)
        #expect(view.documentPath == created.fileURL.path)
        // frontmatter 也在：右栏自陈的是这个文件里有什么，藏起来就跟编辑器里看到的对不上。
        #expect(view.documentBody.contains("name: 改写启动浮层"))
        #expect(view.documentBody.contains("把摘要接到 TaskStore"))
        let document = try #require(descendants(view).compactMap { $0 as? NSTextView }
            .first { $0.identifier?.rawValue == "handoff-document" })
        #expect(!document.isEditable)
        #expect(document.isSelectable)
    }

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

    /// 协议正文取自 `HandoffProtocol`，直接使用列表栏让出的阅读空间。
    ///
    /// 断言用的是 `HandoffProtocol` 当场算出来的整段，不是页面上抄下来的字面量：
    /// 这样协议一改，页面没跟上就是这条测试挂，而不是用户读到一份过期的协议。
    @Test func theProtocolEntryRendersTheInjectionTakenFromHandoffProtocol() throws {
        let (view, store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.create(name: "改写启动浮层", workdir: root.path)
        view.reload()
        view.layoutSubtreeIfNeeded()
        let documentDetailX = view.detailArea.frame.minX
        let listWidth = view.secondDivider.frame.midX - view.firstDivider.frame.midX
        view.select(.handoffProtocol)
        view.layoutSubtreeIfNeeded()
        #expect(view.detailArea.frame.minX < documentDetailX)
        // 在双栏模式调宽不覆盖文档列表宽度，切回后恢复三栏。
        view.firstDivider.onDrag?(view.firstDivider.frame.midX + 20)

        #expect(view.listedNames.isEmpty)
        #expect(view.documentTable.numberOfRows == 0)
        let rendered = view.protocolText
        for agent in SessionAgent.allCases {
            #expect(rendered.contains(HandoffProtocol.skillInvocation(
                agent: agent, plugin: HookMarketplace.pluginName, path: nil)))
        }
        #expect(rendered.contains(HandoffProtocol.skillDocument))
        #expect(rendered.contains(HandoffProtocol.directInstruction(path: "<task file path>")))
        #expect(rendered.contains(HandoffProtocol.writingRules))
        // 开场与中途绑定是两段不同的开头，两段都要在。
        for lateBinding in [false, true] {
            let injection = HandoffProtocol.injection(path: "<task file path>",
                                                      body: sampleTaskFile, lateBinding: lateBinding)
            #expect(rendered.contains(injection))
        }
        #expect(rendered.contains(L("When lightty injects")))
        view.select(.inProgress)
        view.layoutSubtreeIfNeeded()
        #expect(view.detailArea.frame.minX > view.firstDivider.frame.maxX)
        #expect(!view.documentTable.isHiddenOrHasHiddenAncestor)
        #expect(view.secondDivider.frame.midX - view.firstDivider.frame.midX == listWidth)
    }

    /// 文件在用户眼皮底下消失（Agent 改名、Finder 里删掉）时，右栏不许留着上一份的正文。
    @Test func aDocumentThatDisappearsFromDiskLeavesNoStaleContent() throws {
        let (view, store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try store.create(name: "改写启动浮层", workdir: root.path,
                                     body: "## Next steps\n- 只在第一份里出现的句子\n")
        _ = try store.create(name: "侧栏回弹", workdir: root.path,
                             body: "## Next steps\n- 只在第二份里出现的句子\n")
        view.reload()
        view.selectList(id: first.fileURL.path)
        #expect(view.documentBody.contains("只在第一份里出现的句子"))

        try FileManager.default.removeItem(at: first.fileURL)
        view.reload()
        #expect(view.listedNames == ["侧栏回弹"])
        #expect(!view.documentBody.contains("只在第一份里出现的句子"))
        #expect(view.documentBody.contains("只在第二份里出现的句子"))

        // 最后一份也没了：正文和路径都得清空，不能留着等下一次选中时闪一下旧内容。
        for entry in store.list().tasks { try FileManager.default.removeItem(at: entry.fileURL) }
        view.reload()
        #expect(view.listedNames.isEmpty)
        #expect(view.documentBody.isEmpty)
        #expect(view.documentPath.isEmpty)
    }

    // MARK: - 夹具

    /// 与设置页里那份示意任务文件逐字相同（`HandoffSettingsView.sampleTaskFile` 是私有的）。
    private let sampleTaskFile = """
        ---
        name: Rewrite the launch composer
        workdir: /Users/me/project/app
        tool: claude
        created: 2026-09-01T09:00:00Z
        updated: 2026-09-08T17:20:00Z
        ---
        ## Next steps
        - …
        """

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
