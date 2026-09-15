import AppKit
import LighttyCore
import Testing
@testable import lightty

@Suite(.serialized)
@MainActor
struct SessionAssociationTests {

@Test(arguments: SessionAgent.allCases)
func sessionTitleIsDerivedWithoutOverwritingTerminalName(agent: SessionAgent) async throws {
    _ = NSApplication.shared
    ensureTerminalRuntime()
        let f = try SessionModelFixture(agent: agent)
        defer { f.close() }
        let key = f.record().key
        let snapshot = PaneSnapshot(name: "My terminal", agentCWD: f.root.path, agentAlive: true,
                                    catalogSession: key, catalogConfiguration: .custom(f.root.path))
        let pane = restoredPane(from: snapshot, sessionLibrary: f.library, locateExecutable: { _ in "/bin/echo" })
        func record(_ title: String) -> AgentSession {
            .init(key: key, title: title, workingDirectory: f.root.path, updatedAt: nil)
        }
        try await f.load([record("Conversation")])
        #expect(pane.header.title == "Conversation")
        #expect(pane.header.sessionAgent == agent)
        #expect(AgentSessionIcon.image(for: agent)?.isValid == true)
        #expect(pane.snapshot().name == "My terminal")
        try await f.load([record("Renamed conversation")])
        #expect(pane.header.title == "Renamed conversation")
        try await f.load([record("  ")])
        #expect(pane.header.title == "My terminal")
        let restored = restoredPane(from: pane.snapshot(), sessionLibrary: f.library, locateExecutable: { _ in "/bin/echo" })
        try await f.load([record("Conversation")])
        #expect(restored.header.title == "Conversation")
        let unavailable = restoredPane(from: snapshot, sessionLibrary: f.library, locateExecutable: { _ in nil })
        #expect(unavailable.header.title == "My terminal")
        #expect(unavailable.header.sessionAgent == nil)
}

@MainActor
@Test func catalogAssociationSurvivesRepeatedRestartsWithoutHooks() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let previous = AppState.shared
    defer { AppState.shared = previous ?? AppState.shared; try? FileManager.default.removeItem(at: root) }
    AppState.shared = AppState(taskDirectory: root, sweepStalePanes: false)
    ensureTerminalRuntime()
    let task = try AppState.shared.taskBindings.store.create(name: "Independent task", workdir: root.path)
    for agent in SessionAgent.allCases {
        let key = AgentSessionKey(agent: agent,
            sourceRoot: SessionConfigurationLocation.standard.root(for: agent,
                home: FileManager.default.homeDirectoryForCurrentUser).path, nativeID: "restart-fixture")
        let pane = PaneView()
        pane.associateSession(.init(key: key, configuration: .standard, workingDirectory: root.path))
        pane.bind(to: task.fileURL, name: task.task.name)
        var snapshot = pane.snapshot()
        for _ in 0..<3 {
            let store = WorkspaceStore(fileURL: root.appendingPathComponent("workspace.json"))
            store.freeze(with: .init(windows: [.init(activeTabIndex: 0,
                tabs: [.init(title: "Fixture", root: .pane(snapshot))],
                taskPanelOpen: true, tabSidebarOpen: true)]))
            snapshot = try #require(store.load()?.windows.first?.tabs.first?.root.firstLeaf)
            #expect(snapshot.catalogSession == key)
            #expect(snapshot.agentAlive)
            let restored = restoredPane(from: snapshot, locateExecutable: { _ in "/bin/echo" })
            #expect(restored.displayedSessionKey == key)
            #expect(restored.terminal.launchConfiguration.initialInput?.contains("'restart-fixture'") == true)
            #expect(restored.taskFileURL == task.fileURL)
            snapshot = restored.snapshot()
            restored.unbind()
            #expect(restored.displayedSessionKey == key, "Removing a task must not detach the conversation")
        }
    }
}

