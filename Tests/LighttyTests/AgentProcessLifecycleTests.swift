import AppKit
import Darwin
import LighttyCore
import Testing
@testable import lightty

extension SessionAssociationTests {
    @Test(arguments: SessionAgent.allCases)
    func agentExitWithoutEndHookClearsAssociation(agent: SessionAgent) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = AppState.shared
        AppState.shared = AppState(taskDirectory: root, sweepStalePanes: false)
        if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }
        defer { AppState.shared = previous ?? AppState.shared; try? FileManager.default.removeItem(at: root) }
        let store = PaneStatusStore(socketPath: URL(fileURLWithPath: "/tmp/lt-\(UUID().uuidString).sock"))
        #expect(store.start())
        defer { store.stop() }
        let pane = PaneView(statusStore: store)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        var info = proc_bsdinfo()
        #expect(proc_pidinfo(process.processIdentifier, PROC_PIDTBSDINFO, 0, &info,
                             Int32(MemoryLayout<proc_bsdinfo>.stride)) > 0)
        let key = AgentSessionKey(agent: agent, sourceRoot: root.path, nativeID: "exit-fixture")
        let status = PaneStatus(ts: Date(), state: .idle, agent: agent.rawValue, sessionID: key.nativeID,
                                sourceRoot: root.path, cwd: root.path, event: "SessionStart")
        var json = try #require(JSONSerialization.jsonObject(with: PaneStatusDatagram(pane: pane.dragIdentifier, status: status).encode()) as? [String: Any])
        json["agent_process"] = ["pid": process.processIdentifier, "startedSeconds": info.pbi_start_tvsec,
                                  "startedMicroseconds": info.pbi_start_tvusec]
        _ = PaneStatusDatagram.send(try JSONSerialization.data(withJSONObject: json), to: store.socketPath.path)
        let readyDeadline = Date().addingTimeInterval(2)
        while pane.displayedSessionKey == nil && Date() < readyDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(pane.displayedSessionKey == key)
        let encodedSnapshot = try JSONEncoder().encode(pane.snapshot())
        #expect(!String(decoding: encodedSnapshot, as: UTF8.self).contains("agent_process"))
        pane.terminal.commandFinished(at: Date())
        #expect(pane.displayedSessionKey == key, "Shell completion must not detach a live known Agent")
        process.terminate() // Only our fixture; the pane/shell remains alive.
        let exitDeadline = Date().addingTimeInterval(2)
        while pane.displayedSessionKey != nil && Date() < exitDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(pane.displayedSessionKey == nil)
        #expect(!pane.snapshot().agentAlive)
        // A late non-end hook from the exited instance must not resurrect the binding.
        json["ts"] = ISO8601DateFormatter().string(from: Date())
        _ = PaneStatusDatagram.send(try JSONSerialization.data(withJSONObject: json), to: store.socketPath.path)
        try await Task.sleep(for: .milliseconds(30))
        #expect(pane.displayedSessionKey == nil)

        let replacement = Process()
        replacement.executableURL = URL(fileURLWithPath: "/bin/sleep")
        replacement.arguments = ["30"]
        try replacement.run()
        defer { if replacement.isRunning { replacement.terminate() } }
        let identity = try #require(AgentProcessIdentity.read(replacement.processIdentifier))
        let next = PaneStatus(ts: Date(), state: .idle, agent: agent.rawValue, sessionID: "replacement",
            sourceRoot: root.path, agentProcess: identity, cwd: root.path, event: "SessionStart")
        _ = PaneStatusDatagram(pane: pane.dragIdentifier, status: next).send(to: store.socketPath)
        let deadline = Date().addingTimeInterval(2)
        while pane.displayedSessionKey?.nativeID != "replacement" && Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(pane.displayedSessionKey?.nativeID == "replacement")
        json["ts"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(10))
        _ = PaneStatusDatagram.send(try JSONSerialization.data(withJSONObject: json), to: store.socketPath.path)
        try await Task.sleep(for: .milliseconds(30))
        #expect(pane.displayedSessionKey?.nativeID == "replacement", "Old process events cannot clear a new instance")
        replacement.terminate()
        replacement.waitUntilExit()
        #expect(!pane.snapshot().agentAlive, "Snapshot must reconcile before queued exit notifications")
    }
}

@Test func reusedPIDIsNotTheSameAgentInstance() throws {
    let current = try #require(AgentProcessIdentity.read(getpid()))
    let reused = AgentProcessIdentity(pid: current.pid, startedSeconds: current.startedSeconds - 1,
                                     startedMicroseconds: current.startedMicroseconds)
    #expect(current.liveness == .running)
    #expect(reused.liveness == .exited)
}
