import AppKit
import LighttyCore
import Testing
@testable import lightty

/// 启动器的接口测试：请求进、结果出，占用检查经注入的 `FakeSessionProvider`，
/// 不弹任何模态框，不调用用户的 Agent（续接命令用 `/bin/echo`）。
@MainActor
private final class LauncherFixture {
    let root: URL
    let workdir: URL
    let provider: FakeSessionProvider
    let library: SessionLibrary
    let controller: TerminalWindowController
    private(set) var launcher: PaneLauncher!
    private let previous: AppState?

    init(occupancyQueue: DispatchQueue = .global(qos: .userInitiated)) throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-\(UUID().uuidString)")
        workdir = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        provider = FakeSessionProvider(agent: .claude, root: root.path, executable: "/bin/echo")
        library = SessionLibrary(fileURL: root.appendingPathComponent("organization.json"), providers: [provider])
        previous = AppState.shared
        AppState.shared = AppState(taskDirectory: root.appendingPathComponent("tasks"), sweepStalePanes: false,
                                   sessionLibrary: library)
        if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }
        controller = TerminalWindowController()
        AppState.shared.windowControllers = [controller]
        // 续接在检查占用之后还要确认宿主窗口仍在屏幕上。
        controller.window?.orderFront(nil)
        launcher = PaneLauncher(sessionLibrary: library, taskBindings: AppState.shared.taskBindings,
                                runningPanes: { AppState.shared.runningPanes() },
                                openWindow: { AppState.shared.newWindow(initialPane: $0) },
                                locateExecutable: { _ in "/bin/echo" },
                                occupancyQueue: occupancyQueue)
    }

    func session(_ id: String = "launcher-fixture", directory: String? = nil) -> AgentSession {
        AgentSession(key: .init(agent: .claude, sourceRoot: root.path, nativeID: id), title: "Fixture",
                     workingDirectory: directory ?? workdir.path, updatedAt: nil)
    }

    func resume(_ session: AgentSession, destination: TerminalLaunchDestination = .tab) -> TerminalLaunchRequest {
        .init(.resume(session, source: provider.source), destination: destination)
    }

    /// 等结果回到主线程。同步完成的请求第一拍就有结果。
    func outcome(of request: TerminalLaunchRequest, hosted: Bool = true) async throws -> TerminalLaunchOutcome {
        var result: TerminalLaunchOutcome?
        launcher.launch(request, in: hosted ? controller : nil) { result = $0 }
        let deadline = Date().addingTimeInterval(4)
        while result == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        return try #require(result)
    }

    func close() {
        for window in AppState.shared.windowControllers { window.window?.close() }
        AppState.shared.windowControllers = []
        AppState.shared = previous ?? AppState.shared
        try? FileManager.default.removeItem(at: root)
    }
}

extension SessionAssociationTests {
    @Test func launcherReportsAnOccupiedSessionWithoutCreatingATerminal() async throws {
        let f = try LauncherFixture()
        defer { f.close() }
        f.provider.occupancyResult = .inUse(pid: 4242)
        let session = f.session()
        let outcome = try await f.outcome(of: f.resume(session))
        guard case .notLaunched(.occupied(let pid)) = outcome else {
            Issue.record("expected occupied, got \(outcome)"); return
        }
        #expect(pid == 4242)
        #expect(f.provider.calls == [.occupancy(session.key)], "占用检查经注入的 provider")
        #expect(f.controller.tabCount == 1)
        #expect(!f.launcher.isStarting(session.key), "检查结束就释放合流")
    }

    @Test func launcherFocusesATerminalAlreadyRunningTheSession() async throws {
        let f = try LauncherFixture()
        defer { f.close() }
        let session = f.session()
        let existing = try #require(f.controller.activePane)
        existing.associateSession(.init(key: session.key, configuration: f.provider.source.configuration,
                                        workingDirectory: f.workdir.path))
        f.controller.addTab(initialPane: PaneView())
        let outcome = try await f.outcome(of: f.resume(session))
        guard case .focused(let pane) = outcome else { Issue.record("expected focus, got \(outcome)"); return }
        #expect(pane === existing)
        #expect(f.controller.activePane === existing)
        #expect(f.controller.tabCount == 2, "不新开")
        #expect(f.provider.calls.isEmpty, "本应用已开着就不必问外部占用")
    }

