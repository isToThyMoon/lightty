import Foundation
import LighttyCore
import Testing
@testable import lightty

/// The same provider seam used by the application, with mutable official metadata fixtures.
final class SessionModelCatalog: CatalogOnlyProvider {
    let source: SessionCatalogSource
    let pageSize: Int
    private let lock = NSLock()
    private var values: [AgentSession] = []
    private var reads = 0
    var records: [AgentSession] {
        get { lock.lock(); defer { lock.unlock() }; return values }
        set { lock.lock(); defer { lock.unlock() }; values = newValue }
    }
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    init(root: URL, pageSize: Int = 100, agent: SessionAgent = .codex) {
        source = .init(agent: agent, root: root, executable: "/bin/echo", configuration: .custom(root.path))
        self.pageSize = pageSize
    }
    func page(archived: Bool, cursor: String?, cancelled: () -> Bool) throws -> SessionCatalogPage {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        let records = values.filter { $0.sourceArchived == archived }
        let offset = cursor.flatMap(Int.init) ?? 0
        let page = Array(records.dropFirst(offset).prefix(pageSize))
        let next = offset + page.count
        return .init(sessions: page, nextCursor: next < records.count ? String(next) : nil)
    }
}

@MainActor
final class SessionModelFixture {
    let root: URL
    let catalog: SessionModelCatalog
    let statuses: PaneStatusStore
    let library: SessionLibrary
    /// 这家的 hook 插件装没装（`SessionLibrary` 的注入点）。默认按「装了」走，标题只看 hook + 目录。
    final class HookInstalledBox { var value = true }
    let hookInstalledBox = HookInstalledBox()
    var hookInstalled: Bool { get { hookInstalledBox.value } set { hookInstalledBox.value = newValue } }
    private var paneIDs: [UUID] = []

    init(pageSize: Int = 100, agent: SessionAgent = .codex,
         hostProcessID: Int32 = ProcessInfo.processInfo.processIdentifier) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        catalog = SessionModelCatalog(root: root, pageSize: pageSize, agent: agent)
        statuses = PaneStatusStore(socketPath: URL(fileURLWithPath: "/tmp/lt-\(UUID().uuidString).sock"))
        library = SessionLibrary(fileURL: root.appendingPathComponent("organization.json"), providers: [catalog],
                                 statusStore: statuses, metadataRefreshDelay: 0.01, hostProcessID: hostProcessID,
                                 hookInstalled: { [box = hookInstalledBox] _ in box.value })
    }
    func record(_ id: String = "fixture", title: String = "Conversation", directory: String? = nil,
                archived: Bool = false, processes: Set<AgentProcessIdentity> = []) -> AgentSession {
        .init(key: .init(agent: catalog.source.agent, sourceRoot: root.path, nativeID: id), title: title,
              workingDirectory: directory ?? root.path, updatedAt: nil, sourceArchived: archived, sourceProcesses: processes)
    }
    func association(_ record: AgentSession) -> PaneSessionAssociation {
        .init(key: record.key, configuration: .custom(record.key.sourceRoot), workingDirectory: root.path)
    }
    func pane(name: String = "My terminal") -> UUID {
        let id = UUID()
        paneIDs.append(id)
        library.registerPane(id, name: name, directory: nil)
        return id
    }
    func close() {
        paneIDs.forEach { library.removePane($0) }
        library.cancelLoading()
        statuses.stop()
        try? FileManager.default.removeItem(at: root)
    }
    func wait(sourceLocation: SourceLocation = #_sourceLocation, _ predicate: () -> Bool) async throws {
        try await awaitUntil("condition", sourceLocation: sourceLocation, predicate)
    }
    func load(_ records: [AgentSession]) async throws {
        catalog.records = records
        library.refresh()
        try await wait { !library.loading }
        // 会话库的变更通知合流到下一拍，收到通知的列表再合流一拍。
        await awaitMainQueue(hops: 2)
    }
    func status(_ state: PaneActivity, event: String, pane: UUID, record: AgentSession,
                directory: String? = nil) async throws {
        #expect(statuses.start())
        let value = PaneStatus(ts: Date(), state: state, agent: record.key.agent.rawValue,
            sessionID: record.key.nativeID, sourceRoot: record.key.sourceRoot,
            cwd: directory ?? root.path, event: event)
        _ = PaneStatusDatagram(pane: pane, status: value).send(to: statuses.socketPath)
        try await wait { library.paneState(for: pane)?.status?.event == event }
        await awaitMainQueue(hops: 2)
    }
}

