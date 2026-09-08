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
                                      command: .shell("pwd > launch-marker"))
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
        XCTAssertEqual(AgentLaunchPreference.initialInput(for: .claudeCode, in: defaults),
                       "claude --permission-mode bypassPermissions\n")
        XCTAssertTrue(AgentLaunchPreference.setCustomArguments("--profile work", for: .codex, in: defaults))
        XCTAssertEqual(AgentLaunchPreference.initialInput(for: .codex, in: defaults), "codex --yolo --profile work\n")
        XCTAssertFalse(AgentLaunchPreference.setCustomArguments("--profile\nexit", for: .codex, in: defaults))
        XCTAssertFalse(AgentLaunchPreference.setCustomArguments("--profile\0", for: .codex, in: defaults))
        XCTAssertNil(AgentLaunchPreference.initialInput(for: .terminal, in: defaults))
        AgentLaunchPreference.reset(in: defaults)
        XCTAssertEqual(AgentLaunchPreference.command(for: .codex, in: defaults), "codex --yolo")
        XCTAssertTrue(AgentLaunchPreference.setCustomArguments("  ", for: .claudeCode, in: defaults))
        XCTAssertEqual(AgentLaunchPreference.command(for: .claudeCode, in: defaults), "claude --permission-mode bypassPermissions")
    }

    /// 一个开关管两家：意图是「跳过权限确认」，参数写法是 lightty 的翻译。
    func testOneBypassSwitchTranslatesToEachCLIsOwnFlag() throws {
        let suite = "agent-bypass-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(AgentLaunchPreference.bypassEnabled(in: defaults))
        AgentLaunchPreference.setBypass(false, in: defaults)
        XCTAssertEqual(AgentLaunchPreference.command(for: .codex, in: defaults), "codex")
        XCTAssertEqual(AgentLaunchPreference.command(for: .claudeCode, in: defaults), "claude")
        XCTAssertEqual(AgentLaunchPreference.launchArguments(for: .codex, in: defaults), [])
        XCTAssertEqual(AgentLaunchPreference.launchArguments(for: .claude, in: defaults), [])
        AgentLaunchPreference.setBypass(true, in: defaults)
        XCTAssertEqual(AgentLaunchPreference.command(for: .codex, in: defaults), "codex --yolo")
        XCTAssertEqual(AgentLaunchPreference.command(for: .claudeCode, in: defaults),
                       "claude --permission-mode bypassPermissions")
    }

    func testResumeInheritsBypassAndExtraArgumentsWithoutTheProgramToken() throws {
        let suite = "agent-resume-flags-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AgentLaunchPreference.launchArguments(for: .codex, in: defaults), ["--yolo"])
        XCTAssertEqual(AgentLaunchPreference.launchArguments(for: .claude, in: defaults),
                       ["--permission-mode", "bypassPermissions"])
        XCTAssertTrue(AgentLaunchPreference.setCustomArguments("-c model=\"o3 mini\"", for: .codex, in: defaults))
        XCTAssertEqual(AgentLaunchPreference.launchArguments(for: .codex, in: defaults),
                       ["--yolo", "-c", "model=o3 mini"])
        XCTAssertEqual(AgentLaunchPreference.command(for: .codex, in: defaults), "codex --yolo -c model=\"o3 mini\"")
    }

    /// 0.1.x 的整条命令拆回开关 + 附加参数，认得出的 bypass 写法不丢。
    func testLegacyCommandsMigrateIntoTheSwitchAndExtraArguments() throws {
        let suite = "agent-migrate-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("claude --permission-mode bypassPermissions", forKey: "lightty.agent.command.claudeCode")
        defaults.set("codex --profile work", forKey: "lightty.agent.command.codex")
        AgentLaunchPreference.migrateLegacyCommands(in: defaults)
        XCTAssertTrue(AgentLaunchPreference.bypassEnabled(in: defaults))
        XCTAssertEqual(AgentLaunchPreference.customArguments(for: .claudeCode, in: defaults), "")
        XCTAssertEqual(AgentLaunchPreference.customArguments(for: .codex, in: defaults), "--profile work")
        XCTAssertNil(defaults.string(forKey: "lightty.agent.command.claudeCode"))
        // 再跑一次不能覆盖用户此后的选择。
        AgentLaunchPreference.setBypass(false, in: defaults)
        AgentLaunchPreference.migrateLegacyCommands(in: defaults)
        XCTAssertFalse(AgentLaunchPreference.bypassEnabled(in: defaults))

        let fresh = try XCTUnwrap(UserDefaults(suiteName: "agent-migrate-off-\(UUID().uuidString)"))
        defer { fresh.removePersistentDomain(forName: fresh.description) }
        fresh.set("codex", forKey: "lightty.agent.command.codex")
        AgentLaunchPreference.migrateLegacyCommands(in: fresh)
        XCTAssertFalse(AgentLaunchPreference.bypassEnabled(in: fresh))
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

    /// Handoff launches a fresh Agent, so the whole configured command is typed — including the
    /// permission flags the settings page shows.
    func testHandoffLaunchTypesTheConfiguredCommandForTheSelectedAgent() throws {
        _ = NSApplication.shared
        let taskDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agent-handoff-command-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: taskDirectory) }
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        AppState.shared = AppState(taskDirectory: taskDirectory, sweepStalePanes: false)
        if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }
        let key = "lightty.agent.selected"
        let saved = FilePreferences.shared.object(forKey: key)
        defer {
            if let saved { FilePreferences.shared.set(saved, forKey: key) }
            else { FilePreferences.shared.removeObject(forKey: key) }
        }
        AgentLaunchPreference.select(.codex)
        let controller = TerminalWindowController()
        try AppState.shared.taskStore.create(name: "Handoff launch", workdir: taskDirectory.path)
        let file = taskDirectory.appendingPathComponent("Handoff launch.md")
        let task = try AppState.shared.taskStore.load(at: file)
        let popover = RestorePopoverController(fileURL: file, task: task, controller: controller)
        _ = popover.view
        let pane = try XCTUnwrap(popover.makeBoundPane())
        XCTAssertEqual(pane.terminal.launchConfiguration.initialInput, "codex --yolo\n")
    }

    /// 设置页的开关直接改的是全局意图，两家 Agent 的命令预览要当场跟上。
    func testSettingsBypassSwitchRewritesBothLaunchCommands() throws {
        _ = NSApplication.shared
        let saved = AgentLaunchPreference.bypassEnabled()
        defer { AgentLaunchPreference.setBypass(saved) }
        AgentLaunchPreference.setBypass(true)
        let settings = SettingsView(page: .general)
        settings.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        settings.layoutSubtreeIfNeeded()
        let views = descendants(settings)
        let preview = try XCTUnwrap(views.compactMap { $0 as? NSTextField }
            .first { $0.stringValue.contains("--yolo") })
        XCTAssertTrue(preview.stringValue.contains("claude --permission-mode bypassPermissions"))
        let toggle = try XCTUnwrap(views.compactMap { $0 as? ShellToggle }.first)
        XCTAssertTrue(toggle.accessibilityPerformPress())
        XCTAssertFalse(AgentLaunchPreference.bypassEnabled())
        XCTAssertEqual(preview.stringValue.contains("--yolo"), false)
        XCTAssertEqual(preview.stringValue.contains("bypassPermissions"), false)
        XCTAssertTrue(preview.stringValue.contains("codex"))
    }

    /// 建 pane 的入口都只构造 AgentCommand，所以一个开关能同时改到新建、handoff、
    /// 恢复会话、原生选择器和重启恢复——这里把「行为一致」钉成断言。
    func testEveryAgentCommandFollowsTheSameSettings() throws {
        _ = NSApplication.shared
        let saved = AgentLaunchPreference.bypassEnabled()
        defer { AgentLaunchPreference.setBypass(saved) }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let session = AgentSession(key: .init(agent: .codex, sourceRoot: root.standardizedFileURL.path,
                                              nativeID: "abc-123"),
                                   title: "", workingDirectory: "/tmp", updatedAt: nil)
        func commands() throws -> [String] {
            let plan = try SessionResumePlan(resuming: session, executable: "/bin/echo", configuration: .standard)
            // 新建与 handoff 共用 .start；恢复与重启恢复共用 .resume。
            return try [AgentCommand.start(.codex), .resume(plan), .sessionPicker(plan)]
                .map { try XCTUnwrap($0.shellInput) }
        }
        AgentLaunchPreference.setBypass(true)
        for command in try commands() { XCTAssertTrue(command.contains("--yolo"), command) }
        AgentLaunchPreference.setBypass(false)
        for command in try commands() { XCTAssertFalse(command.contains("--yolo"), command) }
        XCTAssertNil(AgentCommand.none.shellInput)
        XCTAssertNil(AgentCommand.start(.terminal).shellInput)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants($0) }
    }
}
