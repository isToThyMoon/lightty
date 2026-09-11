import AppKit
import LighttyCore
import Testing
@testable import lightty

extension SessionAssociationTests {
    @Test func readingAttentionKeepsItsTextUntilTheAgentResumes() async throws {
        _ = NSApplication.shared
        if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }
        let f = try SessionModelFixture()
        let previous = AppState.shared
        AppState.shared = AppState(taskDirectory: f.root, sweepStalePanes: false, sessionLibrary: f.library)
        defer { AppState.shared.windowControllers = []; AppState.shared = previous ?? AppState.shared; f.close() }
        let pane = PaneView(sessionLibrary: f.library)
        let controller = TerminalWindowController(initialPane: pane)
        AppState.shared.windowControllers = [controller]
        defer { controller.window?.close() }
        let host = try #require(controller.window?.contentView)
        func mountSidebar() -> TabColumnView {
            let tabs = TabColumnView()
            host.addSubview(tabs)
            tabs.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
            tabs.layoutSubtreeIfNeeded()
            return tabs
        }
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        func label(in tabs: TabColumnView) -> PaneStatusLabel? {
            descendants(tabs).compactMap { $0 as? PaneStatusLabel }.first
        }
        var tabs = mountSidebar()
        let record = f.record()
        pane.associateSession(f.association(record))
        pane.focusTerminal()
        try await f.status(.attention, event: "PermissionRequest", pane: pane.dragIdentifier, record: record)
        try await f.wait { label(in: tabs)?.stringValue == L("Needs you") }
        let original = try #require(label(in: tabs))
        #expect(pane.sessionState.isUnread)
        #expect(f.statuses.unreadActivity(for: pane.dragIdentifier) == .attention)
        pane.focusTerminal()
        try await f.wait { !pane.sessionState.isUnread }
        #expect(pane.sessionState.status?.state == .attention)
        #expect(f.statuses.unreadActivity(for: pane.dragIdentifier) == nil)
        #expect(f.statuses.attentionCount == 1)
        try await f.wait { label(in: tabs)?.breath == nil }
        #expect(label(in: tabs) === original)
        #expect(original.stringValue == L("Needs you") && !original.isHidden)

        tabs.removeFromSuperview()
        tabs = mountSidebar()
        try await f.wait { label(in: tabs)?.stringValue == L("Needs you") }
        #expect(label(in: tabs)?.breath == nil && !pane.sessionState.isUnread)
        try await f.status(.tool, event: "PreToolUse", pane: pane.dragIdentifier, record: record)
        try await f.wait { label(in: tabs)?.stringValue == L("Thinking") }
        #expect(f.statuses.attentionCount == 0)
        try await f.status(.attention, event: "PermissionRequest", pane: pane.dragIdentifier, record: record)
        #expect(pane.sessionState.isUnread, "A new request after resumed work must notify again")
        try await f.status(.idle, event: "SessionEnd", pane: pane.dragIdentifier, record: record)
        try await f.wait { label(in: tabs)?.isHidden == true }
        #expect(!pane.sessionState.isUnread)
    }

    @Test(arguments: ["focus", "click", "key"])
    func interactingWithTheCurrentTerminalAcknowledgesCompletion(interaction: String) async throws {
        _ = NSApplication.shared
        if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }
        let f = try SessionModelFixture()
        let previous = AppState.shared
        AppState.shared = AppState(taskDirectory: f.root, sweepStalePanes: false, sessionLibrary: f.library)
        defer { AppState.shared.windowControllers = []; AppState.shared = previous ?? AppState.shared; f.close() }
        let pane = PaneView(sessionLibrary: f.library)
        let controller = TerminalWindowController(initialPane: pane)
        AppState.shared.windowControllers = [controller]
        defer { controller.window?.close() }
        let window = try #require(controller.window)
        let record = f.record()
        pane.associateSession(f.association(record))
        pane.focusTerminal()
        #expect(window.firstResponder === pane.terminal)
        try await f.status(.done, event: "Stop", pane: pane.dragIdentifier, record: record)
        #expect(f.statuses.unreadCount == 1)
        let background = f.pane()
        try await f.status(.done, event: "Stop", pane: background, record: record)
        #expect(f.statuses.unreadCount == 2)
        switch interaction {
        case "click":
            let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            pane.terminal.mouseDown(with: down)
            let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
            pane.terminal.mouseUp(with: up)
        case "key":
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 123))
            pane.terminal.keyDown(with: event)
        default:
            // makeFirstResponder succeeds without another becomeFirstResponder callback.
            pane.focusTerminal()
        }
        #expect(window.firstResponder === pane.terminal)
        #expect(f.library.paneState(for: pane.dragIdentifier)?.status?.state == .idle)
        #expect(f.statuses.unreadCount == 1)
        #expect(f.library.paneState(for: background)?.status?.state == .done,
                "Reading this pane must not acknowledge another pane, even for the same conversation")
        // Another completion remains unread until another interaction.
        try await f.status(.done, event: "Stop", pane: pane.dragIdentifier, record: record)
        #expect(f.statuses.unreadCount == 2)
        window.makeFirstResponder(nil)
        pane.focusTerminal()
        #expect(f.library.paneState(for: pane.dragIdentifier)?.status?.state == .idle)
        #expect(f.statuses.unreadCount == 1)
        // Interaction while the Agent is busy must not erase its running state.
        try await f.status(.thinking, event: "UserPromptSubmit", pane: pane.dragIdentifier, record: record)
        pane.focusTerminal()
        #expect(f.library.paneState(for: pane.dragIdentifier)?.status?.state == .thinking)
    }
}