@MainActor
@Test func ordinaryHookLaunchSurvivesDiskAndReconstruction() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let previous = AppState.shared
    AppState.shared = AppState(taskDirectory: root, sweepStalePanes: false)
    defer { AppState.shared = previous ?? AppState.shared }
    defer { try? FileManager.default.removeItem(at: root) }
    let store = PaneStatusStore(socketPath: URL(fileURLWithPath: "/tmp/lt-\(UUID().uuidString).sock"))
    #expect(store.start())
    defer { store.stop() }
    for agent in SessionAgent.allCases {
        // Explicit default-looking Claude paths must remain explicit, too.
        let location = SessionConfigurationLocation.custom(root.path)
        let key = AgentSessionKey(agent: agent, sourceRoot: root.path, nativeID: "ordinary-launch")
        let catalog = SessionModelCatalog(root: root, agent: agent)
        let library = SessionLibrary(fileURL: root.appendingPathComponent("catalog.json"), providers: [catalog], statusStore: store)
        let pane = PaneView(sessionLibrary: library)
        let status = PaneStatus(ts: Date(), state: .idle, agent: agent.rawValue,
            sessionID: key.nativeID, sourceRoot: root.path, sourceConfiguration: location,
            cwd: root.path, event: "SessionStart")
        _ = PaneStatusDatagram(pane: pane.dragIdentifier, status: status).send(to: store.socketPath)
        try await awaitUntil("SessionStart delivered") { store.status(for: pane.dragIdentifier) != nil }
        #expect(pane.displayedSessionKey == key)
        let terminalName = pane.snapshot().name
        let records = [AgentSession(key: key, title: "Live conversation", workingDirectory: root.path, updatedAt: nil)]
        catalog.records = records
        library.refresh()
        try await awaitUntil("catalog title reaches the pane") { pane.header.title == "Live conversation" }
        let disk = WorkspaceStore(fileURL: root.appendingPathComponent("workspace.json"))
        disk.freeze(with: .init(windows: [.init(activeTabIndex: 0,
            tabs: [.init(title: "Hook", root: .pane(pane.snapshot()))],
            taskPanelOpen: true, tabSidebarOpen: true)]))
        let saved = try #require(disk.load()?.windows.first?.tabs.first?.root.firstLeaf)
        let restored = restoredPane(from: saved, locateExecutable: { _ in "/bin/echo" })
        #expect(restored.displayedSessionKey == key)
        #expect(restored.snapshot().catalogConfiguration == location)
        #expect(restored.terminal.launchConfiguration.initialInput?.contains(agent.configurationVariable + "=" + root.path) == true)
        let end = PaneStatus(ts: Date(), state: .idle, agent: agent.rawValue, sessionID: key.nativeID,
                             sourceRoot: root.path, event: "SessionEnd")
        _ = PaneStatusDatagram(pane: pane.dragIdentifier, status: end).send(to: store.socketPath)
        try await awaitUntil("SessionEnd delivered") { store.status(for: pane.dragIdentifier)?.event == "SessionEnd" }
        #expect(pane.displayedSessionKey == nil)
        await awaitMainQueue(hops: 2)  // 会话库通知一拍，头部重算再一拍
        #expect(pane.header.title == terminalName)
        #expect(pane.header.sessionAgent == nil)
        #expect(!pane.snapshot().agentAlive)
    }
}

@MainActor
@Test func unavailableRestoreKeepsIdentityWithoutClaimingAnOpenAgent() throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let key = AgentSessionKey(agent: .codex, sourceRoot: home.appendingPathComponent(".codex").path, nativeID: "missing-cli")
    let snapshot = PaneSnapshot(name: "Unavailable", agentCWD: home.path, agentAlive: true,
                                catalogSession: key, catalogConfiguration: .standard)
    let f = try SessionModelFixture()
    defer { f.close() }
    let pane = restoredPane(from: snapshot, sessionLibrary: f.library, locateExecutable: { _ in nil })
    #expect(pane.displayedSessionKey == nil)
    #expect(pane.terminal.launchConfiguration.initialInput == nil)
    #expect(pane.snapshot().catalogSession == key)
}

@Test func closingLastWindowFreezesBothSessionAndTaskAssociations() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let previous = AppState.shared
    AppState.shared = AppState(taskDirectory: root, sweepStalePanes: false)
    defer { AppState.shared = previous ?? AppState.shared; try? FileManager.default.removeItem(at: root) }
    ensureTerminalRuntime()
    let task = try AppState.shared.taskBindings.store.create(name: "Shared task", workdir: root.path)
    let controller = TerminalWindowController()
    AppState.shared.windowControllers = [controller]
    let first = try #require(controller.activePane)
    let second = PaneView()
    controller.addTab(initialPane: second)
    let home = FileManager.default.homeDirectoryForCurrentUser
    let keys = SessionAgent.allCases.map {
        AgentSessionKey(agent: $0, sourceRoot: SessionConfigurationLocation.standard.root(for: $0, home: home).path,
                        nativeID: "close-window-\($0.rawValue)")
    }
    for (pane, key) in zip([first, second], keys) {
        pane.associateSession(.init(key: key, configuration: .standard, workingDirectory: root.path))
        pane.bind(to: task.fileURL, name: task.task.name)
    }
    // Uses the actual windowWillClose -> freeze path, not just PaneSnapshot Codable.
    controller.window?.close()
    #expect(AppState.shared.windowControllers.isEmpty)
    let saved = try #require(WorkspaceStore.shared.load()?.windows.first)
    #expect(saved.tabs.flatMap { $0.root.leaves.compactMap(\.catalogSession) } == keys)
    #expect(saved.tabs.flatMap { $0.root.leaves.compactMap(\.taskFile) } == [task.fileURL.path, task.fileURL.path])
    for (snapshot, key) in zip(saved.tabs.flatMap { $0.root.leaves }, keys) {
        let pane = restoredPane(from: snapshot, locateExecutable: { _ in "/bin/echo" })
        #expect(pane.displayedSessionKey == key)
        #expect(pane.taskFileURL == task.fileURL)
        #expect(pane.terminal.launchConfiguration.initialInput?.contains(key.nativeID) == true)
    }
}
}
