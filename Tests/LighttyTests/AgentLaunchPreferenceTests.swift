import AppKit
import LighttyCore
import XCTest
@testable import lightty

@MainActor
final class AgentLaunchPreferenceTests: XCTestCase {
    func testSearchUsesSharedAgentWorkflowAndArchiveSettingsEntry() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        AppState.shared = AppState(taskDirectory: directory, sweepStalePanes: false)
        if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }
        try AppState.shared.taskStore.create(name: "Search fixture", workdir: directory.path)
        let controller = TerminalWindowController()
        let palette = SearchPaletteView(controller: controller)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = palette
        palette.frame = NSRect(x: 0, y: 0, width: 1100, height: 700)
        palette.layoutSubtreeIfNeeded()
        let buttons = descendants(palette).compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.first { $0.title == L("New tab") }?.state, .on)
        XCTAssertTrue(buttons.contains { $0.title == L("Split in current tab") })
        XCTAssertFalse(buttons.contains { $0.title == L("New terminal") })
        XCTAssertNotNil(descendants(palette).compactMap { $0 as? NSPopUpButton }.first)
        XCTAssertEqual(controller.tabCount, 1)
        let settings = SettingsView(page: .archive)
        XCTAssertTrue(descendants(settings).contains { $0 is ArchivedTasksView })
        if let path = ProcessInfo.processInfo.environment["LIGHTTY_UI_SNAPSHOT_DIR"],
           let bitmap = palette.bitmapImageRepForCachingDisplay(in: palette.bounds) {
            palette.cacheDisplay(in: palette.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to:
                URL(fileURLWithPath: path).appendingPathComponent("search-agent-workflow.png"))
        }
    }

    func testLongPreviewCannotOpenAnUnclampedFieldEditor() throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("preview-click-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        AppState.shared = AppState(taskDirectory: directory, sweepStalePanes: false)
        if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }
        let controller = TerminalWindowController()
        let body = "## Current state\n" + String(repeating: "Long handoff preview text. ", count: 150)
        let task = TaskFile(name: "Preview", status: "todo", workdir: directory.path,
                            created: Date(), updated: Date(), body: body)
        let popover = RestorePopoverController(fileURL: directory.appendingPathComponent("task.md"),
                                               task: task, controller: controller)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = popover.view
        popover.view.layoutSubtreeIfNeeded()
        let preview = try XCTUnwrap(descendants(popover.view).compactMap { $0 as? NSTextField }
            .first { $0.stringValue.hasPrefix("## Current state") })
        let before = preview.frame
        // AppKit 的文本选择（点击/拖选也走 field editor）不能展开被截断的摘要。
        preview.selectText(nil)
        popover.view.layoutSubtreeIfNeeded()
        XCTAssertNil(preview.currentEditor(), "Selecting a preview must not overlay the launch controls with a field editor")
        XCTAssertEqual(preview.frame, before)
    }

    func testBoundTaskIsReadyBeforeStartupCommandRunsInTaskDirectory() throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agent-startup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        AppState.shared = AppState(taskDirectory: directory, sweepStalePanes: false)
        if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }
        let task = TaskFile(name: "Launch test", status: "todo", workdir: directory.path,
                            created: Date(), updated: Date())
        let file = directory.appendingPathComponent("task.md")
        let pane = PaneView.restoring(task: task, fileURL: file,
                                     initialInput: "pwd > launch-marker\n")
        XCTAssertNil(pane.terminal.surface)
        XCTAssertEqual(pane.taskFileURL, file)
        let pointer = PaneRuntimeDirectory.taskPointerFile(for: pane.dragIdentifier.uuidString)
        XCTAssertEqual(try String(contentsOf: pointer).trimmingCharacters(in: .whitespacesAndNewlines), file.path)
        let controller = TerminalWindowController(initialPane: pane)
        let marker = directory.appendingPathComponent("launch-marker")
        let deadline = Date(timeIntervalSinceNow: 5)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        withExtendedLifetime(controller) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "Initial command must execute")
        }
        let actual = try String(contentsOf: marker).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(URL(fileURLWithPath: actual).resolvingSymlinksInPath().path,
                       directory.resolvingSymlinksInPath().path)
    }

    func testCommandsPersistAndTerminalOnlyDoesNotSendInput() throws {
        let suite = "agent-launch-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AgentLaunchPreference.selected(in: defaults), .codex)
        AgentLaunchPreference.select(.codex, in: defaults)
        XCTAssertEqual(AgentLaunchPreference.selected(in: defaults), .codex)
        XCTAssertEqual(AgentLaunchPreference.initialInput(for: .codex, in: defaults), "codex --yolo\n")
        XCTAssertTrue(AgentLaunchPreference.setCommand("my-codex --profile work", for: .codex, in: defaults))
        XCTAssertEqual(AgentLaunchPreference.initialInput(for: .codex, in: defaults), "my-codex --profile work\n")
        XCTAssertFalse(AgentLaunchPreference.setCommand("codex\nexit", for: .codex, in: defaults))
        XCTAssertFalse(AgentLaunchPreference.setCommand("codex\0", for: .codex, in: defaults))
        XCTAssertNil(AgentLaunchPreference.initialInput(for: .terminal, in: defaults))
        AgentLaunchPreference.resetCommands(in: defaults)
        XCTAssertEqual(AgentLaunchPreference.command(for: .codex, in: defaults), "codex --yolo")
        XCTAssertTrue(AgentLaunchPreference.setCommand("  ", for: .claudeCode, in: defaults))
        XCTAssertEqual(AgentLaunchPreference.command(for: .claudeCode, in: defaults), "claude --permission-mode bypassPermissions")
    }

    func testPopoverSwitchingAgentKeepsDestinationAndDoesNotCreateTerminal() throws {
        _ = NSApplication.shared
        let taskDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agent-picker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: taskDirectory) }
        AppState.shared = AppState(taskDirectory: taskDirectory, sweepStalePanes: false)
        if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }
        let key = "lightty.agent.selected"
        let saved = FilePreferences.shared.object(forKey: key)
        defer {
            if let saved { FilePreferences.shared.set(saved, forKey: key) }
            else { FilePreferences.shared.removeObject(forKey: key) }
        }
        AgentLaunchPreference.select(.claudeCode)
        let controller = TerminalWindowController()
        let task = TaskFile(name: "Example", status: "todo", workdir: taskDirectory.path,
                            created: Date(), updated: Date())
        let popover = RestorePopoverController(fileURL: taskDirectory.appendingPathComponent("task.md"),
                                               task: task, controller: controller)
        let views = descendants(popover.view)
        let picker = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first)
        let buttons = views.compactMap { $0 as? NSButton }
        let tab = try XCTUnwrap(buttons.first { $0.title == L("New tab") })
        let split = try XCTUnwrap(buttons.first { $0.title == L("Split in current tab") })
        XCTAssertEqual(tab.state, .on)
        split.performClick(nil)
        picker.selectItem(at: 1)
        picker.sendAction(try XCTUnwrap(picker.action), to: picker.target)
        XCTAssertEqual(split.state, .on)
        XCTAssertEqual(tab.state, .off)
        XCTAssertTrue(buttons.contains { $0.title == L("Launch %@", "Codex") })
        XCTAssertEqual(controller.tabCount, 1)
        XCTAssertEqual(controller.panes().count, 1)
        XCTAssertEqual(AgentLaunchPreference.selected(), .codex)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants($0) }
    }
}