    @Test(arguments: TerminalLaunchDestination.allCases)
    func launcherResumesAnIdleSessionIntoTheRequestedDestination(destination: TerminalLaunchDestination) async throws {
        let f = try LauncherFixture()
        defer { f.close() }
        let session = f.session()
        var association: PaneSessionAssociation?
        var result: TerminalLaunchOutcome?
        f.launcher.launch(f.resume(session, destination: destination), in: f.controller) { outcome in
            // 在终端跑起命令之前读：/bin/echo 很快退出，关联随之解除。
            if case .launched(let pane) = outcome { association = pane.sessionAssociation }
            result = outcome
        }
        #expect(f.launcher.isStarting(session.key))
        let deadline = Date().addingTimeInterval(4)
        while result == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard case .launched(let pane) = try #require(result) else { Issue.record("expected launch"); return }
        #expect(association == .init(key: session.key, configuration: .custom(f.root.path),
                                     workingDirectory: f.workdir.path))
        #expect(pane.terminal.launchConfiguration.workingDirectory == f.workdir.path)
        #expect(pane.terminal.launchConfiguration.initialInput?.contains("'launcher-fixture'") == true)
        switch destination {
        case .split:
            #expect(f.controller.tabCount == 1)
            #expect(f.controller.panes().contains { $0 === pane })
        case .tab:
            #expect(f.controller.tabCount == 2)
            #expect(f.controller.activePane === pane)
        case .window:
            #expect(f.controller.tabCount == 1)
            #expect(AppState.shared.windowControllers.count == 2)
            #expect(AppState.shared.windowControllers.last?.panes().first === pane)
        }
    }

    @Test func launcherRefusesSameAgentLaunchesWhileADeletionIsInProgress() async throws {
        let f = try LauncherFixture()
        defer { f.close() }
        #expect(f.launcher.beginDeleting(.claude))
        #expect(!f.launcher.beginDeleting(.claude), "同一家同时只有一次删除")
        let task = BoundTask(fileURL: f.root.appendingPathComponent("task.md"), name: "Task")
        // 只拦可能碰到被删会话的启动：续接可能正是那一段，原生选择器里可能选中它。
        let refused: [TerminalLaunchRequest] = [
            f.resume(f.session()),
            .init(.sessionPicker(f.provider.source)),
        ]
        for request in refused {
            let outcome = try await f.outcome(of: request)
            guard case .notLaunched(.deletingSession(.claude)) = outcome else {
                Issue.record("expected deletion refusal, got \(outcome)"); continue
            }
        }
        #expect(f.controller.tabCount == 1)
        #expect(f.provider.calls.isEmpty)
        // 新会话（挂不挂任务都一样）生成的是另一段会话，不受影响；另一家、纯终端同理。
        // 不给宿主窗口，让它们越过删除互斥之后停在放置这一步——不在测试里真的敲 claude / codex。
        for request: TerminalLaunchRequest in [
            .init(.agent(.claudeCode), workingDirectory: f.workdir.path),
            .init(.agent(.claudeCode), workingDirectory: f.workdir.path, task: task),
            .init(.agent(.codex), workingDirectory: f.workdir.path),
            .init(.agent(.terminal), workingDirectory: f.workdir.path),
        ] {
            guard case .notLaunched(.noPlacement) = try await f.outcome(of: request, hosted: false) else {
                Issue.record("expected to pass the deletion check"); continue
            }
        }
        guard case .launched = try await f.outcome(of: .init(.agent(.terminal), workingDirectory: f.workdir.path)) else {
            Issue.record("a plain terminal still launches"); return
        }
        #expect(f.controller.tabCount == 2)
        f.launcher.endDeleting(.claude)
        guard case .launched = try await f.outcome(of: .init(.sessionPicker(f.provider.source))) else {
            Issue.record("deletion ended, picker should launch"); return
        }
    }

    @Test func launcherOpensTheNativePickerWithoutASessionIdentity() async throws {
        let f = try LauncherFixture()
        defer { f.close() }
        let outcome = try await f.outcome(of: .init(.sessionPicker(f.provider.source)))
        guard case .launched(let pane) = outcome else { Issue.record("expected launch, got \(outcome)"); return }
        let expected = try SessionPickerPlan(opening: f.provider.source, workingDirectory: NSHomeDirectory())
        #expect(pane.terminal.launchConfiguration.initialInput == expected.shellInput)
        #expect(pane.terminal.launchConfiguration.workingDirectory == NSHomeDirectory())
        #expect(pane.displayedSessionKey == nil, "选择器不指向任何会话")
        #expect(pane.snapshot().catalogSession == nil)
        #expect(f.controller.tabCount == 2)
    }

    @Test func launcherBindsTheRequestedTaskThroughTaskBindings() async throws {
        let f = try LauncherFixture()
        defer { f.close() }
        let created = try AppState.shared.taskBindings.createTask(name: "Launch task", workdir: f.workdir.path)
        let task = BoundTask(fileURL: created.fileURL, name: created.task.name)
        let outcome = try await f.outcome(of: .init(.agent(.terminal), workingDirectory: f.workdir.path,
                                                    task: task, destination: .split))
        guard case .launched(let pane) = outcome else { Issue.record("expected launch, got \(outcome)"); return }
        #expect(AppState.shared.taskBindings.task(for: pane.dragIdentifier) == task)
        #expect(AppState.shared.taskBindings.panes(for: created.fileURL) == [pane.dragIdentifier])
        #expect(pane.header.titleOfBoundTask == task.name, "终端经绑定变更刷新 header")
        #expect(pane.terminal.launchConfiguration.workingDirectory == f.workdir.path)
        #expect(pane.displayedSessionKey == nil, "任务绑定不带出会话关联")
    }

    @Test func launcherRestoresASnapshotAsUnavailableWhenItsCLIIsMissing() throws {
        let f = try LauncherFixture()
        defer { f.close() }
        let key = f.session().key
        let snapshot = PaneSnapshot(name: "Restored name", agentCWD: f.workdir.path, agentAlive: true,
                                    catalogSession: key, catalogConfiguration: .custom(f.root.path))
        let missing = PaneLauncher(sessionLibrary: f.library, taskBindings: AppState.shared.taskBindings,
                                   runningPanes: { [] }, openWindow: { _ in }, locateExecutable: { _ in nil })
        let pane = missing.restoredPane(from: snapshot)
        let association = PaneSessionAssociation(key: key, configuration: .custom(f.root.path),
                                                 workingDirectory: f.workdir.path)
        #expect(pane.sessionState.binding == .unavailable(association))
        #expect(pane.displayedSessionKey == nil, "无法恢复不算已打开")
        #expect(pane.terminal.launchConfiguration.initialInput == nil)
        #expect(pane.snapshot().catalogSession == key, "恢复意图保留")
        #expect(pane.snapshot().name == "Restored name")

        let available = f.launcher.restoredPane(from: snapshot)
        #expect(available.sessionState.binding == .restoring(association))
        #expect(available.terminal.launchConfiguration.initialInput?.contains("/bin/echo") == true)
    }

    /// 以前这段紧跟着模态框，测不了：目录缺失时先问目录，重新请求才检查占用；
    /// 检查进行中同一会话的第二次请求合流掉。
    @Test func launcherAsksForAFolderThenCoalescesRepeatedResumes() async throws {
        let queue = DispatchQueue(label: "launcher-occupancy")
        let f = try LauncherFixture(occupancyQueue: queue)
        defer { f.close() }
        let missing = f.session(directory: f.root.appendingPathComponent("gone").path)
        guard case .notLaunched(.needsWorkingDirectory(let message)) = try await f.outcome(of: f.resume(missing)) else {
            Issue.record("expected a folder prompt"); return
        }
        #expect(message == PaneLauncher.folderPromptMessage(for: missing.workingDirectory))
        let unrecorded = AgentSession(key: missing.key, title: "Fixture", workingDirectory: nil, updatedAt: nil)
        guard case .notLaunched(.needsWorkingDirectory) = try await f.outcome(of: f.resume(unrecorded)) else {
            Issue.record("an unrecorded folder also needs a choice"); return
        }
        #expect(f.provider.calls.isEmpty, "选目录之前不检查占用")

        queue.suspend()
        var chosen = f.resume(missing)
        chosen.workingDirectory = f.workdir.path
        var first: TerminalLaunchOutcome?
        f.launcher.launch(chosen, in: f.controller) { first = $0 }
        #expect(f.launcher.isStarting(missing.key))
        guard case .notLaunched(.alreadyStarting) = try await f.outcome(of: chosen) else {
            Issue.record("a second request during the check must coalesce"); queue.resume(); return
        }
        queue.resume()
        let deadline = Date().addingTimeInterval(4)
        while first == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard case .launched(let pane) = try #require(first) else { Issue.record("expected launch"); return }
        #expect(pane.terminal.launchConfiguration.workingDirectory == f.workdir.path)
        #expect(f.controller.tabCount == 2)
    }
}
