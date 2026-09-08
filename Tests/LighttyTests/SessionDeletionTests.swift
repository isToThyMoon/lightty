import AppKit
import LighttyCore
import Testing
@testable import lightty

struct SessionDeletionTests {
    @MainActor @Test func confirmationUsesTransparentChildWindowNotSystemSheet() {
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let confirmation = SessionDeletionConfirmation()
        confirmation.messageText = "Delete?"
        confirmation.informativeText = "Fixture\n\nCannot be undone."
        confirmation.addButton(withTitle: "Cancel")
        confirmation.addButton(withTitle: "Delete")
        var cancelled = false
        confirmation.beginSheetModal(for: parent) { cancelled = $0 == .alertFirstButtonReturn }
        #expect(parent.attachedSheet == nil)
        #expect(parent.childWindows?.contains(where: { $0 is ShellMenuWindow && !$0.isOpaque }) == true)
        confirmation.buttons[0].performClick(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(cancelled)
        #expect(parent.childWindows?.isEmpty != false)
        cancelled = false
        confirmation.beginSheetModal(for: parent) { cancelled = $0 == .alertFirstButtonReturn }
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: parent)
        #expect(cancelled)
        #expect(parent.childWindows?.isEmpty != false)
        parent.orderOut(nil)
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
        try SessionDeletion.inspectClaudeProcesses(Data("42 claude\n".utf8), target: target, known: [42: other])
        #expect(throws: SessionDeletion.Failure.self) {
            try SessionDeletion.inspectClaudeProcesses(Data("42 claude\n".utf8), target: target, known: [42: target])
        }
        do {
            try SessionDeletion.inspectClaudeProcesses(Data("42 claude\n".utf8), target: target, known: [:])
            Issue.record("Unidentified Claude must not be treated as safe")
        } catch SessionDeletion.Failure.unknownOccupancy(let pid) { #expect(pid == 42) }
        let otherRoot = AgentSessionKey(agent: .claude, sourceRoot: "/other", nativeID: target.nativeID)
        try SessionDeletion.inspectClaudeProcesses(Data("42 /bin/claude\n".utf8), target: target, known: [42: otherRoot])
        try SessionDeletion.inspectClaudeProcesses(Data("42 /bin/zsh\n".utf8), target: target, known: [:])
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
        let source = SessionCatalogSource(agent: .codex, root: root, executable: executable)
        let provider = CodexSessionCatalog(source: source)
        #expect(try provider.sessions(archived: false, cancelled: { false }).count == 2)
        try SessionDeletion.delete(.init(agent: .codex, sourceRoot: root.path, nativeID: ids[0]), source: source)
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
        let source = SessionCatalogSource(agent: .claude, root: root, executable: "/missing/claude")
        let key = AgentSessionKey(agent: .claude, sourceRoot: root.path, nativeID: id)
        #expect(throws: SessionDeletion.Failure.self) {
            try SessionDeletion.delete(key, source: source, helperDirectory: helper,
                acceptingUnknownOccupancy: true,
                checkProcesses: { throw SessionDeletion.Failure.occupied })
        }
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent(id + ".jsonl").path))
        #expect(throws: SessionDeletion.Failure.self) {
            try SessionDeletion.delete(key, source: source, helperDirectory: helper,
                checkProcesses: { throw SessionDeletion.Failure.unknownOccupancy(42) })
        }
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent(id + ".jsonl").path))
        try SessionDeletion.delete(key, source: source, helperDirectory: helper,
            acceptingUnknownOccupancy: true,
            checkProcesses: { throw SessionDeletion.Failure.unknownOccupancy(42) })
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent(id + ".jsonl").path))
        #expect(!FileManager.default.fileExists(atPath: child.path))
        #expect(try Data(contentsOf: task) == Data("keep".utf8))
        let remaining = try ClaudeSessionCatalog(source: source, helperDirectory: helper)
            .sessions(archived: false, cancelled: { false })
        #expect(remaining.map(\.key.nativeID) == [otherID])
        #expect(throws: SessionDeletion.Failure.self) {
            try SessionDeletion.delete(key, source: source, helperDirectory: helper, checkProcesses: {})
        }
    }

    @Test func invalidDeletionIdentityFailsBeforeMutation() {
        let source = SessionCatalogSource(agent: .claude, root: URL(fileURLWithPath: "/fixture"), executable: "/missing")
        for id in ["../other", "--all", ""] {
            #expect(throws: SessionDeletion.Failure.self) {
                try SessionDeletion.delete(.init(agent: .claude, sourceRoot: source.root.path, nativeID: id), source: source)
            }
        }
        #expect(throws: SessionDeletion.Failure.self) {
            try SessionDeletion.delete(.init(agent: .claude, sourceRoot: "/other", nativeID: UUID().uuidString), source: source)
        }
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
