import AppKit
import LighttyCore
import XCTest
@testable import lightty

@MainActor
final class PaneIdentityPanelTests: XCTestCase {
    /// 滚轮 settle 与键盘选择的优先级：滚轮停下后高亮指针所在行；期间用了键盘，
    /// 键盘的选择不被 settle 覆盖。
    func testKeyboardSelectionSurvivesPendingWheelSettle() throws {
        for (keyboardTakesOver, expectedTask) in [
            (true, "task-2.md"),   // 键盘接管：回车选的是键盘移到的行
            (false, "task-4.md"),  // 没碰键盘：settle 后高亮指针下那行
        ] {
            try checkWheelSettle(keyboardTakesOver: keyboardTakesOver, expectedTask: expectedTask)
        }
    }

    private func checkWheelSettle(keyboardTakesOver: Bool, expectedTask: String) throws {
        let (panel, search, scroll) = try makeTaskList()
        let window = PointerTestWindow(contentRect: panel.frame, styleMask: .borderless,
                                       backing: .buffered, defer: false)
        window.contentView = panel
        panel.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap(scroll.documentView?.subviews[3])
        window.pointer = row.convert(NSPoint(x: 20, y: 12), to: nil)
        let cgEvent = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                           wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0))
        scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: cgEvent)))
        if keyboardTakesOver {
            _ = panel.control(search, textView: NSTextView(),
                              doCommandBy: #selector(NSResponder.moveDown(_:)))
        }
        let settled = expectation(description: "Scroll settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { settled.fulfill() }
        wait(for: [settled], timeout: 1)

        var picked: URL?
        panel.onBindTask = { picked = $0 }
        _ = panel.control(search, textView: NSTextView(),
                          doCommandBy: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(picked?.lastPathComponent, expectedTask)
    }

    /// 回车绑定高亮行、⌘回车新建；输入与已有任务模糊匹配时也必须能新建。
    /// 真实按键走字段编辑器：⌘回车没有默认命令，漏处理就是按了没反应。
    func testPartialMatchStillAllowsCreatingANewTask() throws {
        let (panel, search, _) = try makeTaskList()
        let window = PaneIdentityWindow(content: panel)
        defer { window.orderOut(nil) }
        window.makeKeyAndOrderFrontInvisibly()
        panel.focusInitialField()
        filter("Task 1", panel: panel, search: search)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.string = "Task 1"

        var bound: URL?, created: String?, dismissed = 0
        panel.onBindTask = { bound = $0 }
        panel.onCreateTask = { created = $0 }
        panel.onDismiss = { dismissed += 1 }
        let commandReturn = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        NSApp.sendEvent(commandReturn)

        XCTAssertEqual(created, "Task 1")
        XCTAssertNil(bound)
        XCTAssertEqual(dismissed, 1, "选定后回到终端")
    }

    /// 看外观用：scripts/snapshot.sh PaneIdentityPanelTests/testCaptureSnapshots
    func testCaptureSnapshots() throws {
        guard let path = ProcessInfo.processInfo.environment["LIGHTTY_UI_SNAPSHOT_DIR"] else { return }
        _ = NSApplication.shared
        ensureTerminalRuntime()
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func save(_ view: NSView, _ name: String) throws {
            view.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(name + ".png"))
        }
        var windows: [NSWindow] = []
        defer { windows.forEach { $0.orderOut(nil) } }
        let now = Date()
        let choices: [PaneIdentityPanel.TaskChoice] = [
            .init(name: "mobile 开发", fileURL: URL(fileURLWithPath: "/tmp/a.md"), running: true, current: false,
                  directory: "/work/foodmaxapp", updated: now, nearby: true),
            .init(name: "检查搜索页键盘遮挡与商卡 title 对齐的很长任务名", fileURL: URL(fileURLWithPath: "/tmp/b.md"), running: false, current: true,
                  directory: "/work/foodmaxapp", updated: now.addingTimeInterval(-7200), nearby: true),
            .init(name: "backend-java 领域语言学习", fileURL: URL(fileURLWithPath: "/tmp/c.md"), running: false, current: false,
                  directory: "/work/backend-java-service-with-long-name", updated: now.addingTimeInterval(-172800)),
            .init(name: "lightty 优化", fileURL: URL(fileURLWithPath: "/tmp/d.md"), running: false, current: false,
                  directory: "/work/lightty", updated: now.addingTimeInterval(-259200)),
        ]
        let summary = "**现状 (2026-09-21 核实)**：main 在 `dd674ed`，与 origin 同步\n\n1. **等用户真机验证通知改动**（v0.20.2 里已包含，尚未验收，这一行故意写得很长看折行效果）\n   - 同一个 pane 连着完成两次 → 通知中心里只剩最新一条。\n2. **`RefreshButtonTests.customGlyphRendersLikeNative`** 偶发失败\n3. 通知相关\n4. 第四项\n5. 第五项\n6. 第六项"
        for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let aqua = NSAppearance(named: appearance)
            func makePanel(task: String?, knownAgent: Bool = true) -> (PaneIdentityPanel, NSView) {
                let panel = PaneIdentityPanel()
                panel.appearance = aqua
                panel.frame = NSRect(x: 0, y: 0, width: PaneIdentityPanel.panelWidth, height: PaneIdentityPanel.maxHeight)
                panel.taskProvider = { choices }
                panel.taskDetailProvider = { .init(directory: "/Users/example/project/foodmaxapp", updated: "2 小时前", summary: summary) }
                panel.handoffActionProvider = { knownAgent ? .ready : nil }
                panel.update(paneName: "搜索结果页商卡 title 对齐", taskName: task, dot: .systemGreen, agent: .claude)
                panel.onIslandHeightChange = { [weak panel] height in
                    guard let panel else { return }
                    panel.applyIslandFrame(PaneIdentityMorphGeometry.expandedIslandFrame(in: panel.bounds, height: height), duration: 0)
                }
                panel.applyIslandFrame(PaneIdentityMorphGeometry.expandedIslandFrame(in: panel.bounds, height: panel.currentIslandHeight), duration: 0)
                let backdrop = NSView(frame: panel.bounds.insetBy(dx: -16, dy: -16))
                backdrop.appearance = aqua
                backdrop.wantsLayer = true
                backdrop.layer?.backgroundColor = (appearance == .aqua ? NSColor.white : NSColor(white: 0.13, alpha: 1)).cgColor
                panel.frame.origin = NSPoint(x: 16, y: 16)
                backdrop.addSubview(panel)
                // 文字量度依赖窗口的 backing，离屏量出来的宽度和绘制对不上。
                let window = NSWindow(contentRect: backdrop.bounds, styleMask: .borderless,
                                      backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = backdrop
                window.orderFrontRegardless()
                windows.append(window)
                return (panel, backdrop)
            }
            let (detail, detailHost) = makePanel(task: "mobile 开发")
            _ = detail
            try save(detailHost, "identity-detail-\(appearanceName)")
            let (_, noAgentHost) = makePanel(task: "lightty 优化", knownAgent: false)
            try save(noAgentHost, "identity-detail-no-agent-\(appearanceName)")

            let (picker, pickerHost) = makePanel(task: "mobile 开发")
            picker.openTaskPicker()
            RunLoop.main.run(until: Date().addingTimeInterval(0.8)) // 等翻页动画走完；切外观后第一帧可能卡几百毫秒
            try save(pickerHost, "identity-picker-\(appearanceName)")
            let search = try XCTUnwrap(picker.descendants.compactMap { $0 as? NSTextField }
                .first { $0.placeholderAttributedString?.string == L("Search name or folder, or type a new name") })
            filter("mobile", panel: picker, search: search)
            try save(pickerHost, "identity-picker-query-\(appearanceName)")

            for (name, width, task, title) in [
                ("wide-bound", 900.0, "mobile 开发", "搜索结果页商卡 title 对齐"),
                ("wide-unbound", 900.0, nil, "Terminal 3"),
                ("mid-long", 420.0, "检查搜索页键盘遮挡与商卡 title 对齐", "ai-search-service 和 image-audit 接口日志查询"),
                ("narrow", 170.0, "mobile 开发", "ai-search-service 和 image-audit"),
            ] as [(String, CGFloat, String?, String)] {
                let header = PaneHeaderView()
                header.appearance = aqua
                header.applyTerminalTheme(background: appearance == .aqua ? .white : NSColor(white: 0.13, alpha: 1),
                                          foreground: appearance == .aqua ? .black : .white)
                header.frame = NSRect(x: 0, y: 0, width: width, height: PaneHeaderView.height)
                header.sessionAgent = .claude
                header.title = title
                header.setTaskName(task)
                let window = NSWindow(contentRect: header.bounds, styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView?.addSubview(header)
                window.orderFrontRegardless()
                windows.append(window)
                try save(header, "capsule-\(name)-\(appearanceName)")
            }
        }
    }

    /// 按钮在 mouseUp 触发，落点要在按钮里。
    private func click(_ view: NSView) throws {
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown))
        view.mouseUp(with: try event(.leftMouseUp))
    }

    /// agent 正忙时这一行还在（藏掉等于让用户以为没这功能），但点不动、给出理由。
    func testSummarizeRowIsDisabledWhileTheAgentIsBusy() throws {
        _ = NSApplication.shared
        let panel = PaneIdentityPanel()
        panel.frame = NSRect(x: 0, y: 0, width: PaneIdentityPanel.panelWidth,
                             height: PaneIdentityPanel.maxHeight)
        panel.handoffActionProvider = { .blocked(reason: L("Busy")) }
        var sent = 0
        panel.onUpdateHandoff = { sent += 1; return true }
        panel.update(paneName: "Terminal", taskName: "Some task", dot: .systemGray, agent: .claude)
        panel.layoutSubtreeIfNeeded()

        let row = try XCTUnwrap(panel.descendants.first {
            $0.identifier == PaneIdentityPanel.handoffRowIdentifier
        })
        let titles = row.descendants.compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(titles.contains(L("Busy")), "要说明为什么点不动")

        try click(row)
        XCTAssertEqual(sent, 0, "禁用行不能把指令送出去")
    }

    private func makeTaskList(openWith open: (PaneIdentityPanel) -> Void = { $0.toggleTaskList() }) throws -> (PaneIdentityPanel, NSTextField, NSScrollView) {
        _ = NSApplication.shared
        let panel = PaneIdentityPanel()
        panel.frame = NSRect(x: 0, y: 0, width: PaneIdentityPanel.panelWidth,
                             height: PaneIdentityPanel.maxHeight)
        panel.taskProvider = {
            (1...20).map { .init(name: "Task \($0)",
                                fileURL: URL(fileURLWithPath: "/tmp/task-\($0).md"),
                                running: false, current: false) }
        }
        panel.layoutSubtreeIfNeeded()
        open(panel)
        panel.layoutSubtreeIfNeeded()
        let search = try XCTUnwrap(panel.descendants.compactMap { $0 as? NSTextField }
            .first { $0.placeholderAttributedString?.string == L("Search name or folder, or type a new name") })
        let scroll = try XCTUnwrap(panel.descendants.compactMap { $0 as? NSScrollView }.first)
        return (panel, search, scroll)
    }

    private func filter(_ query: String, panel: PaneIdentityPanel, search: NSTextField) {
        search.stringValue = query
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        panel.layoutSubtreeIfNeeded()
    }
}

private final class PointerTestWindow: NSWindow {
    var pointer = NSPoint.zero
    override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
}

private extension NSView {
    var descendants: [NSView] {
        subviews + subviews.flatMap(\.descendants)
    }
}
