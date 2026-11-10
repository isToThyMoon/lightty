import Foundation
import LighttyCore
import Testing
@testable import lightty

@Test func ordinaryAgentLaunchUsesHookIdentity() {
    let home = URL(fileURLWithPath: "/home")
    let key = AgentSessionKey(agent: .claude, sourceRoot: "/fixture", nativeID: "live")
    let fallback = PaneSessionAssociation(key: key, configuration: .custom("/fixture"), workingDirectory: "/work")
    let status = PaneStatus(ts: Date(), state: .thinking, agent: "claude", sessionID: "live")
    #expect(PaneSessionAssociation.resolve(status: status, fallback: nil,
        processExited: false, candidates: [key], home: home)?.key == key)
    #expect(PaneSessionAssociation.resolve(status: status, fallback: nil,
        processExited: true, candidates: [key], home: home) == nil)
    let other = AgentSessionKey(agent: .claude, sourceRoot: "/other", nativeID: "live")
    #expect(PaneSessionAssociation.resolve(status: status, fallback: nil,
        processExited: false, candidates: [key, other], home: home) == nil)
    let rooted = PaneStatus(ts: Date(), state: .idle, agent: "claude", sessionID: "live", sourceRoot: "/other")
    #expect(PaneSessionAssociation.resolve(status: rooted, fallback: fallback,
        processExited: false, candidates: [key, other], home: home)?.key == other)
    let ended = PaneStatus(ts: Date(), state: .idle, agent: "claude", sessionID: "live", sourceRoot: "/other", event: "SessionEnd")
    #expect(PaneSessionAssociation.resolve(status: ended, fallback: fallback,
        processExited: false, candidates: [key, other], home: home) == nil)
    #expect(PaneSessionAssociation.resolve(status: nil, fallback: fallback,
        processExited: false, candidates: [], home: home) == fallback)
    #expect(PaneSessionAssociation.resolve(status: nil, fallback: fallback,
        processExited: true, candidates: [], home: home) == nil)
    #expect(PaneSessionAssociation.resolve(status: nil, fallback: nil,
        processExited: false, candidates: [], home: home) == nil)
}

/// 续接后的 Codex 在第一个 hook 之前只有终端信号兜底的状态，里面没有会话 ID。
/// 它不能把恢复来的关联冲掉，否则下一次快照写成无会话，再重启就不续接了。
@Test func terminalSignalStatusKeepsResumedIdentity() {
    let home = URL(fileURLWithPath: "/home")
    let key = AgentSessionKey(agent: .codex, sourceRoot: "/home/.codex", nativeID: "thread")
    let resumed = PaneSessionAssociation(key: key, configuration: .standard, workingDirectory: "/work")
    let signal = PaneStatus(ts: Date(), state: .attention, agent: "codex", event: PaneStatusStore.fallbackEvent)
    #expect(PaneSessionAssociation.resolve(status: signal, fallback: resumed,
        processExited: false, candidates: [], home: home) == resumed)
    let other = PaneSessionAssociation(key: .init(agent: .claude, sourceRoot: "/home/.claude", nativeID: "c"),
        configuration: .standard, workingDirectory: "/work")
    #expect(PaneSessionAssociation.resolve(status: signal, fallback: other,
        processExited: false, candidates: [], home: home) == nil)
    #expect(PaneSessionAssociation.resolve(status: signal, fallback: nil,
        processExited: false, candidates: [], home: home) == nil)
}

@Test func hookSourceRootSurvivesWireRoundTrip() throws {
    let status = PaneStatus(ts: Date(timeIntervalSince1970: 100), state: .idle,
        agent: "codex", sessionID: "fixture", sourceRoot: "/custom/codex",
        sourceConfiguration: .custom("/custom/codex"))
    let message = PaneStatusDatagram(pane: UUID(), status: status)
    #expect(try PaneStatusDatagram.decode(message.encode()) == message)
}

@Test func explicitDefaultLookingConfigurationAndLegacySnapshots() throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    for agent in SessionAgent.allCases {
        let key = AgentSessionKey(agent: agent, sourceRoot: SessionConfigurationLocation.standard.root(for: agent, home: home).path,
                                  nativeID: "legacy")
        let location = SessionConfigurationLocation.custom(key.sourceRoot)
        let status = PaneStatus(ts: Date(), state: .idle, agent: agent.rawValue, sessionID: key.nativeID,
            sourceRoot: key.sourceRoot, sourceConfiguration: location, cwd: home.path)
        let association = try #require(PaneSessionAssociation.resolve(status: status, fallback: nil,
            processExited: false, candidates: [], home: home))
        #expect(association.configuration == location)
        #expect(try association.resumePlan(executable: "/bin/echo").context.environment[agent.configurationVariable] == key.sourceRoot)
        let legacy = PaneSnapshot(name: "v1", agent: agent.rawValue, sessionID: key.nativeID,
                                  agentCWD: home.path, agentAlive: true)
        let restored = try #require(PaneSessionAssociation(snapshot: legacy, home: home))
        #expect(restored.key == key)
        #expect(restored.configuration == .standard)
        #expect(try restored.resumePlan(executable: "/bin/echo").context.unsetEnvironment == [agent.configurationVariable])
    }
}
