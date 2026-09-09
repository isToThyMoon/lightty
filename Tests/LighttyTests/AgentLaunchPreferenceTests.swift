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
        XCTAssertNotNil(descendants(palette).compactMap { $0 as? ShellDropdown }.first)
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
        let popover = LaunchComposerController(
            subject: .task(fileURL: directory.appendingPathComponent("task.md"), task: task),
            controller: controller)
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
        let marker = directory.appendingPathComponent("launch-marker")
        // 绝对路径落点：断言看的是 pwd 的**内容**，所以即使 pane 没拿到任务目录、
        // 退回内核默认 cwd（跑测试时是仓库根），也只会写进临时目录而不是污染仓库。
        let pane = PaneView.restoring(task: task, fileURL: file,
                                      command: .shell("pwd > '\(marker.path)'"))
        XCTAssertNil(pane.terminal.surface)
        XCTAssertEqual(pane.taskFileURL, file)
        XCTAssertEqual(pane.terminal.launchConfiguration.workingDirectory, directory.path)
        let pointer = PaneRuntimeDirectory.taskPointerFile(for: pane.dragIdentifier.uuidString)
        XCTAssertEqual(try String(contentsOf: pointer).trimmingCharacters(in: .whitespacesAndNewlines), file.path)
        let controller = TerminalWindowController(initialPane: pane)
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

    /// 0.1.x 的整条命令只拆出附加参数：程序名丢弃，bypass 写法删掉（已由开关表达），
    /// 开关一律留在默认打开，不按旧命令反推。
    func testLegacyCommandsMigrateIntoExtraArgumentsAndLeaveTheSwitchOn() throws {
        for (legacy, expected) in [
            (["lightty.agent.command.claudeCode": "claude --permission-mode bypassPermissions --model opus"],
             ["claude --permission-mode bypassPermissions --model opus", "codex --yolo"]),
            // 旧命令里没写 bypass 也一样：转换后所有人是同一个起点。
            (["lightty.agent.command.codex": "codex --profile work"],
             ["claude --permission-mode bypassPermissions", "codex --yolo --profile work"]),
        ] {
            let suite = "agent-migrate-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            for (key, value) in legacy { defaults.set(value, forKey: key) }
            AgentLaunchPreference.migrateLegacyCommands(in: defaults)
            XCTAssertTrue(AgentLaunchPreference.bypassEnabled(in: defaults))
            XCTAssertEqual([LaunchAgent.claudeCode, .codex].map { AgentLaunchPreference.command(for: $0, in: defaults) },
                           expected)
            for key in legacy.keys { XCTAssertNil(defaults.string(forKey: key)) }
        }
    }

    /// 迁移只跑一次的量：旧键清掉之后，再跑不能覆盖用户此后关掉开关的选择。
    func testMigrationDoesNotOverrideALaterChoice() throws {
        let suite = "agent-migrate-again-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("codex --yolo", forKey: "lightty.agent.command.codex")
        AgentLaunchPreference.migrateLegacyCommands(in: defaults)
        AgentLaunchPreference.setBypass(false, in: defaults)
        AgentLaunchPreference.migrateLegacyCommands(in: defaults)
        XCTAssertFalse(AgentLaunchPreference.bypassEnabled(in: defaults))
        XCTAssertEqual(AgentLaunchPreference.command(for: .codex, in: defaults), "codex")
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
        let popover = LaunchComposerController(
            subject: .task(fileURL: taskDirectory.appendingPathComponent("task.md"), task: task),
            controller: controller)
        let views = descendants(popover.view)
        let picker = try XCTUnwrap(views.compactMap { $0 as? ShellDropdown }.first)
        let buttons = views.compactMap { $0 as? NSButton }
        let tab = try XCTUnwrap(buttons.first { $0.title == L("New tab") })
        let split = try XCTUnwrap(buttons.first { $0.title == L("Split in current tab") })
        XCTAssertEqual(tab.state, .on)
        split.performClick(nil)
        picker.select(LaunchAgent.codex.rawValue)
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
        let popover = LaunchComposerController(subject: .task(fileURL: file, task: task),
                                               controller: controller)
        _ = popover.view
        let pane = try XCTUnwrap(popover.makePane())
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

    /// 改会话名是把 `/rename <名字>` 送进 agent 自己的终端——标题归 agent 所有，
    /// lightty 不另存一份。命令必须**恰好一行**：名字里混进换行，后半截就会变成
    /// 一句发给模型的话，白烧一轮。
    ///
    /// 而且这一行**不带任何行尾**：注入文本在 core 里按粘贴处理，粘进去的回车对
    /// agent 的 TUI 只是插入一个换行，命令会原样停在输入框里。提交是另外按一次
    /// 回车键（`TerminalSurfaceView.sendReturn()`），不是文本的一部分。
    func testRenameCommandIsASingleLineWithNoLineEnding() {
        XCTAssertEqual(AgentCommand.rename("pv search 的 sql 优化").shellInput,
                       "/rename pv search 的 sql 优化")
        XCTAssertEqual(AgentCommand.rename("第一行\n第二行").shellInput,
                       "/rename 第一行 第二行")
        XCTAssertEqual(AgentCommand.rename("  两头有空格  ").shellInput,
                       "/rename 两头有空格")
        XCTAssertNil(AgentCommand.rename("   ").shellInput)
        XCTAssertNil(AgentCommand.rename("").shellInput)
        // 其他几支是敲给 shell 的第一行命令，它们仍然自带换行。
        XCTAssertEqual(AgentCommand.shell("ls").shellInput, "ls\n")
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants($0) }
    }
}
