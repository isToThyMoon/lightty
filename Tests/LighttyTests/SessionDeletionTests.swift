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
    // MARK: 删除前的核查

    /// Claude 的删除核查只认两处正面证据：它自己的活会话表，和本应用 pane 核对过的进程身份。
    /// 表问不出来是「说不清」，不是「没人用」。
    ///
    /// 进程表核查（`ps` 认 claude 进程 + `lsof` 看谁写着转录文件）已删掉：进程名随安装方式变
    /// （原生是版本号、npm 是 `claude.exe`），认错一个就把「有人在用」读成「没人用」。
    /// 代价是刚起来还没登记进表的外部 claude 查不出来，接受。
    @Test func deletionChecksOnlyTheLiveTableAndPanesThisAppVerified() throws {
        let target = AgentSessionKey(agent: .claude, sourceRoot: "/fixture", nativeID: UUID().uuidString)
        let other = AgentSessionKey(agent: .claude, sourceRoot: "/fixture", nativeID: UUID().uuidString)
        // 原生 ID 一样但配置根不同的是另一段会话。
        let otherRoot = AgentSessionKey(agent: .claude, sourceRoot: "/other", nativeID: target.nativeID)
        // 本进程的身份是真的，核对得上；改掉启动时刻就成了「这个 pid 已经换了人」。
        let pane = try #require(AgentProcessIdentity.read(ProcessInfo.processInfo.processIdentifier))
        let reused = AgentProcessIdentity(pid: pane.pid, startedSeconds: pane.startedSeconds + 1,
                                          startedMicroseconds: pane.startedMicroseconds)
        func row(_ pid: Int32, _ key: AgentSessionKey) -> ClaudeSessionProvider.LiveSession {
            .init(pid: pid, sessionID: key.nativeID, cwd: nil)
        }
        enum Verdict: Equatable { case deletable, occupied(Int32), unknown }
        let cases: [(name: String, table: [ClaudeSessionProvider.LiveSession]?,
                     known: [AgentProcessIdentity: AgentSessionKey], expected: Verdict)] = [
            ("live table unreadable", nil, [:], .unknown),
            ("live table runs the target", [row(42, target)], [:], .occupied(42)),
            ("live table runs only other sessions", [row(42, other)], [:], .deletable),
            ("empty live table", [], [:], .deletable),
            ("a pane of this app runs the target", [], [pane: target], .occupied(pane.pid)),
            ("a pane of this app runs another session", [], [pane: other], .deletable),
            ("same native id under another configuration root", [], [pane: otherRoot], .deletable),
            ("the pid a pane recorded has been reused", [], [reused: target], .deletable),
        ]
        for c in cases {
            var verdict = Verdict.deletable
            do {
                try ClaudeSessionProvider.checkDeletable(target, known: c.known,
                    probe: .init(liveSessions: { c.table }))
            } catch SessionDeletion.Failure.occupiedProcess(let pid) { verdict = .occupied(pid) }
            catch SessionDeletion.Failure.unknownOccupancy { verdict = .unknown }
            #expect(verdict == c.expected, "\(c.name)")
        }
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
