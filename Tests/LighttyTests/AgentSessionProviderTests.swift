import Foundation
import LighttyCore
import Testing
@testable import lightty

/// 改名、删除、占用经 `AgentSessionProvider` 的分支。provider 是替身，不起任何进程；
/// 真 adapter 对真 CLI / SDK 的验证在 SessionRenameTests、SessionDeletionTests 里。
struct AgentSessionProviderTests {
    private let id = "01a07a5f-6811-7f12-94c5-dc0f0f92f40a"
    private func key(_ provider: FakeSessionProvider) -> AgentSessionKey {
        AgentSessionKey(agent: provider.source.agent, sourceRoot: provider.source.root.path, nativeID: id)
    }

    // MARK: 改名

    @Test func renameHandsTheCleanedTitleToTheProvider() throws {
        let provider = FakeSessionProvider()
        try SessionRename.rename(key(provider), to: "  第一行\n第二行 ", provider: provider)
        #expect(provider.calls == [.rename(key(provider), "第一行 第二行")])
    }

    @Test func anyProviderRenameErrorIsReportedAsOneFailure() {
        let provider = FakeSessionProvider(agent: .codex)
        provider.renameError = SessionCatalogError.timeout
        #expect(throws: SessionRename.Failure.failed) {
            try SessionRename.rename(key(provider), to: "新名字", provider: provider)
        }
    }

    // MARK: 删除

    @Test func idleSessionIsCheckedThenDeleted() throws {
        let provider = FakeSessionProvider()
        let identity = AgentProcessIdentity(pid: 42, startedSeconds: 7, startedMicroseconds: 0)
        let known = [identity: key(provider)]
        try SessionDeletion.delete(key(provider), provider: provider, known: known)
        #expect(provider.calls == [.occupancy(key(provider)), .checkDeletable(key(provider), known), .delete(key(provider))])
    }

    @Test func externalWriterBlocksDeletionBeforeAnyCheck() {
        let provider = FakeSessionProvider(agent: .codex)
        provider.occupancyResult = .inUse(pid: 123)
        do {
            try SessionDeletion.delete(key(provider), provider: provider, acceptingUnknownOccupancy: true)
            Issue.record("An occupied session must not be deleted")
        } catch SessionDeletion.Failure.occupiedProcess(let pid) {
            #expect(pid == 123)
        } catch { Issue.record("Unexpected \(error)") }
        #expect(provider.calls == [.occupancy(key(provider))])
    }

    /// 说不清谁在用：没同意就停，同意了只压掉这一种失败。
    @Test func unknownUsageNeedsExplicitConsent() throws {
        let provider = FakeSessionProvider()
        provider.deletionCheckError = SessionDeletion.Failure.unknownOccupancy(42)
        do {
            try SessionDeletion.delete(key(provider), provider: provider)
            Issue.record("Unknown usage must not be treated as idle")
        } catch SessionDeletion.Failure.unknownOccupancy(let pid) {
            #expect(pid == 42)
        }
        #expect(!provider.calls.contains(.delete(key(provider))))
        try SessionDeletion.delete(key(provider), provider: provider, acceptingUnknownOccupancy: true)
        #expect(provider.calls.last == .delete(key(provider)))
    }

    @Test func consentNeverOverridesConfirmedUsage() {
        let provider = FakeSessionProvider()
        provider.deletionCheckError = SessionDeletion.Failure.occupiedProcess(9)
        #expect(throws: SessionDeletion.Failure.self) {
            try SessionDeletion.delete(key(provider), provider: provider, acceptingUnknownOccupancy: true)
        }
        #expect(!provider.calls.contains(.delete(key(provider))))
    }

    @Test func nativeDeletionErrorIsReportedAsFailed() {
        let provider = FakeSessionProvider(agent: .codex)
        provider.deleteError = SessionCatalogError.protocolFailure
        do {
            try SessionDeletion.delete(key(provider), provider: provider)
            Issue.record("A native failure must not look like success")
        } catch SessionDeletion.Failure.failed {
        } catch { Issue.record("Unexpected \(error)") }
    }

    // MARK: 存活进程观测

    /// 观察只补空目录与进程证据，不覆盖官方给的目录；问不出来整页原样返回。
    @Test func liveObservationAnnotatesWithoutOverriding() throws {
        let provider = FakeSessionProvider()
        let other = "5b6ff2ba-3f6c-4d1e-9f70-2b1c0a4d8e11"
        let root = provider.source.root.path
        provider.sessions = [
            AgentSession(key: .init(agent: .claude, sourceRoot: root, nativeID: id), title: "a",
                         workingDirectory: nil, updatedAt: nil),
            AgentSession(key: .init(agent: .claude, sourceRoot: root, nativeID: other), title: "b",
                         workingDirectory: "/official", updatedAt: nil),
        ]
        #expect(try provider.page(archived: false, cursor: nil, cancelled: { false }).sessions == provider.sessions)
        let process = AgentProcessIdentity(pid: 42, startedSeconds: 7, startedMicroseconds: 0)
        provider.observation = LiveSessionObservation(processes: [other: [process]],
                                                      workingDirectories: [id: "/live", other: "/live"])
        let page = try provider.page(archived: false, cursor: nil, cancelled: { false })
        #expect(page.sessions.map(\.workingDirectory) == ["/live", "/official"])
        #expect(page.sessions.map(\.sourceProcesses) == [[], [process]])
        // 空页不值得起一次观察。
        provider.sessions = []
        let before = provider.calls.count
        _ = try provider.page(archived: false, cursor: nil, cancelled: { false })
        #expect(provider.calls.count == before)
    }

    // MARK: 构造

    @Test func eachAgentGetsItsOwnAdapter() {
        for agent in SessionAgent.allCases {
            let source = SessionCatalogSource(agent: agent, root: URL(fileURLWithPath: "/fixture"),
                                              executable: "/bin/false", configuration: .standard)
            let provider = source.makeProvider()
            #expect(provider.source == source)
            switch agent {
            case .claude: #expect(provider is ClaudeSessionProvider)
            case .codex: #expect(provider is CodexSessionProvider)
            }
        }
    }

    @MainActor @Test func injectedProvidersAreTheOnlyOnesTheLibraryUses() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = FakeSessionProvider(agent: .codex)
        let library = SessionLibrary(fileURL: root.appendingPathComponent("organization.json"), providers: [codex])
        #expect(library.provider(for: .codex) as? FakeSessionProvider === codex)
        #expect(library.provider(for: .claude) == nil)
    }
}
