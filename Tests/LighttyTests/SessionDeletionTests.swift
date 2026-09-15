import AppKit
import LighttyCore
import Testing
@testable import lightty

struct SessionDeletionTests {
    /// 删除确认的每一条取消路径都回调 cancelled 并收走子窗口：点 Cancel、按回车、父窗口关闭。
    /// 回车走窗口的响应链（与 Escape 对称），不靠按钮的 AppKit keyEquivalent——
    /// 那是窗口级快捷键，会抢在 surface 之前吃掉用户配的 Ghostty 绑定。
    @MainActor @Test func deletionConfirmationCancelsOnButtonReturnAndParentClose() throws {
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { parent.orderOut(nil) }
        let confirmation = SessionDeletionConfirmation()
        confirmation.messageText = "Delete?"
        confirmation.informativeText = "Fixture\n\nCannot be undone."
        confirmation.addButton(withTitle: "Cancel")
        confirmation.addButton(withTitle: "Delete")
        var cancelled = false

        // 点 Cancel：回调同步送达
        confirmation.beginSheetModal(for: parent) { cancelled = $0 == .alertFirstButtonReturn }
        confirmation.buttons[0].performClick(nil)
        #expect(cancelled)
        #expect(parent.childWindows?.isEmpty != false)

        // 按回车：没有 keyEquivalent，走面板的 keyDown
        cancelled = false
        confirmation.beginSheetModal(for: parent) { cancelled = $0 == .alertFirstButtonReturn }
        for button in confirmation.buttons { #expect(button.keyEquivalent.isEmpty) }
        let panel = try #require(parent.childWindows?.compactMap { $0 as? ShellMenuWindow }.first)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        panel.keyDown(with: event)
        #expect(cancelled)
        #expect(parent.childWindows?.isEmpty != false)

        // 父窗口关闭也算取消
        cancelled = false
        confirmation.beginSheetModal(for: parent) { cancelled = $0 == .alertFirstButtonReturn }
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: parent)
        #expect(cancelled)
        #expect(parent.childWindows?.isEmpty != false)
    }

    @MainActor @Test func unknownUsageOffersCancelBeforePermanentOverride() {
        let session = AgentSession(key: .init(agent: .claude, sourceRoot: "/fixture", nativeID: UUID().uuidString),
                                   title: "Fixture", workingDirectory: nil, updatedAt: nil)
        let alert = SessionDeletion.unknownOccupancyAlert(session: session, pid: 42)
        #expect(alert.buttons.map(\.title) == [L("Cancel"), L("Permanently delete anyway")])
        #expect(!alert.informativeText.contains("PID:"))
        #expect(alert.informativeText.contains(session.title))
    }
    @Test func unrelatedClaudeDoesNotBlockDeletion() throws {
        let target = AgentSessionKey(agent: .claude, sourceRoot: "/fixture", nativeID: UUID().uuidString)
        let other = AgentSessionKey(agent: .claude, sourceRoot: "/fixture", nativeID: UUID().uuidString)
        try ClaudeSessionProvider.inspectProcesses(Data("42 claude\n".utf8), target: target, known: [42: other])
        #expect(throws: SessionDeletion.Failure.self) {
            try ClaudeSessionProvider.inspectProcesses(Data("42 claude\n".utf8), target: target, known: [42: target])
        }
        do {
            try ClaudeSessionProvider.inspectProcesses(Data("42 claude\n".utf8), target: target, known: [:])
            Issue.record("Unidentified Claude must not be treated as safe")
        } catch SessionDeletion.Failure.unknownOccupancy(let pid) { #expect(pid == 42) }
        let otherRoot = AgentSessionKey(agent: .claude, sourceRoot: "/other", nativeID: target.nativeID)
        try ClaudeSessionProvider.inspectProcesses(Data("42 /bin/claude\n".utf8), target: target, known: [42: otherRoot])
        try ClaudeSessionProvider.inspectProcesses(Data("42 /bin/zsh\n".utf8), target: target, known: [:])
    }

    // MARK: 刚启动的 claude 的登记窗口

    /// 编排好的删除核查环境：进程表固定，活会话表按次序返回，时钟固定，等待只记账。
    private final class ProbeScript {
        static let now = Date(timeIntervalSince1970: 1_000_000)
        let target = AgentSessionKey(agent: .claude, sourceRoot: "/fixture", nativeID: UUID().uuidString)
        var processTable: Data? = Data("42 claude\n".utf8)
        var liveTables: [[ClaudeSessionProvider.LiveSession]?] = []
        var starts: [Int32: TimeInterval] = [:]
        private(set) var liveReads = 0
        private(set) var waits: [TimeInterval] = []

