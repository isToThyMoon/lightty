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

    /// 新建任务里回车提交只在编辑文本时生效，由字段的 doCommandBy 分发；
    /// 按钮不再持有 AppKit keyEquivalent。
    @MainActor @Test func returnInEitherFieldCreatesTheTaskWithoutAKeyEquivalent() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("handoff-return-\(UUID().uuidString)")
        let workdir = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        let previous = AppState.shared
        AppState.shared = AppState(taskDirectory: root.appendingPathComponent("tasks"), sweepStalePanes: false)
        defer { AppState.shared = previous ?? AppState.shared; try? FileManager.default.removeItem(at: root) }

        let controller = NewHandoffController()
        let stack = try #require(controller.view.subviews.first as? NSStackView)
        let actions = try #require(stack.arrangedSubviews.last)
        let button = try #require(actions.subviews.first as? ShellAccentButton)
        #expect(button.keyEquivalent.isEmpty)
        controller.nameField.stringValue = "Return fixture"
        controller.directory.path = workdir.path
        let editor = NSTextView()
        // 名称框回车 → 提交；同一支路也接了目录框的 onCommit。
        #expect(controller.control(controller.nameField, textView: editor,
                                   doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(AppState.shared.taskStore.list().tasks.first?.task.workdir == workdir.path)
        #expect(!controller.control(controller.nameField, textView: editor,
                                    doCommandBy: #selector(NSResponder.insertTab(_:))))
    }

    @Test func longHandoffFieldsStaySingleLine() throws {
        let controller = NewHandoffController()
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
        let stack = try #require(controller.view.subviews.first as? NSStackView)
        let actions = try #require(stack.arrangedSubviews.last)
        let button = try #require(actions.subviews.first as? ShellAccentButton)
        controller.view.setFrameSize(controller.view.fittingSize)
        controller.view.layoutSubtreeIfNeeded()
        #expect(button.frame.height == 32)
        #expect(button.frame.width >= 80)
        #expect(abs(button.frame.maxX - actions.bounds.maxX) < 1)
    }

    @Test func handoffDirectoryCreationAndLaunchOverrides() throws {
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

        let creator = NewHandoffController()
        _ = creator.view
        creator.nameField.stringValue = "Directory fixture"
        creator.directory.path = original.path
        creator.commit()
        let store = AppState.shared.taskStore
        let file = try #require(store.list().tasks.first)
        #expect(file.task.workdir == original.path)

        let window = TerminalWindowController()
        defer { window.window?.close() }
        let launcher = RestorePopoverController(fileURL: file.fileURL, task: file.task, controller: window)
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
        #expect(abs(abs(launcher.directory.frame.midY - launcher.saveDirectory.frame.midY)
            - (launcher.directory.frame.height + launcher.saveDirectory.frame.height) / 2 - 6) < 1)
        let temporary = try #require(launcher.makeBoundPane())
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
        let saved = try #require(launcher.makeBoundPane())
        #expect(saved.terminal.launchConfiguration.workingDirectory == chosen.path)
        #expect(try store.load(at: file.fileURL).workdir == chosen.path)
        #expect(try store.load(at: file.fileURL).body == fresh.body)
        let reopened = RestorePopoverController(fileURL: file.fileURL,
            task: try store.load(at: file.fileURL), controller: window)
        _ = reopened.view
        #expect(reopened.directory.path == chosen.path)
        #expect(reopened.saveDirectory.isHidden)
        launcher.directory.field.stringValue = original.path
        launcher.directory.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(!launcher.saveDirectory.isHidden)
        #expect(launcher.saveDirectory.state == .off)
        #expect(try #require(launcher.makeBoundPane()).terminal.launchConfiguration.workingDirectory == original.path)
        #expect(try store.load(at: file.fileURL).workdir == chosen.path)
        launcher.directory.path = root.appendingPathComponent("missing").path
        #expect(!launcher.saveDirectory.isEnabled)
        #expect(launcher.makeBoundPane() == nil)
        #expect(try store.load(at: file.fileURL).workdir == chosen.path)
    }
}

@Test func workingDirectoryRequiresAnExistingAbsoluteFolder() {
    #expect(WorkingDirectory.validated("relative/path") == nil)
    #expect(WorkingDirectory.validated("") == nil)
    #expect(WorkingDirectory.validated("/bin/sh") == nil)
    #expect(WorkingDirectory.validated("~") == FileManager.default.homeDirectoryForCurrentUser.path)
}