@MainActor
struct SessionModelTests {
    @Test func markAllReadAcknowledgesRequestsWithoutErasingThemOrRefetchingMetadata() async throws {
        let f = try SessionModelFixture()
        defer { f.close() }
        let record = f.record(), first = f.pane(), second = f.pane(), completed = f.pane()
        try await f.load([record])
        try await f.status(.done, event: "Stop", pane: completed, record: record)
        try await f.status(.attention, event: "PermissionRequest", pane: first, record: record)
        try await f.status(.attention, event: "Notification", pane: second, record: record)
        try await f.wait { !f.library.loading }
        // Completion may have scheduled bounded metadata retries. Finish that setup
        // before measuring whether the read operation itself starts catalog work.
        f.library.cancelLoading()
        await awaitMainQueue(hops: 2)
        let reads = f.catalog.requestCount
        var changes: [SessionChange] = []
        let observer = NotificationCenter.default.addObserver(forName: .lighttySessionLibraryDidChange,
            object: f.library, queue: nil) { note in
            MainActor.assumeIsolated { if let change = SessionChange.from(note) { changes.append(change) } }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        #expect(f.statuses.hasUnreadReminders)
        f.statuses.markAllRead()
        #expect(!f.statuses.hasUnreadReminders)
        #expect(f.statuses.attentionCount == 2 && f.statuses.unreadCount == 0)
        for id in [first, second] {
            #expect(f.library.paneState(for: id)?.status?.state == .attention)
            #expect(f.library.paneState(for: id)?.isUnread == false)
        }
        #expect(f.library.paneState(for: completed)?.status?.state == .idle)
        try await f.wait { changes.contains { $0.panes[first]?.contains(.activity) == true
            && $0.panes[second]?.contains(.activity) == true } }
        #expect(f.catalog.requestCount == reads)
        #expect(changes.allSatisfy { !$0.catalog })

        // Re-delivery of the same request is not a new unread request. The following
        // pane event is a receive-queue barrier, so no arbitrary sleep is needed.
        let duplicate = try #require(f.statuses.status(for: first))
        _ = PaneStatusDatagram(pane: first, status: duplicate).send(to: f.statuses.socketPath)
        try await f.status(.thinking, event: "UserPromptSubmit", pane: second, record: record)
        #expect(f.library.paneState(for: first)?.isUnread == false)
        try await f.status(.attention, event: "Notification", pane: first, record: record)
        #expect(f.library.paneState(for: first)?.isUnread == true)
        #expect(f.statuses.unreadActivity(for: first) == .attention)
    }

    @Test(arguments: [false, true])
    func restoreHydratesSharedBindingsBeyondPageOneWithoutViews(catalogAlreadyLoaded: Bool) async throws {
        let f = try SessionModelFixture(pageSize: 1)
        defer { f.close() }
        let target = f.record("older", title: "Restored conversation")
        f.catalog.records = [f.record("recent"), target, f.record("unneeded")]
        if catalogAlreadyLoaded {
            f.library.refresh()
            try await f.wait { !f.library.loading }
            #expect(f.catalog.requestCount == 2)
        }
        let first = f.pane(), second = f.pane()
        for id in [first, second] { f.library.associate(.restoring(f.association(target)), with: id) }
        let a = UUID(), b = UUID()
        f.library.updateWindow(a, panes: [first], selected: first)
        f.library.updateWindow(b, panes: [second], selected: second)
        f.library.start()
        try await f.wait { f.library.paneState(for: second)?.session == target && !f.library.loading }
        #expect(f.library.paneState(for: first)?.session == target)
        #expect(f.library.paneState(for: first)?.binding == .restoring(f.association(target)))
        #expect(f.library.openPaneIDs(for: target.key) == [first, second])
        #expect(f.library.selectedSession(in: a) == target.key)
        #expect(f.library.selectedSession(in: b) == target.key)
        #expect(f.catalog.requestCount == 3, "Stop paging as soon as associated records are hydrated")
    }

    @Test func metadataIsCommittedForEveryPaneBeforeOneTypedNotification() async throws {
        let f = try SessionModelFixture()
        defer { f.close() }
        let process = try #require(AgentProcessIdentity.read(ProcessInfo.processInfo.processIdentifier))
        let old = f.record(), changed = f.record(title: "New name", directory: "/new-folder", processes: [process])
        let first = f.pane(), second = f.pane(), unrelated = f.pane()
        for id in [first, second] { f.library.associate(.attached(f.association(old)), with: id) }
        try await f.load([old])
        var changes: [SessionChange] = []
        let observer = NotificationCenter.default.addObserver(forName: .lighttySessionLibraryDidChange,
            object: f.library, queue: nil) { notification in
            MainActor.assumeIsolated {
                guard let change = SessionChange.from(notification) else { return }
                changes.append(change)
                if change.panes[first] != nil {
                    #expect(f.library.paneState(for: first)?.session == f.library.paneState(for: second)?.session)
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try await f.load([changed])
        #expect(f.library.records == [changed])
        #expect(f.library.paneState(for: first)?.session == changed)
        #expect(f.library.paneState(for: second)?.title == "New name")
        #expect(f.library.paneState(for: first)?.terminalName == "My terminal")
        #expect(changes.contains { $0.panes[first]?.contains(.metadata) == true && $0.panes[second]?.contains(.metadata) == true })
        #expect(changes.allSatisfy { $0.panes[unrelated] == nil })
        #expect(changes.contains { $0.sessions.contains(changed.key) })
    }

    @Test func metadataInvalidationRefreshesACachedSessionBeyondPageOne() async throws {
        let f = try SessionModelFixture(pageSize: 1)
        defer { f.close() }
        let recent = f.record("recent"), target = f.record("older"), id = f.pane()
        f.catalog.records = [recent, target, f.record("unneeded")]
        f.library.associate(.restoring(f.association(target)), with: id)
        f.library.start()
        try await f.wait { f.library.paneState(for: id)?.session == target && !f.library.loading }
        let changed = f.record("older", title: "Changed older session", directory: "/new-folder")
        f.catalog.records = [recent, changed, f.record("unneeded")]
        f.library.invalidateMetadata(for: target.key)
        try await f.wait { f.library.paneState(for: id)?.session == changed && !f.library.loading }
        #expect(f.catalog.requestCount == 6, "Re-read the target page, then stop before unrelated older pages")
    }

    /// 用户自己在终端里敲 `/rename` 不触发任何钩子，官方也没有改名订阅接口。
    /// 最早的补救时机是他开始下一轮提问（`UserPromptSubmit` → thinking）：这时重读一次官方
    /// 列表，标题不用等这一轮结束。
    @Test func aPromptAfterATerminalRenameRereadsTheTitle() async throws {
        let f = try SessionModelFixture()
        defer { f.close() }
        let record = f.record(title: "旧标题"), id = f.pane()
        f.library.associate(.attached(f.association(record)), with: id)
        try await f.load([record])
        try await f.status(.done, event: "Stop", pane: id, record: record)
        // 回合结束那条刷新有五次有界重试（每次读 active + archived 两页），等它跑完再改标题，
        // 之后的读取只可能来自新的一轮提问。
        try await f.wait { f.catalog.requestCount == 12 && !f.library.loading }
        f.catalog.records = [f.record(title: "新标题")]
        try await f.status(.thinking, event: "UserPromptSubmit", pane: id, record: record)
        try await f.wait { f.library.paneState(for: id)?.title == "新标题" }
    }

    /// 标题同一时刻只有一个来源，来源之间不穿插。hook 插件**没装**时，标题看得出是 agent 写的就照
    /// 原文显示（和原生终端一样，看得见状态前缀）、图标按认出的家给；shell 写的标题不显示；agent 退出
    /// （命令结束标记）后回到 pane 名。装了 hook 时标题走 hook + 目录：启动阶段是图标 + pane 名，
    /// 绑定后只看目录，agent 退出（SessionEnd）直接回 pane 名、图标一起走，不在中间亮一下旧标题。
    @Test func agentTitleShowsOnlyWithoutHooksAndTheIconFollowsRecognition() async throws {
        let f = try SessionModelFixture()
        defer { f.close() }
        let record = f.record(title: "Conversation")
        let id = f.pane()
        #expect(f.library.paneState(for: id)?.title == "My terminal")

        // —— 没装 hook：原生终端显示什么就显示什么
        f.hookInstalled = false
        f.library.noteTerminalTitle("florian@mac: ~", in: id)
        #expect(f.library.paneState(for: id)?.title == "My terminal", "shell 的标题不是 agent 的，不显示")
        f.library.noteTerminalTitle("◑ Shopify 公司介绍", in: id)
        #expect(f.library.paneState(for: id)?.title == "◑ Shopify 公司介绍")
        #expect(f.library.paneState(for: id)?.displayAgent == .claude, "没绑定也给图标")
        #expect(f.library.paneState(for: id)?.sessionKey == nil, "图标不等于关联")
        f.library.renamePane(id, to: "Build")
        #expect(f.library.paneState(for: id)?.title == "◑ Shopify 公司介绍", "agent 在跑时 pane 名不显示")
        f.library.commandFinished(in: id, at: Date())
        #expect(f.library.paneState(for: id)?.title == "Build", "agent 退出：pane 名回来，那是我们的")
        #expect(f.library.paneState(for: id)?.displayAgent == nil)

        // Codex：空闲的标题没前缀，认不出；转起来才认，之后没前缀的也按它显示
        f.library.noteTerminalTitle("回应问候 | florian", in: id)
        #expect(f.library.paneState(for: id)?.title == "Build")
        f.library.noteTerminalTitle("⠋ 回应问候 | florian", in: id)
        #expect(f.library.paneState(for: id)?.displayAgent == .codex)
        f.library.noteTerminalTitle("回应问候 | florian", in: id)
        #expect(f.library.paneState(for: id)?.title == "回应问候 | florian")
        f.library.commandFinished(in: id, at: Date())

        // —— 装了 hook：标题走 hook + 目录，agent 的标题只贡献图标
        f.hookInstalled = true
        f.library.noteTerminalTitle("⠋ lightty", in: id)
        #expect(f.library.paneState(for: id)?.title == "Build", "Codex 启动转圈：pane 名不动")
        #expect(f.library.paneState(for: id)?.displayAgent == .codex, "但图标已经有了")
        f.library.noteTerminalTitle("lightty", in: id)
        #expect(f.library.paneState(for: id)?.title == "Build")

        try await f.load([record])
        try await f.status(.idle, event: "SessionStart", pane: id, record: record)
        #expect(f.library.paneState(for: id)?.title == "Conversation", "绑定后只看官方目录")
        f.library.noteTerminalTitle("⠋ Conversation | lightty", in: id)
        #expect(f.library.paneState(for: id)?.title == "Conversation", "绑定期间程序标题不穿插进来")

        try await f.status(.idle, event: "SessionEnd", pane: id, record: record)
        #expect(f.library.paneState(for: id)?.sessionKey == nil)
        #expect(f.library.paneState(for: id)?.title == "Build", "退出直接回 pane 名，不亮旧标题")
        #expect(f.library.paneState(for: id)?.displayAgent == nil, "图标一起走")
    }

    /// Codex 的 hook 全失效时，本 pane 的标题与桌面通知兜底推状态；只动 Codex，
    /// Claude 的 pane 收到同样的信号不改状态。
    @Test func terminalSignalsStandInForCodexButNotClaude() async throws {
        let f = try SessionModelFixture()
        defer { f.close() }
        let codex = f.pane(), claude = f.pane()
        // 在 shell 里敲 codex 的那次回车：还没认出 Codex，随后的加载转圈不算回合
        f.library.noteSubmit(in: codex)
        f.library.noteTerminalTitle("⠋ codex | florian", in: codex)
        #expect(f.statuses.status(for: codex) == nil)
        f.library.noteTerminalTitle("codex | florian", in: codex)
        // 认出 Codex 之后提交输入，转圈就是回合
        f.library.noteSubmit(in: codex)
        f.library.noteTerminalTitle("⠋ 回应问候 | florian", in: codex)
        #expect(f.statuses.status(for: codex)?.state == .thinking)
        f.library.noteDesktopNotification("你好！有什么我可以帮忙的？", in: codex)
        #expect(f.statuses.unreadActivity(for: codex) == .done)

        f.library.noteTerminalTitle("◑ Shopify 公司介绍", in: claude)
        f.library.noteDesktopNotification("Agent turn complete", in: claude)
        #expect(f.statuses.status(for: claude) == nil)
    }

    @Test func hooksDirectoryAndExitUseTheSameBindingState() async throws {
        let f = try SessionModelFixture()
        defer { f.close() }
        let record = f.record()
        let id = f.pane()
        try await f.load([record])
        let window = UUID()
        f.library.updateWindow(window, panes: [id], selected: id)
        try await f.status(.idle, event: "SessionStart", pane: id, record: record)
        #expect(f.library.paneState(for: id)?.binding == .attached(f.association(record)))
        #expect(f.library.openedSessionKeys == [record.key])
        try await f.status(.tool, event: "PreToolUse", pane: id, record: record, directory: "/agent-folder")
        #expect(f.library.paneState(for: id)?.acceptsInput == false)
        #expect(f.library.paneState(for: id)?.workingDirectory == "/agent-folder")
        f.library.updateDirectory("/shell-folder", for: id)
        #expect(f.library.paneState(for: id)?.workingDirectory == "/shell-folder")
        try await f.status(.idle, event: "SessionEnd", pane: id, record: record)
        #expect(f.library.paneState(for: id)?.sessionKey == nil)
        #expect(f.library.paneState(for: id)?.title == "My terminal")
        #expect(f.library.selectedSession(in: window) == nil)
        #expect(f.library.openedSessionKeys.isEmpty)
        f.library.associate(.restoring(f.association(record)), with: id)
        #expect(f.library.selectedSession(in: window) == record.key, "An old end hook cannot erase a new resume")
    }

    @Test func unavailableAndDifferentSourcesNeverClaimAnOpenBinding() async throws {
        let f = try SessionModelFixture()
        defer { f.close() }
        let record = f.record(), id = f.pane()
        let intent = f.association(record)
        f.library.associate(.unavailable(intent), with: id)
        f.library.updateWindow(UUID(), panes: [id], selected: id)
        try await f.load([record])
        #expect(f.library.paneState(for: id)?.binding.association == intent)
        #expect(f.library.paneState(for: id)?.session == nil)
        #expect(f.library.openedSessionKeys.isEmpty)
        let other = PaneSessionAssociation(key: .init(agent: .codex, sourceRoot: "/other-source", nativeID: record.key.nativeID),
            configuration: .custom("/other-source"), workingDirectory: f.root.path)
        f.library.associate(.attached(other), with: id)
        #expect(f.library.paneState(for: id)?.session == nil)
        #expect(f.library.openPaneIDs(for: record.key).isEmpty)
    }

    @Test func windowSelectionAndClosingDoNotFetchOrDetachOtherWindows() async throws {
        let f = try SessionModelFixture()
        defer { f.close() }
        let record = f.record(), first = f.pane(), second = f.pane(), shell = f.pane()
        for id in [first, second] { f.library.associate(.attached(f.association(record)), with: id) }
        try await f.load([record])
        let a = UUID(), b = UUID(), reads = f.catalog.requestCount
        f.library.updateWindow(a, panes: [first, shell], selected: first)
        f.library.updateWindow(b, panes: [second], selected: second)
        f.library.updateWindow(a, panes: [first, shell], selected: shell)
        #expect(f.library.selectedSession(in: a) == nil)
        #expect(f.library.selectedSession(in: b) == record.key)
        f.library.removePane(second)
        #expect(f.library.paneState(for: second) == nil)
        #expect(f.library.selectedPane(in: b) == nil)
        #expect(f.library.openPaneIDs(for: record.key) == [first])
        f.library.removeWindow(b)
        #expect(f.library.openPaneIDs(for: record.key) == [first])
        f.library.updateWindow(a, panes: [shell], selected: shell)
        #expect(f.library.openedSessionKeys.isEmpty)
        #expect(f.library.paneState(for: first)?.sessionKey == record.key, "Closing layout is not an Agent exit event")
        #expect(f.catalog.requestCount == reads)
    }

    @Test func metadataRetryIsBoundedAndCancellationSurvivesSelectionChanges() async throws {
        let f = try SessionModelFixture()
        defer { f.close() }
        let record = f.record(), id = f.pane()
        f.library.associate(.attached(f.association(record)), with: id)
        try await f.load([record])
        f.library.invalidateMetadata(for: record.key)
        try await f.wait { f.catalog.requestCount == 12 && !f.library.loading }
        try await Task.sleep(for: .milliseconds(60))
        #expect(f.catalog.requestCount == 12, "Five bounded metadata reads, not a notification feedback loop")
        f.library.invalidateMetadata(for: record.key)
        f.library.cancelLoading()
        f.library.updateWindow(UUID(), panes: [id], selected: id)
        try await Task.sleep(for: .milliseconds(60))
        #expect(f.catalog.requestCount == 12)
        #expect(!f.library.loaded)
    }

    @Test(arguments: ["", "  \n  "])
    func missingOrBlankMetadataUsesTerminalName(title: String) async throws {
        let f = try SessionModelFixture()
        defer { f.close() }
        let record = f.record(title: title), id = f.pane()
        f.library.associate(.restoring(f.association(record)), with: id)
        #expect(f.library.paneState(for: id)?.title == "My terminal")
        try await f.load([record])
        #expect(f.library.paneState(for: id)?.title == "My terminal")
        #expect(f.library.paneState(for: id)?.sessionKey == record.key)
    }
}
