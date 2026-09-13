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
        let library = SessionLibrary(fileURL: root.appendingPathComponent("catalog.json"), providers: [], statusStore: store)
        let pane = PaneView(sessionLibrary: library)
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

    enum CloseRoute: CaseIterable { case eachPane, tab, tabScope, clearTabs }

    /// 关闭的每条路（pane ✕ / shell 退出、容器行 ✕、close_tab、清空窗口）对进程的对账效果必须一样：
    /// Agent 已经退出、退出通知还排在主队列里时关掉终端，关联当场解除，不能只有 pane ✕ 那条路做到。
    @Test(arguments: CloseRoute.allCases)
    func everyCloseRouteReconcilesAgentProcesses(route: CloseRoute) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = AppState.shared
        AppState.shared = AppState(taskDirectory: root, sweepStalePanes: false)
        if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }
        defer { AppState.shared = previous ?? AppState.shared; try? FileManager.default.removeItem(at: root) }
        let store = PaneStatusStore(socketPath: URL(fileURLWithPath: "/tmp/lt-\(UUID().uuidString).sock"))
        #expect(store.start())
        defer { store.stop() }
        let library = SessionLibrary(fileURL: root.appendingPathComponent("catalog.json"), providers: [], statusStore: store)
        let first = PaneView(sessionLibrary: library)
        let controller = TerminalWindowController(initialPane: first)
        AppState.shared.windowControllers = [controller]
        defer { controller.window?.close(); AppState.shared.windowControllers = [] }
        let second = PaneView(sessionLibrary: library)
        controller.addPaneToActiveTab(second)
        let panes = [first, second]

        var processes: [Process] = []
        defer { processes.filter(\.isRunning).forEach { $0.terminate() } }
        var identities: [AgentProcessIdentity] = []
        for (index, pane) in panes.enumerated() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["30"]
            try process.run()
            processes.append(process)
            let identity = try #require(AgentProcessIdentity.read(process.processIdentifier))
            identities.append(identity)
            let status = PaneStatus(ts: Date(), state: .idle, agent: SessionAgent.claude.rawValue,
                sessionID: "close-\(index)", sourceRoot: root.path, agentProcess: identity, cwd: root.path, event: "SessionStart")
            _ = PaneStatusDatagram(pane: pane.dragIdentifier, status: status).send(to: store.socketPath)
        }
        let readyDeadline = Date().addingTimeInterval(2)
        while panes.contains(where: { $0.displayedSessionKey == nil }) && Date() < readyDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(panes.allSatisfy { $0.displayedSessionKey != nil })

        // 从这里起不再让出主线程：退出事件排在主队列里，只有关闭时的对账能看到它。
        for process in processes { kill(process.processIdentifier, SIGKILL) }
        let exitDeadline = Date().addingTimeInterval(2)
        while identities.contains(where: { $0.liveness != .exited }) && Date() < exitDeadline { usleep(1_000) }
        #expect(panes.allSatisfy { $0.displayedSessionKey != nil }, "退出通知还没处理")

        switch route {
        case .eachPane: panes.forEach { $0.terminal.requestClose() }
        case .tab: controller.closeTab(at: 0)
        case .tabScope: controller.closeTabs(mode: .this)
        case .clearTabs: controller.clearTabs()
        }
        #expect(controller.tabCount == 0)
        #expect(panes.allSatisfy { $0.displayedSessionKey == nil }, "关掉终端时就要对账，不等排队的退出通知")
    }
}

@Test func reusedPIDIsNotTheSameAgentInstance() throws {
    let current = try #require(AgentProcessIdentity.read(getpid()))
    let reused = AgentProcessIdentity(pid: current.pid, startedSeconds: current.startedSeconds - 1,
                                     startedMicroseconds: current.startedMicroseconds)
    #expect(current.liveness == .running)
    #expect(reused.liveness == .exited)
}
