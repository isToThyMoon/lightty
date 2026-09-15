import Foundation
import LighttyCore
import Testing
@testable import lightty

/// 手动触发的路径变更源：记下每个被监听的路径，`fire(_:)` 代替一次防抖后的文件事件。
final class ManualPathChanges {
    private var listeners: [(path: URL, onChange: () -> Void, token: Weak)] = []
    final class Weak { weak var value: AnyObject?; init(_ value: AnyObject) { self.value = value } }

    var source: PathChangeSource {
        { [unowned self] path, onChange in
            let token = NSObject()
            listeners.append((path, onChange, Weak(token)))
            return token
        }
    }

    /// 开过的监听总数，含已释放的。
    var registrations: Int { listeners.count }

    /// 仍被持有的监听路径。
    var watchedPaths: [URL] { listeners.filter { $0.token.value != nil }.map(\.path) }

    func fire(_ path: URL) {
        for listener in listeners where listener.path == path && listener.token.value != nil { listener.onChange() }
    }
}

/// 用户自己在终端里敲 `/rename`：没有钩子，只有 agent 写改名文件这一个信号。
@MainActor
struct SessionTitleSignalTests {
    private func fixture() throws -> (SessionModelFixture, ManualPathChanges, URL) {
        let changes = ManualPathChanges()
        let f = try SessionModelFixture(titleChanges: changes.source)
        let file = f.root.appendingPathComponent("session_index.jsonl")
        try Data("{}\n".utf8).write(to: file)
        f.catalog.signalFiles = [file]
        return (f, changes, file)
    }

    /// 钩子报过 SessionStart 的空闲会话。等关联变化引起的有界重读结束，再开始数读取次数。
    private func open(_ record: AgentSession, in pane: UUID, _ f: SessionModelFixture) async throws {
        try await f.load([record])
        try await f.status(.idle, event: "SessionStart", pane: pane, record: record)
        try await settle(f)
    }

    /// 等读取次数稳定：关联变化会引发最多五次有界重读，负载高时固定睡一下不够。
    private func settle(_ f: SessionModelFixture, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        var last = -1
        while last != f.catalog.requestCount || f.library.loading {
            try #require(ContinuousClock.now < deadline, "catalog reads never settled", sourceLocation: sourceLocation)
            last = f.catalog.requestCount
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    /// 文件信号只值一次目录读（active + archived 两页 = +2），不进入五次重试——
    /// 标题真的变了（改名）如此，标题没变（普通的 transcript 追加）也如此。
    @Test(arguments: [true, false])
    func titleSignalCostsExactlyOneRead(titleChanged: Bool) async throws {
        let (f, changes, file) = try fixture()
        defer { f.close() }
        let record = f.record(title: "你好"), id = f.pane()
        try await open(record, in: id, f)
        try await f.wait { changes.watchedPaths == [file] }

        if titleChanged { f.catalog.records = [f.record(title: "修复标题同步")] }
        let reads = f.catalog.requestCount
        changes.fire(file)
        if titleChanged {
            try await f.wait { f.library.paneState(for: id)?.title == "修复标题同步" && !f.library.loading }
        } else {
            try await f.wait { f.catalog.requestCount == reads + 2 && !f.library.loading }
        }
        // 否定式断言：之后「不该」再有读取，没有可等的信号，只能压一小段再查。
        try await Task.sleep(for: .milliseconds(60))
        #expect(f.catalog.requestCount == reads + 2,
                titleChanged ? "One catalog read (active + archived pages), no retries"
                             : "An ordinary transcript append costs one read, not five")
    }

    /// 只有钩子报过「空闲」的会话才响应文件信号：
    enum SessionState: CustomStringConvertible {
        /// 钩子报了 thinking，一个回合正在跑——Stop 钩子到时再重读
        case runningTurn
        /// 没有钩子状态（只有关联）——没有插件就分不清在跑还是空闲
        case noHookState
        var description: String { self == .runningTurn ? "running turn" : "no hook state" }
    }

    @Test(arguments: [SessionState.runningTurn, .noHookState])
    func titleSignalIsIgnoredUnlessSessionIsKnownIdle(state: SessionState) async throws {
        let (f, changes, file) = try fixture()
        defer { f.close() }
        let record = f.record(), id = f.pane()
        switch state {
        case .runningTurn:
            try await f.load([record])
            try await f.status(.thinking, event: "UserPromptSubmit", pane: id, record: record)
        case .noHookState:
            f.library.associate(.attached(f.association(record)), with: id)
            try await f.load([record])
        }
        try await f.wait { changes.watchedPaths == [file] }
        try await settle(f)
        let reads = f.catalog.requestCount
        changes.fire(file)
        // 否定式断言：信号「不该」触发读取，没有可等的信号，只能压一小段再查。
        try await Task.sleep(for: .milliseconds(300))
        #expect(f.catalog.requestCount == reads,
                state == .runningTurn ? "The Stop hook re-reads when the turn ends"
                                      : "No plugin, no way to tell a running turn from an idle one")
    }

    @Test func closedSessionsAreNoLongerWatchedAndReplacedFilesAreReopened() async throws {
        let (f, changes, file) = try fixture()
        defer { f.close() }
        let record = f.record(), id = f.pane()
        try await open(record, in: id, f)
        try await f.wait { changes.watchedPaths == [file] }

        // 临时文件 + rename：同一路径换了 inode，旧监听作废，要重开一个。
        let temporary = f.root.appendingPathComponent(".session_index.jsonl.tmp")
        try Data("{}\n{}\n".utf8).write(to: temporary)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
        #expect(changes.registrations == 1)
        changes.fire(file)
        try await f.wait { changes.registrations == 2 && changes.watchedPaths == [file] }

        f.library.associate(.none, with: id)
        try await f.wait { changes.watchedPaths.isEmpty }
    }
}

struct SessionTitleSignalFileTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func claudeFindsTheTranscriptInWhicheverProjectHoldsIt() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        let source = SessionCatalogSource(agent: .claude, root: root, executable: "/bin/echo",
                                          configuration: .custom(root.path))
        let provider = ClaudeSessionProvider(source: source)
        let key = AgentSessionKey(agent: .claude, sourceRoot: root.path, nativeID: id)
        #expect(provider.titleSignalFiles(for: key).isEmpty, "No transcript yet")

        for project in ["-Users-a-other", "-Users-a-project"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("projects/\(project)"),
                                                    withIntermediateDirectories: true)
        }
        let transcript = root.appendingPathComponent("projects/-Users-a-project/\(id).jsonl")
        try Data().write(to: transcript)
        #expect(provider.titleSignalFiles(for: key).map(\.standardizedFileURL) == [transcript.standardizedFileURL])
        let traversal = AgentSessionKey(agent: .claude, sourceRoot: root.path, nativeID: "../../etc")
        #expect(provider.titleSignalFiles(for: traversal).isEmpty)
    }

    @Test func codexWatchesTheSharedThreadNameIndex() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = SessionCatalogSource(agent: .codex, root: root, executable: "/bin/echo",
                                          configuration: .custom(root.path))
        let provider = CodexSessionProvider(source: source)
        let key = AgentSessionKey(agent: .codex, sourceRoot: root.path, nativeID: UUID().uuidString)
        #expect(provider.titleSignalFiles(for: key).isEmpty)
        let index = root.appendingPathComponent("session_index.jsonl")
        try Data().write(to: index)
        #expect(provider.titleSignalFiles(for: key).map(\.standardizedFileURL) == [index.standardizedFileURL])
    }
}
