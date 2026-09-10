import AppKit
import LighttyCore
import Testing
@testable import lightty

extension SessionAssociationTests {
    @Test func directoryFieldEditorDoesNotWrapLongPaths() throws {
        _ = NSApplication.shared
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 70),
                            styleMask: [.titled], backing: .buffered, defer: false)
        let directory = WorkingDirectoryEditor(path: "/Users/example/project/frontend/foodmaxapprn/apps/mobile")
        directory.frame = NSRect(x: 10, y: 10, width: 200, height: 28)
        host.contentView?.addSubview(directory)
        host.contentView?.layoutSubtreeIfNeeded()
        host.makeKeyAndOrderFront(nil)
        defer { host.orderOut(nil) }
        host.makeFirstResponder(directory.field)
        let editor = try #require(directory.field.currentEditor() as? NSTextView)
        let manager = try #require(editor.layoutManager)
        let container = try #require(editor.textContainer)
        manager.ensureLayout(for: container)
        var lines = 0
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _, _, _, _, _ in lines += 1 }
        #expect(lines == 1)
    }

    /// 新建任务里回车提交只在编辑文本时生效，走字段的 doCommandBy；
    /// 按钮不再持有 AppKit keyEquivalent。回车现在走的是主操作——建任务并启动。
    @MainActor @Test func returnInTheNameFieldCreatesAndLaunchesWithoutAKeyEquivalent() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("handoff-return-\(UUID().uuidString)")
        let workdir = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        let previous = AppState.shared
        AppState.shared = AppState(taskDirectory: root.appendingPathComponent("tasks"), sweepStalePanes: false)
        defer { AppState.shared = previous ?? AppState.shared; try? FileManager.default.removeItem(at: root) }
        if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }

        let window = TerminalWindowController()
        defer { window.window?.close() }
        let controller = LaunchComposerController(subject: .newTask, controller: window)
        _ = controller.view
        let button = try #require(descendants(controller.view).compactMap { $0 as? ShellAccentButton }.first)
        #expect(button.keyEquivalent.isEmpty)
        controller.nameField.stringValue = "Return fixture"
        controller.directory.path = workdir.path
        let editor = NSTextView()
        #expect(controller.control(controller.nameField, textView: editor,
                                   doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(AppState.shared.taskStore.list().tasks.first?.task.workdir == workdir.path)
        #expect(window.tabCount == 2)
        #expect(!controller.control(controller.nameField, textView: editor,
                                    doCommandBy: #selector(NSResponder.insertTab(_:))))
    }

    @MainActor @Test func longHandoffFieldsStaySingleLine() throws {
        _ = NSApplication.shared
        let controller = LaunchComposerController(subject: .newTask, controller: nil)
        _ = controller.view
        for field in [controller.nameField, controller.directory.field] {
            field.stringValue = "/Users/example/projects/a-very-long-project-name/apps/mobile"
            let cell = try #require(field.cell as? NSTextFieldCell)
            #expect(cell.usesSingleLineMode)
            #expect(cell.isScrollable || cell.lineBreakMode == .byTruncatingHead)
            #expect(!cell.wraps)
            let size = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: 160, height: 1000))
            #expect(size.height < 30)
        }
        // 正文相反：它就是要换行、要能滚。
        #expect(controller.bodyEditor.textView.textContainer?.widthTracksTextView == true)
        let button = try #require(descendants(controller.view).compactMap { $0 as? ShellAccentButton }.first)
        controller.view.setFrameSize(controller.view.fittingSize)
        controller.view.layoutSubtreeIfNeeded()
        #expect(button.frame.height == 30)
        // 主操作与次操作都占整幅，上下叠放，左右缘对齐。
        let only = try #require(descendants(controller.view).compactMap { $0 as? ShellTextButton }
            .first { $0.label == L("Create only") })
        #expect(abs(only.frame.width - button.frame.width) < 1)
        #expect(abs(only.frame.minX - button.frame.minX) < 1)
    }

    /// 中文输入法拼字期间是「未确定文本」，它不发 `textDidChange`。只听那一条的话，
    /// 字已经打在框里了、占位文字还在，两层字叠在一起。
    @MainActor @Test func placeholderDisappearsWhileAnInputMethodIsStillComposing() throws {
        _ = NSApplication.shared
        let area = ShellTextArea()
        area.placeholder = "目标、背景、下一步。"
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                            styleMask: [.titled], backing: .buffered, defer: false)
        host.contentView?.addSubview(area)
        area.frame = NSRect(x: 10, y: 10, width: 280, height: 92)
        host.makeKeyAndOrderFront(nil)
        defer { host.orderOut(nil) }
        host.makeFirstResponder(area.textView)
        #expect(area.isShowingPlaceholder)

        // 拼音输入法把未确定文本交给文本视图，此时还没有「确定」。
        area.textView.setMarkedText("fasheng", selectedRange: NSRange(location: 7, length: 0),
                                    replacementRange: NSRange(location: 0, length: 0))
        #expect(area.textView.hasMarkedText())
        #expect(!area.isShowingPlaceholder, "拼字期间占位文字必须让位")

        // 整段删掉之后要回来。
        area.textView.unmarkText()
        area.textView.string = ""
        area.string = ""
        #expect(area.isShowingPlaceholder)
    }

    /// 正文框跟着内容长：一两行时不占地方，长内容自己撑开，到两倍为止改滚动。
    @MainActor @Test func handoffNotesGrowWithContentUpToTwiceTheHeight() throws {
        _ = NSApplication.shared
        let area = ShellTextArea()
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
                            styleMask: [.titled], backing: .buffered, defer: false)
        area.translatesAutoresizingMaskIntoConstraints = false
        host.contentView?.addSubview(area)
        NSLayoutConstraint.activate([
            area.topAnchor.constraint(equalTo: host.contentView!.topAnchor, constant: 10),
            area.leadingAnchor.constraint(equalTo: host.contentView!.leadingAnchor, constant: 10),
            area.widthAnchor.constraint(equalToConstant: 280),
        ])
        func settle() {
            host.contentView?.layoutSubtreeIfNeeded()
            host.contentView?.layoutSubtreeIfNeeded()
        }
        settle()
        let base = area.frame.height
        #expect(base == area.minimumHeight)

        area.string = String(repeating: "把比价弹窗的埋点补齐，顺带核对搜索页的曝光。", count: 12)
        settle()
        let grown = area.frame.height
        #expect(grown > base, "内容多了要自己长高")
        #expect(grown <= area.maximumHeight)

        area.string = String(repeating: "把比价弹窗的埋点补齐，顺带核对搜索页的曝光。", count: 60)
        settle()
        let ceiling = area.frame.height
        #expect(ceiling <= area.maximumHeight, "到两倍就停，再多改用滚动")
        #expect(ceiling > area.maximumHeight - 20, "封顶值不该离两倍太远")
        // 封顶时最后一行必须是整行。文本视图是滚动区里的文档，裁剪线上没有下边距，
        // 所以可视高度减掉**上**边距要正好是若干整行。
        let manager = try #require(area.textView.layoutManager)
        let top = area.textView.textContainerInset.height
        var lastWhole: CGFloat = 0
        manager.enumerateLineFragments(
            forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)
        ) { rect, _, _, _, stop in
            if rect.maxY <= ceiling - top + 0.5 { lastWhole = rect.maxY } else { stop.pointee = true }
        }
        #expect(abs(ceiling - top - lastWhole) < 0.5, "封顶要停在整行的下沿")
        #expect(area.textView.enclosingScrollView?.hasVerticalScroller == true)

        area.string = ""
        settle()
        #expect(area.frame.height == area.minimumHeight, "清空要缩回去")
    }

    /// 正文框缩回去时气泡也要缩。`NSPopover` 只在展示时量一次内容：长高时约束把窗口
    /// 顶大了，看着「能长」；缩回去时窗口不动，多出来的高度被竖栈分摊成各段之间的空白。
    @MainActor @Test func theComposerReportsItsHeightBackDownAfterTheNotesShrink() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = AppState.shared
        AppState.shared = AppState(taskDirectory: root.appendingPathComponent("tasks"), sweepStalePanes: false)
        defer { AppState.shared = previous ?? AppState.shared; try? FileManager.default.removeItem(at: root) }

        let controller = LaunchComposerController(subject: .newTask, controller: nil)
        // 刻意不挂进 NSWindow。原先把它设成窗口的 contentViewController，是想模拟气泡
        // 给出的外部尺寸约束——但 NSWindow 不是 NSPopover，它自己那套约束回灌会在
        // 同一个进程里累积：实测同样的测量做到第三次，`contentStack.fittingSize` 就
        // 不再跟着正文变，两次读数都是 499，测试于是按确定顺序挂在全量里、单独跑却过。
        // 换成普通父视图 + 一个宽度约束，被测路径没变（`viewDidLayout` 仍然从
        // `contentStack.fittingSize` 算 `preferredContentSize`），而且做多少次都一样。
        // 代价要说明白：这条不再覆盖"真气泡的尺寸约束下还能缩回来"，它本来也没稳定
        // 覆盖住——那一版在第三次之后给的是错的答案。
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 800))
        host.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        func settle() {
            controller.view.layoutSubtreeIfNeeded()
            controller.viewDidLayout()
            controller.view.layoutSubtreeIfNeeded()
            controller.viewDidLayout()
        }
        settle()
        let compact = controller.preferredContentSize.height
        #expect(compact > 0)

        controller.bodyEditor.string = String(repeating: "把比价弹窗的埋点补齐。", count: 24)
        settle()
        #expect(controller.preferredContentSize.height > compact, "内容多了要报更高")

        controller.bodyEditor.string = ""
        settle()
        #expect(abs(controller.preferredContentSize.height - compact) < 0.5, "减回来高度也要跟着回来")
    }

    /// 三个入口共用一个浮层：会话不挂任务，新建任务先落盘再启动，已有任务重读后启动。
    /// 这条钉的是「同一段界面在三种情况下都在」——Agent、工作目录、去处一个都不少。
    @MainActor @Test func everyLaunchSubjectOffersAgentDirectoryAndDestination() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = AppState.shared
        AppState.shared = AppState(taskDirectory: root.appendingPathComponent("tasks"), sweepStalePanes: false)
        defer { AppState.shared = previous ?? AppState.shared; try? FileManager.default.removeItem(at: root) }
        if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }
        let task = TaskFile(name: "Fixture", status: "active", workdir: root.path,
                            created: Date(), updated: Date())
        let subjects: [LaunchSubject] = [
            .session, .newTask, .task(fileURL: root.appendingPathComponent("fixture.md"), task: task),
        ]
        for subject in subjects {
            let controller = LaunchComposerController(subject: subject, controller: nil)
            let views = descendants(controller.view)
            #expect(views.compactMap { $0 as? ShellDropdown }.count == 1)
            #expect(views.contains { $0 === controller.directory })
            let radios = views.compactMap { $0 as? RestoreSelectionButton }
                .filter { $0.title != L("Set as default directory on launch") }
            #expect(radios.map(\.title) == [L("Split in current tab"), L("New tab"), L("New window")])
            #expect(radios.first { $0.title == L("New tab") }?.state == .on)
        }
    }

    /// 会话模式的新建：能选目录（这正是它以前缺的），而且不写任何任务文件。
    @MainActor @Test func newSessionUsesTheChosenDirectoryAndWritesNoTask() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let chosen = root.appendingPathComponent("chosen folder")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        let previous = AppState.shared
        AppState.shared = AppState(taskDirectory: root.appendingPathComponent("tasks"), sweepStalePanes: false)
        defer { AppState.shared = previous ?? AppState.shared; try? FileManager.default.removeItem(at: root) }
        if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }

        let controller = LaunchComposerController(subject: .session, controller: nil)
        _ = controller.view
        // 没有任务就没有「设为默认目录」这回事。
        #expect(controller.saveDirectory.isHidden)
        controller.directory.path = chosen.path
        let pane = try #require(controller.makePane())
        #expect(pane.terminal.launchConfiguration.workingDirectory == chosen.path)
        #expect(pane.taskFileURL == nil)
        #expect(AppState.shared.taskStore.list().tasks.isEmpty)

        controller.directory.path = root.appendingPathComponent("missing").path
        #expect(controller.makePane() == nil)
    }

    /// 新建任务：正文落进文件，两条出口（只创建 / 创建并启动）都走同一段建档代码。
    @MainActor @Test func newTaskWritesTheTypedBodyAndCanCreateWithoutLaunching() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workdir = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        let previous = AppState.shared
        AppState.shared = AppState(taskDirectory: root.appendingPathComponent("tasks"), sweepStalePanes: false)
        defer { AppState.shared = previous ?? AppState.shared; try? FileManager.default.removeItem(at: root) }
        if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }
        let store = AppState.shared.taskStore

        let onlyCreate = LaunchComposerController(subject: .newTask, controller: nil)
        _ = onlyCreate.view
        // 名字是必填：空名字既不建档也不启动。
        onlyCreate.directory.path = workdir.path
        onlyCreate.createOnly()
        #expect(store.list().tasks.isEmpty)

        onlyCreate.nameField.stringValue = "只建一笔"
        onlyCreate.bodyEditor.string = "## Next steps\n先把接口对齐"
        onlyCreate.createOnly()
        let created = try #require(store.list().tasks.first)
        #expect(created.task.workdir == workdir.path)
        #expect(created.task.body.contains("先把接口对齐"))

        let launcher = LaunchComposerController(subject: .newTask, controller: nil)
        _ = launcher.view
        launcher.nameField.stringValue = "建完就开"
        launcher.bodyEditor.string = "目标：跑通登录"
        launcher.directory.path = workdir.path
        let pane = try #require(launcher.makePane())
        #expect(pane.terminal.launchConfiguration.workingDirectory == workdir.path)
        let bound = try #require(pane.taskFileURL)
        #expect(try store.load(at: bound).body.contains("跑通登录"))
        #expect(store.list().tasks.count == 2)
    }

    @MainActor @Test func handoffDirectoryCreationAndLaunchOverrides() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = root.appendingPathComponent("original")
        let chosen = root.appendingPathComponent("chosen folder")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        let previous = AppState.shared
        AppState.shared = AppState(taskDirectory: root.appendingPathComponent("tasks"), sweepStalePanes: false)
        defer { AppState.shared = previous ?? AppState.shared; try? FileManager.default.removeItem(at: root) }
        if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }

        let creator = LaunchComposerController(subject: .newTask, controller: nil)
        _ = creator.view
        creator.nameField.stringValue = "Directory fixture"
        creator.directory.path = original.path
        creator.createOnly()
        let store = AppState.shared.taskStore
        let file = try #require(store.list().tasks.first)
        #expect(file.task.workdir == original.path)

        let window = TerminalWindowController()
        defer { window.window?.close() }
        let launcher = LaunchComposerController(
            subject: .task(fileURL: file.fileURL, task: file.task), controller: window)
        _ = launcher.view
        let preview = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false)
        preview.contentView = launcher.view
        preview.makeKeyAndOrderFront(nil)
        defer { preview.orderOut(nil) }
        preview.makeFirstResponder(launcher.directory.field)
        launcher.viewDidAppear()
        #expect(launcher.directory.field.currentEditor() == nil)
        #expect(preview.makeFirstResponder(launcher.directory.field))
        #expect(launcher.directory.field.currentEditor() != nil)
        preview.makeFirstResponder(nil)
        #expect(launcher.directory.path == original.path)
        #expect(launcher.saveDirectory.isHidden)
        launcher.directory.path = chosen.path
        #expect(!launcher.saveDirectory.isHidden)
        #expect(launcher.saveDirectory.state == .off)
        let directoryGroup = try #require(launcher.directory.superview as? NSStackView)
        #expect(directoryGroup.arrangedSubviews[2] === launcher.saveDirectory)
        let outer = try #require(launcher.view.subviews.first as? NSStackView)
        #expect(outer.customSpacing(after: directoryGroup) == 14)
        launcher.view.setFrameSize(launcher.view.fittingSize)
        launcher.view.layoutSubtreeIfNeeded()
        #expect(abs(launcher.directory.frame.minX - launcher.saveDirectory.frame.minX) < 1)
        let gap = abs(launcher.directory.frame.midY - launcher.saveDirectory.frame.midY)
        let halves = (launcher.directory.frame.height + launcher.saveDirectory.frame.height) / 2
        #expect(abs(gap - halves - 6) < 1)
        let temporary = try #require(launcher.makePane())
        #expect(temporary.terminal.launchConfiguration.workingDirectory == chosen.path)
        #expect(try store.load(at: file.fileURL).workdir == original.path)
        #expect(temporary.taskFileURL == file.fileURL)
        launcher.saveDirectory.state = .on
        launcher.directory.path = original.path
        #expect(launcher.saveDirectory.isHidden)
        #expect(launcher.saveDirectory.state == .off)
        launcher.directory.path = chosen.path
        #expect(launcher.saveDirectory.state == .off)

        var fresh = try store.load(at: file.fileURL)
        fresh.body = "New Agent handoff after opening the preview"
        try store.update(at: file.fileURL, task: fresh)
        launcher.saveDirectory.state = .on
        #expect(try store.load(at: file.fileURL).workdir == original.path)
        let saved = try #require(launcher.makePane())
        #expect(saved.terminal.launchConfiguration.workingDirectory == chosen.path)
        #expect(try store.load(at: file.fileURL).workdir == chosen.path)
        #expect(try store.load(at: file.fileURL).body == fresh.body)
        let reopened = LaunchComposerController(
            subject: .task(fileURL: file.fileURL, task: try store.load(at: file.fileURL)),
            controller: window)
        _ = reopened.view
        #expect(reopened.directory.path == chosen.path)
        #expect(reopened.saveDirectory.isHidden)
        launcher.directory.field.stringValue = original.path
        launcher.directory.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(!launcher.saveDirectory.isHidden)
        #expect(launcher.saveDirectory.state == .off)
        #expect(try #require(launcher.makePane()).terminal.launchConfiguration.workingDirectory == original.path)
        #expect(try store.load(at: file.fileURL).workdir == chosen.path)
        launcher.directory.path = root.appendingPathComponent("missing").path
        #expect(!launcher.saveDirectory.isEnabled)
        #expect(launcher.makePane() == nil)
        #expect(try store.load(at: file.fileURL).workdir == chosen.path)
    }
}

private func descendants(_ view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap { descendants($0) }
}

@Test func workingDirectoryRequiresAnExistingAbsoluteFolder() {
    #expect(WorkingDirectory.validated("relative/path") == nil)
    #expect(WorkingDirectory.validated("") == nil)
    #expect(WorkingDirectory.validated("/bin/sh") == nil)
    #expect(WorkingDirectory.validated("~") == FileManager.default.homeDirectoryForCurrentUser.path)
}
