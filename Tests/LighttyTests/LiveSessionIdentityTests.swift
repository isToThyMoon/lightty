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
        #expect(try association.resumePlan(executable: "/bin/echo").environment[agent.configurationVariable] == key.sourceRoot)
        let legacy = PaneSnapshot(name: "v1", agent: agent.rawValue, sessionID: key.nativeID,
                                  agentCWD: home.path, agentAlive: true)
        let restored = try #require(PaneSessionAssociation(snapshot: legacy, home: home))
        #expect(restored.key == key)
        #expect(restored.configuration == .standard)
        #expect(try restored.resumePlan(executable: "/bin/echo").unsetEnvironment == [agent.configurationVariable])
    }
}