        func start(_ pid: Int32, secondsAgo: TimeInterval) {
            starts[pid] = Self.now.timeIntervalSince1970 - secondsAgo
        }
        func row(_ pid: Int32, _ id: String) -> ClaudeSessionProvider.LiveSession {
            .init(pid: pid, sessionID: id, cwd: nil)
        }
        var probe: ClaudeSessionProvider.DeletionProbe {
            .init(processTable: { self.processTable },
                  liveSessions: {
                      defer { self.liveReads += 1 }
                      return self.liveReads < self.liveTables.count ? self.liveTables[self.liveReads] : nil
                  },
                  identity: { pid in
                      self.starts[pid].map { start in
                          AgentProcessIdentity(pid: pid, startedSeconds: UInt64(start.rounded(.down)),
                              startedMicroseconds: UInt64((start - start.rounded(.down)) * 1_000_000))
                      }
                  },
                  now: { Self.now },
                  wait: { self.waits.append($0) })
        }
        func check() throws {
            try ClaudeSessionProvider.checkDeletable(target, known: [:], probe: probe)
        }
    }

    @Test func youngClaudeThatRegistersOnTheSecondLookIsDeletable() throws {
        let script = ProbeScript()
        script.start(42, secondsAgo: 1)
        script.liveTables = [[], [script.row(42, UUID().uuidString)]]
        try script.check()
        #expect(script.waits == [ClaudeSessionProvider.registrationWait])
        #expect(script.liveReads == 2)
    }

    @Test func youngClaudeStillUnregisteredAfterTheWaitIsUnknown() {
        let script = ProbeScript()
        script.start(42, secondsAgo: 1)
        script.liveTables = [[], []]
        do {
            try script.check()
            Issue.record("A still-unregistered Claude must not be treated as idle")
        } catch SessionDeletion.Failure.unknownOccupancy(let pid) { #expect(pid == 42) }
        catch { Issue.record("Unexpected \(error)") }
        // 只重读一次，不轮询。
        #expect(script.waits.count == 1)
        #expect(script.liveReads == 2)
    }

    @Test func oldUnregisteredClaudeIsUnknownWithoutWaiting() {
        let script = ProbeScript()
        script.start(42, secondsAgo: ClaudeSessionProvider.registrationWindow + 1)
        script.liveTables = [[], [script.row(42, UUID().uuidString)]]
        do {
            try script.check()
            Issue.record("An old unregistered Claude must stay unknown")
        } catch SessionDeletion.Failure.unknownOccupancy(let pid) { #expect(pid == 42) }
        catch { Issue.record("Unexpected \(error)") }
        #expect(script.waits.isEmpty)
        #expect(script.liveReads == 1)
    }

    /// 一个老的身份不明就已经注定要问用户，不值得为同时在场的年轻进程再等。
    /// 老的身份不明进程让结论注定是「说不清」，但仍要等年轻的登记：用户随后点「仍然删除」
    /// 只压身份不明，若年轻的那个跑的正是目标，必须以确认占用拒绝，而不是被一并压掉。
    @Test func oldUnregisteredClaudeStillWaitsForYoungOnesAndStaysUnknown() {
        let script = ProbeScript()
        script.processTable = Data("42 claude\n43 claude\n".utf8)
        script.start(42, secondsAgo: 1)
        script.start(43, secondsAgo: 600)
        script.liveTables = [[], [script.row(42, UUID().uuidString)]]
        do {
            try script.check()
            Issue.record("An old unidentified Claude keeps the verdict unknown")
        } catch SessionDeletion.Failure.unknownOccupancy(let pid) { #expect(pid == 43) }
        catch { Issue.record("Unexpected \(error)") }
        #expect(script.waits.count == 1)
    }

    /// 同意「仍然删除」只压身份不明；等出来的确认占用照样拒绝、provider 也不被调 delete。
    /// 两个场景：只有一个年轻进程在等待期间登记为目标；年轻的目标旁边还有一个老的身份不明
    ///（老的注定要问用户，但年轻那个若跑的正是目标，必须以确认占用拒绝，不能被一并压掉）。
    @Test func consentOverridesUnknownButNeverAConfirmedOccupant() {
        let cases: [(name: String, processTable: String, oldUnknown: Int32?)] = [
            ("young target registered during the wait", "42 claude\n", nil),
            ("young target beside an old unknown claude", "42 claude\n43 claude\n", 43),
        ]
        for c in cases {
            let script = ProbeScript()
            script.processTable = Data(c.processTable.utf8)
            script.start(42, secondsAgo: 1)
            if let old = c.oldUnknown { script.start(old, secondsAgo: 600) }
            script.liveTables = [[], [script.row(42, script.target.nativeID)]]
            let provider = FakeSessionProvider(root: "/fixture")
            let adapter = DeletionCheckOverride(base: provider, check: { try script.check() })
            let key = AgentSessionKey(agent: .claude, sourceRoot: "/fixture", nativeID: script.target.nativeID)
            do {
                try SessionDeletion.delete(key, provider: adapter, acceptingUnknownOccupancy: true)
                Issue.record("\(c.name): A young Claude running the target must block deletion despite consent")
            } catch SessionDeletion.Failure.occupiedProcess(let pid) { #expect(pid == 42, "\(c.name)") }
            catch { Issue.record("\(c.name): Unexpected \(error)") }
            #expect(!provider.calls.contains(.delete(key)), "\(c.name)")
        }
    }

    @Test func youngClaudeThatRegistersTheTargetIsOccupied() {
        let script = ProbeScript()
        script.start(42, secondsAgo: 1)
        script.liveTables = [[], [script.row(42, script.target.nativeID)]]
        do {
            try script.check()
            Issue.record("A Claude that turns out to run the target must block deletion")
        } catch SessionDeletion.Failure.occupiedProcess(let pid) { #expect(pid == 42) }
        catch { Issue.record("Unexpected \(error)") }
    }

    /// 活会话表读不到就是「说不清」，不能变成空闲——第一眼读不到不等直接抛；
    /// 第一眼空、等完第二眼读不到，也抛，且只读了两次。
    @Test(arguments: [1, 2])
    func unreadableLiveTableIsUnknown(failingLook: Int) {
        let script = ProbeScript()
        script.start(42, secondsAgo: 1)
        script.liveTables = failingLook == 1 ? [nil, [script.row(42, UUID().uuidString)]] : [[], nil]
        do {
            try script.check()
            Issue.record("An unreadable live table must not become idle")
        } catch SessionDeletion.Failure.unknownOccupancy(let pid) { #expect(pid == 42) }
        catch { Issue.record("Unexpected \(error)") }
        #expect(script.waits.count == failingLook - 1, "第一眼读不到不等；第二眼是等完才读的")
        #expect(script.liveReads == failingLook)
    }

    /// 等的这一会儿里 PID 被别的进程复用，新进程的登记不能算到原来那个头上。
    @Test func pidReusedDuringTheWaitStaysUnknown() {
        let script = ProbeScript()
        script.start(42, secondsAgo: 1)
        let probe = script.probe
        var reused = probe
        var looks = 0
        reused.identity = { pid in
            looks += 1
            return looks == 1 ? probe.identity(pid)
                : AgentProcessIdentity(pid: pid, startedSeconds: 1_000_000, startedMicroseconds: 500_000)
        }
        script.liveTables = [[], [script.row(42, UUID().uuidString)]]
        #expect(throws: SessionDeletion.Failure.self) {
            try ClaudeSessionProvider.checkDeletable(script.target, known: [:], probe: reused)
        }
    }

    @Test func unreadableProcessTableIsUnknownWithoutAskingTheLiveTable() {
        let script = ProbeScript()
        script.processTable = nil
        #expect(throws: SessionDeletion.Failure.self) { try script.check() }
        #expect(script.liveReads == 0)
    }
    @Test func codexNativeDeletionUpdatesCatalog() throws {
        let executable = try #require(HookInstaller.locateExecutable("codex"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-delete-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("sessions/2026/09/08")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ids = [UUID().uuidString.lowercased(), UUID().uuidString.lowercased()]
        for id in ids {
            let rows: [[String: Any]] = [
                ["timestamp": "2026-09-08T00:00:00Z", "type": "session_meta", "payload": [
                    "id": id, "timestamp": "2026-09-08T00:00:00Z", "cwd": root.path,
                    "originator": "lightty-test", "cli_version": "0.153.4", "source": "cli", "model_provider": "openai"]],
                ["timestamp": "2026-09-08T00:00:01Z", "type": "event_msg", "payload": [
                    "type": "user_message", "message": "Deletion fixture", "images": []]]]
            let data = try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
                .joined(separator: "\n") + "\n"
            try data.write(to: directory.appendingPathComponent("rollout-2026-09-08T00-00-00-\(id).jsonl"),
                atomically: true, encoding: .utf8)
        }
        let source = SessionCatalogSource(agent: .codex, root: root, executable: executable,
                                          configuration: .custom(root.path))
        let provider = CodexSessionProvider(source: source)
        #expect(try provider.sessions(archived: false, cancelled: { false }).count == 2)
        try SessionDeletion.delete(.init(agent: .codex, sourceRoot: root.path, nativeID: ids[0]), provider: provider)
        #expect(try provider.sessions(archived: false, cancelled: { false }).map(\.key.nativeID) == [ids[1]])
    }

    private var helper: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/claude-session-helper")
    }

    @Test func claudeNativeDeletionPreservesOtherSessionsAndTasks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("delete-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("projects/project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let otherID = UUID().uuidString.lowercased()
        for value in [id, otherID] {
            let row: [String: Any] = ["type": "user", "sessionId": value, "uuid": UUID().uuidString,
                "parentUuid": NSNull(), "isSidechain": false, "cwd": root.path,
                "timestamp": "2026-09-08T00:00:00Z", "entrypoint": "cli",
                "message": ["role": "user", "content": "Deletion fixture"]]
            try JSONSerialization.data(withJSONObject: row).write(to: project.appendingPathComponent(value + ".jsonl"))
        }
        let child = project.appendingPathComponent(id + "/subagents")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data("child".utf8).write(to: child.appendingPathComponent("agent-fixture.jsonl"))
        let task = root.appendingPathComponent("task.md")
        try Data("keep".utf8).write(to: task)
        let source = SessionCatalogSource(agent: .claude, root: root, executable: "/missing/claude",
                                          configuration: .custom(root.path))
        let adapter = ClaudeSessionProvider(source: source, helperDirectory: helper)
        let key = AgentSessionKey(agent: .claude, sourceRoot: root.path, nativeID: id)
        #expect(throws: SessionDeletion.Failure.self) {
            try SessionDeletion.delete(key, provider: DeletionCheckOverride(base: adapter,
                check: { throw SessionDeletion.Failure.occupied }), acceptingUnknownOccupancy: true)
        }
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent(id + ".jsonl").path))
        let unknown = DeletionCheckOverride(base: adapter, check: { throw SessionDeletion.Failure.unknownOccupancy(42) })
        #expect(throws: SessionDeletion.Failure.self) {
            try SessionDeletion.delete(key, provider: unknown)
        }
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent(id + ".jsonl").path))
        try SessionDeletion.delete(key, provider: unknown, acceptingUnknownOccupancy: true)
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent(id + ".jsonl").path))
        #expect(!FileManager.default.fileExists(atPath: child.path))
        #expect(try Data(contentsOf: task) == Data("keep".utf8))
        let remaining = try ClaudeSessionProvider(source: source, helperDirectory: helper)
            .sessions(archived: false, cancelled: { false })
        #expect(remaining.map(\.key.nativeID) == [otherID])
        #expect(throws: SessionDeletion.Failure.self) {
            try SessionDeletion.delete(key, provider: DeletionCheckOverride(base: adapter, check: {}))
        }
    }

    @Test func invalidDeletionIdentityFailsBeforeMutation() {
        let provider = FakeSessionProvider(agent: .claude, root: "/fixture")
        for id in ["../other", "--all", ""] {
            #expect(throws: SessionDeletion.Failure.self) {
                try SessionDeletion.delete(.init(agent: .claude, sourceRoot: provider.source.root.path, nativeID: id),
                                           provider: provider)
            }
        }
        #expect(throws: SessionDeletion.Failure.self) {
            try SessionDeletion.delete(.init(agent: .claude, sourceRoot: "/other", nativeID: UUID().uuidString),
                                       provider: provider)
        }
        #expect(provider.calls.isEmpty, "Identity mismatch must not reach the provider")
    }

    @Test func organizationForgetsOnlyDeletedKeys() {
        var state = SessionOrganization()
        let key = AgentSessionKey(agent: .claude, sourceRoot: "/fixture", nativeID: UUID().uuidString)
        let other = AgentSessionKey(agent: .codex, sourceRoot: "/fixture", nativeID: key.nativeID)
        let session = AgentSession(key: key, title: "", workingDirectory: nil, updatedAt: nil)
        let project = SessionProject(name: "Keep project")
        state.projects = [project]
        state.assign(key, to: project.id)
        state.assign(other, to: project.id)
        state.setArchived(true, session: session)
        state.forgetSessions([key])
        #expect(state.assignments.map(\.session) == [other])
        #expect(state.archivedSessions.isEmpty)
        #expect(state.projects == [project])
    }
}
