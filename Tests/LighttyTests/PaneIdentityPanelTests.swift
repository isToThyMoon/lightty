import AppKit
import LighttyCore
import XCTest
@testable import lightty

@MainActor
final class PaneIdentityPanelTests: XCTestCase {
    /// 形变的核心不变式：岛体在长，内容在面板坐标系里必须纹丝不动。
    ///
    /// 内容住在岛体的裁剪层里，frame 原点取岛体原点的相反数——所以岛体长开只是
    /// 「露出更多」，内容一个像素都不许挪。第一行还要和 header 上的胶囊逐像素交接，
    /// 挪了就穿帮。内容必须住在岛体里：放在岛体外面就不受裁剪，岛体还只有胶囊大小时，
    /// 底下已经躺着一整屏列表——那就是"整块区域从上往下砸下来"的由来。
    ///
    /// 场景：先钉结构前提（列表与搜索框都在岛体裁剪层里），再同步形变一次看内容原点与
    /// 标题不动，然后起真动画：起点是当前 frame、内容不动；动画中途顶边/中线/标题不动；
    /// 可逆，被取消的 completion 不跑。
    func testIslandMorphKeepsContentAndTopEdgeFixedAndCanReverse() throws {
        _ = NSApplication.shared
        // 结构前提：搜索框与列表都住在岛体的裁剪层里。
        let (listPanel, search, scroll) = try makeTaskList()
        for view in [search, scroll] {
            var ancestor = view.superview
            var insideIsland = false
            while let current = ancestor {
                if current === listPanel.island { insideIsland = true; break }
                ancestor = current.superview
            }
            XCTAssertTrue(insideIsland, "\(type(of: view)) 必须在岛体的裁剪层里")
        }

        let panel = PaneIdentityPanel()
        panel.frame = NSRect(x: 0, y: 0, width: 496, height: PaneIdentityPanel.maxHeight)
        panel.update(paneName: "Long session title", taskName: "Bound task", dot: .systemGray, agent: .claude)
        let window = PaneIdentityWindow(content: panel)
        defer { window.orderOut(nil) }
        let start = NSRect(x: 8, y: panel.bounds.height - 20, width: 480, height: 20)
        let end = PaneIdentityMorphGeometry.expandedIslandFrame(in: panel.bounds, height: 280)
        panel.setIdentityAnchorOffset(start.minX)
        panel.applyIslandFrame(start, duration: 0)
        window.orderFrontInvisibly()
        panel.layoutSubtreeIfNeeded()
        let title = try XCTUnwrap(panel.descendants.compactMap { $0 as? NSTextField }.first {
            $0.stringValue == "Long session title"
        })
        let titleFrame = panel.convert(title.bounds, from: title)
        let origin = panel.identityRowOriginInPanel

        // 同步形变（必须走形变入口：直接给 island.frame 赋值会把内容一起带偏，这也正是
        // `applyIslandFrame` 存在的理由）：岛体长开，内容原点与标题（图标、文字）纹丝不动。
        panel.applyIslandFrame(end, duration: 0)
        panel.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.identityRowOriginInPanel.x, origin.x, accuracy: 0.001)
        XCTAssertEqual(panel.identityRowOriginInPanel.y, origin.y, accuracy: 0.001)
        let grownTitle = panel.convert(title.bounds, from: title)
        XCTAssertEqual(grownTitle.minX, titleFrame.minX, accuracy: 0.001)
        XCTAssertEqual(grownTitle.midY, titleFrame.midY, accuracy: 0.001)
        panel.applyIslandFrame(start, duration: 0)
        panel.layoutSubtreeIfNeeded()

        // 真动画：起点是当前显示的 frame，内容不动。
        var cancelledCompletionRan = false
        panel.applyIslandFrame(end, duration: 0.3) { cancelledCompletionRan = true }
        XCTAssertEqual(panel.islandFrame, start)
        XCTAssertEqual(panel.identityRowOriginInPanel, origin)
        let sampled = expectation(description: "Sample visible morph")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            XCTAssertEqual(panel.islandFrame.maxY, start.maxY, accuracy: 0.001)
            XCTAssertEqual(panel.islandFrame.midX, start.midX, accuracy: 0.001)
            XCTAssertEqual(panel.convert(title.bounds, from: title), titleFrame)
            XCTAssertGreaterThan(panel.islandFrame.height, start.height)
            let current = panel.islandFrame
            panel.applyIslandFrame(start, duration: 0.08) {
                XCTAssertEqual(panel.islandFrame, start)
                XCTAssertEqual(panel.convert(title.bounds, from: title), titleFrame)
                XCTAssertFalse(cancelledCompletionRan)
                sampled.fulfill()
            }
            XCTAssertEqual(panel.islandFrame, current, "Reversal starts at the displayed frame")
        }
        wait(for: [sampled], timeout: 2)
    }

    func testFilteringScrolledListKeepsReturnTargetVisible() throws {
        let (panel, search, scroll) = try makeTaskList()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
        scroll.reflectScrolledClipView(scroll.contentView)

        filter("Task", panel: panel, search: search)

        let firstRow = try XCTUnwrap(scroll.documentView?.subviews.first)
        XCTAssertTrue(scroll.documentVisibleRect.contains(firstRow.frame))
        var picked: URL?
        panel.onBindTask = { picked = $0 }
        _ = panel.control(search, textView: NSTextView(),
                          doCommandBy: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(picked?.lastPathComponent, "task-1.md")
    }

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

    /// 任务选择器的路径：无论绑没绑都能作为入口打开；esc 从入口进来时直接回终端，
    /// 从详情态进来时只退回详情态。
    func testEscLeavesThePickerAccordingToHowItWasOpened() throws {
        for asEntryPoint in [true, false] {
            let (panel, search, _) = try makeTaskList(openWith: { asEntryPoint ? $0.openTaskPicker() : $0.toggleTaskList() })
            var dismissed = 0
            panel.onDismiss = { dismissed += 1 }
            _ = panel.control(search, textView: NSTextView(),
                              doCommandBy: #selector(NSResponder.cancelOperation(_:)))
            XCTAssertFalse(panel.isTaskListOpen)
            XCTAssertEqual(dismissed, asEntryPoint ? 1 : 0)
        }
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

    /// 没有匹配时普通回车就是新建。
    func testReturnCreatesWhenNothingMatches() throws {
        let (panel, search, _) = try makeTaskList()
        filter("zzz", panel: panel, search: search)
        var created: String?
        panel.onCreateTask = { created = $0 }
        _ = panel.control(search, textView: NSTextView(),
                          doCommandBy: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(created, "zzz")
    }

    func testChoicesRankByRelevanceToThisTerminal() {
        func choice(_ name: String, _ folder: String, nearby: Bool = false) -> PaneIdentityPanel.TaskChoice {
            .init(name: name, fileURL: URL(fileURLWithPath: "/tmp/\(name).md"), running: false, current: false,
                  directory: "/work/\(folder)", nearby: nearby)
        }
        let choices = [choice("alpha", "web"), choice("beta", "api", nearby: true), choice("gamma", "alpha-app")]
        let cases: [(query: String, expected: [String], why: String)] = [
            ("", ["beta", "alpha", "gamma"], "无输入：此目录的任务提前，其余保持最近更新序"),
            ("alpha", ["alpha", "gamma"], "名字命中排在目录命中之前"),
            ("api", ["beta"], "可以按目录搜到任务"),
            ("work", [], "只匹配末级目录，否则路径前缀让什么都能搜到"),
        ]
        for c in cases {
            XCTAssertEqual(PaneIdentityPanel.rank(choices, query: c.query).map(\.name), c.expected, c.why)
        }
    }

    /// 选择器开着时详情让位；关上后回来。Agent 写回后 update 带来新摘要。
    func testDetailShowsTheHandoffAndYieldsToThePicker() {
        _ = NSApplication.shared
        let panel = PaneIdentityPanel()
        panel.frame = NSRect(x: 0, y: 0, width: PaneIdentityPanel.panelWidth, height: PaneIdentityPanel.maxHeight)
        var summary = "First summary"
        panel.taskDetailProvider = { .init(directory: "/work/app", updated: "1h", summary: summary) }
        panel.taskProvider = { [] }
        panel.update(paneName: "Terminal", taskName: "Bound", dot: .systemGray, agent: nil)
        func visibleTexts() -> [String] {
            panel.descendants.filter { !$0.isHiddenOrHasHiddenAncestor }.compactMap { ($0 as? NSTextField)?.stringValue }
        }
        XCTAssertTrue(visibleTexts().contains("First summary"))

        panel.toggleTaskList()
        XCTAssertFalse(visibleTexts().contains("First summary"))
        panel.toggleTaskList()

        summary = "Updated by agent"
        panel.update(paneName: "Terminal", taskName: "Bound", dot: .systemGray, agent: nil)
        XCTAssertTrue(visibleTexts().contains("Updated by agent"))
    }

    /// 胶囊两块点击区分流，任务区收窄时只收文字、不消失（否则入口又藏起来了）。
    func testCapsuleRoutesClicksAndKeepsTheTaskEntryWhenNarrow() throws {
        _ = NSApplication.shared
        ensureTerminalRuntime()
        let header = PaneHeaderView()
        header.title = "Terminal"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView?.addSubview(header)
        header.frame = NSRect(x: 0, y: 0, width: 600, height: PaneHeaderView.height)
        header.layoutSubtreeIfNeeded()
        XCTAssertEqual(header.taskChipText, L("Task"))

        var opened: [String] = []
        header.onTaskChipTapped = { opened.append("chip") }
        header.onIdentityTapped = { opened.append("name") }
        header.dispatchTap(atWindowPoint: header.taskChipCenterInWindow)
        let dot = NSPoint(x: header.capsuleFrame.minX + PaneIdentityMetrics.dotLeading, y: header.capsuleFrame.midY)
        header.dispatchTap(atWindowPoint: header.convert(dot, to: nil))
        XCTAssertEqual(opened, ["chip", "name"])

        header.setTaskName("A rather long task name that cannot fit")
        header.frame.size.width = 90
        header.layoutSubtreeIfNeeded()
        XCTAssertEqual(header.taskChipText, "", "窄时只留图标")
        opened = []
        header.dispatchTap(atWindowPoint: header.taskChipCenterInWindow)
        XCTAssertEqual(opened, ["chip"], "窄到只剩图标也能点")
    }

    /// 侧栏「绑定到当前终端」：目标是活动终端，已绑着这个任务时不提供。
    func testSidebarBindTargetIsTheActivePaneUnlessAlreadyBound() throws {
        _ = NSApplication.shared
        ensureTerminalRuntime()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bind-target-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = AppState.shared
        defer { AppState.shared = previous }
        AppState.shared = AppState(taskDirectory: root, sweepStalePanes: false)
        let pane = PaneView()
        let controller = TerminalWindowController(initialPane: pane)
        defer { controller.window?.close() }
        let first = try AppState.shared.taskBindings.store.create(name: "First", workdir: "/tmp")
        let second = try AppState.shared.taskBindings.store.create(name: "Second", workdir: "/tmp")
        XCTAssertNil(HandoffSidebarContent.bindTarget(for: first.fileURL, in: nil), "没有窗口就没有目标")
        XCTAssertTrue(HandoffSidebarContent.bindTarget(for: first.fileURL, in: controller) === pane)

        pane.bind(to: first.fileURL, name: "First")
        XCTAssertNil(HandoffSidebarContent.bindTarget(for: first.fileURL, in: controller))
        XCTAssertTrue(HandoffSidebarContent.bindTarget(for: second.fileURL, in: controller) === pane, "换绑其他任务")
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

    /// 摘要是预览：去标记符、去空行、限行数。Agent 写的 handoff 动辄几十行，
    /// 不限就会把岛体撑出面板，底部按钮被裁掉。
    func testHandoffSummaryIsAPlainBoundedPreview() {
        let markdown = "**现状**：main 在 `dd674ed`\n\n## Next\n1. **`Foo.bar` 未验证**\n" + (2...30).map { "\($0). item" }.joined(separator: "\n")
        let text = HandoffSummaryText.attributed(markdown, font: ShellStyle.Font.compactBody, color: .labelColor).string
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, HandoffSummaryText.maximumLines)
        XCTAssertEqual(lines[0], "现状：main 在 dd674ed")
        XCTAssertEqual(lines[1], "1. Foo.bar 未验证")
        XCTAssertEqual(HandoffSummaryText.attributed("a **b `c", font: ShellStyle.Font.compactBody, color: .labelColor).string,
                       "a **b `c", "配不上对的标记保留原文")

        _ = NSApplication.shared
        let panel = PaneIdentityPanel()
        panel.frame = NSRect(x: 0, y: 0, width: PaneIdentityPanel.panelWidth, height: PaneIdentityPanel.maxHeight)
        let wrapping = String(repeating: "很长的一行摘要会折行 ", count: 200)
        panel.taskDetailProvider = { .init(directory: "/work", updated: "1h", summary: wrapping) }
        panel.handoffActionProvider = { .ready }
        panel.update(paneName: "Terminal", taskName: "Bound", dot: .systemGray, agent: .claude)
        XCTAssertLessThanOrEqual(panel.currentIslandHeight, PaneIdentityPanel.maxHeight)
    }

    /// 「让 Agent 总结」在第一层，点一次胶囊就能看到、不必先展开任务列表。
    /// 它原先在任务列表底部，够着它要点两次（胶囊 → 任务行）。这是任务进行中反复
    /// 要做的动作，不该藏在管归属的那一层里。
    ///
    /// 出现条件是一张表：provider 有无（认不认得出 agent）× 绑没绑任务 → 这一行在不在，
    /// 以及岛体高度——没有这一行时岛体不该为它留空。
    func testSummarizeRowAppearsOnlyWithABoundTaskAndAKnownAgent() throws {
        _ = NSApplication.shared
        struct Case {
            let name: String
            let provider: (() -> PaneIdentityPanel.HandoffAction?)?
            let taskName: String?
            let present: Bool
        }
        let cases: [Case] = [
            // 认得出 agent 且绑了任务：第一层就该有这一行。
            Case(name: "known agent with a bound task", provider: { .ready }, taskName: "Some task", present: true),
            // 认不出 agent 就没有这一行，而且岛体不该为它留空。
            Case(name: "unknown agent", provider: nil, taskName: "Some task", present: false),
            // 没绑任务就没有这一行：没有可写回的地址，摆出来只是噪音。
            Case(name: "no bound task", provider: { .ready }, taskName: nil, present: false),
        ]
        for c in cases {
            let panel = PaneIdentityPanel()
            panel.frame = NSRect(x: 0, y: 0, width: PaneIdentityPanel.panelWidth,
                                 height: PaneIdentityPanel.maxHeight)
            panel.handoffActionProvider = c.provider
            panel.update(paneName: "Terminal", taskName: c.taskName, dot: .systemGray, agent: .claude)
            panel.layoutSubtreeIfNeeded()

            let row = panel.descendants.first { $0.identifier == PaneIdentityPanel.handoffRowIdentifier }
            XCTAssertEqual(row != nil, c.present, c.name)
            XCTAssertEqual(
                panel.currentIslandHeight,
                PaneIdentityPanel.baseHeight + (c.present ? PaneIdentityPanel.handoffRowSpace : 0),
                "\(c.name)：没有这一行时岛体不该凭空多出一块空白")
            if let row {
                let titles = row.descendants.compactMap { ($0 as? NSTextField)?.stringValue }
                XCTAssertTrue(titles.contains(L("Have the Agent summarize it")), c.name)
            }
        }
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

    /// 送不出去时不关面板——关掉等于告诉用户"做了"。
    func testAFailedSendKeepsThePanelOpen() throws {
        _ = NSApplication.shared
        let panel = PaneIdentityPanel()
        panel.frame = NSRect(x: 0, y: 0, width: PaneIdentityPanel.panelWidth,
                             height: PaneIdentityPanel.maxHeight)
        panel.handoffActionProvider = { .ready }
        panel.onUpdateHandoff = { false }
        var dismissed = 0
        panel.onDismiss = { dismissed += 1 }
        panel.update(paneName: "Terminal", taskName: "Some task", dot: .systemGray, agent: .claude)
        panel.layoutSubtreeIfNeeded()

        let row = try XCTUnwrap(panel.descendants.first {
            $0.identifier == PaneIdentityPanel.handoffRowIdentifier
        })
        try click(row)
        XCTAssertEqual(dismissed, 0)
    }

    /// 胶囊与灵动岛第一行必须逐像素同构：展开时胶囊瞬间隐身、第一行顶上，收起反过来。
    /// 差一个像素，交接那一帧就能看见文字跳——胶囊加了 agent 图标而岛体没跟上时，
    /// 文字整整往回缩了 14pt。
    func testIslandFirstRowKeepsTheCapsuleTitleOffset() {
        _ = NSApplication.shared
        ensureTerminalRuntime()
        for agent in [SessionAgent?.none, .some(.claude), .some(.codex)] {
            let header = PaneHeaderView()
            header.frame = NSRect(x: 0, y: 0, width: 400, height: PaneHeaderView.height)
            header.sessionAgent = agent
            header.title = "Terminal"
            header.layoutSubtreeIfNeeded()

            let panel = PaneIdentityPanel()
            panel.frame = NSRect(x: 0, y: 0, width: PaneIdentityPanel.panelWidth,
                                 height: PaneIdentityPanel.maxHeight)
            panel.update(paneName: "Terminal", taskName: nil, dot: .systemGray, agent: agent)
            panel.layoutSubtreeIfNeeded()

            XCTAssertEqual(panel.titleOffsetFromDot, header.titleOffsetFromDot, accuracy: 0.001,
                           "agent = \(String(describing: agent))")
        }
    }

    /// 真实窗口里 pane 先以 0 宽创建：胶囊宽度上限若是必需约束就会无解，布局引擎
    /// 断掉的恰是图标宽度且不再恢复，图标撑到 SVG 的 24pt，点和名字间多出一截空隙。
    func testCapsuleIconKeepsItsWidthWhenThePaneStartsWithZeroWidth() throws {
        _ = NSApplication.shared
        ensureTerminalRuntime()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("capsule-icon-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        AppState.shared = AppState(taskDirectory: root, sweepStalePanes: false)
        let pane = PaneView()
        let controller = TerminalWindowController(initialPane: pane)
        defer { controller.window?.close() }
        pane.header.sessionAgent = .claude
        pane.header.title = "ai-search-service和image-audit接口日志查询"
        controller.window?.setContentSize(NSSize(width: 900, height: 500))
        controller.window?.layoutIfNeeded()
        let icon = try XCTUnwrap(pane.header.descendants.first { $0 is NSImageView })
        XCTAssertEqual(icon.frame.width, PaneIdentityMetrics.iconSize)
    }

    /// 关闭键长在圆点插槽里，只在胶囊 hover 时出现。hover 区若按某一刻的胶囊 frame
    /// 算死，标题从「Terminal」换成长会话标题、胶囊向两侧变宽后，圆点落在旧区域外，
    /// 鼠标移到圆点上关闭键就消失。
    func testCapsuleHoverAreaFollowsTheCapsuleWhenTheTitleGrows() throws {
        _ = NSApplication.shared
        ensureTerminalRuntime()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("capsule-hover-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        AppState.shared = AppState(taskDirectory: root, sweepStalePanes: false)
        let pane = PaneView()
        let controller = TerminalWindowController(initialPane: pane)
        defer { controller.window?.close() }
        controller.window?.setContentSize(NSSize(width: 900, height: 500))
        controller.window?.layoutIfNeeded()
        let header = pane.header
        header.updateTrackingAreas()
        header.title = "ai-search-service和image-audit接口日志查询"
        controller.window?.layoutIfNeeded()

        let dot = header.capsuleFrame.minX + PaneIdentityMetrics.dotLeading + PaneIdentityMetrics.dotSize / 2
        let point = NSPoint(x: dot, y: header.capsuleFrame.midY)
        let hoverRects = header.descendants.flatMap { view in
            view.trackingAreas
                .filter { $0.owner === header && !$0.options.contains(.activeAlways) }
                .map { header.convert($0.options.contains(.inVisibleRect) ? view.visibleRect : $0.rect, from: view) }
        } + header.trackingAreas
            .filter { $0.owner === header && !$0.options.contains(.activeAlways) }
            .map(\.rect)
        XCTAssertFalse(hoverRects.isEmpty)
        XCTAssertTrue(hoverRects.allSatisfy { $0.contains(point) }, "\(hoverRects) vs capsule \(header.capsuleFrame)")
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

    /// `PaneIdentityMorphGeometry` 纯函数：面板包住胶囊（再长的胶囊也不许探出面板），
    /// 展开时中线不变、顶边不变、左右等量外扩、只向下长。
    func testMorphExpandsEquallyLeftAndRightAndOnlyDownward() {
        // 面板要包住胶囊：绑了长任务名时胶囊可以很宽。
        let long = NSRect(x: 100, y: 600, width: 480, height: 20)
        let around = PaneIdentityMorphGeometry.panelFrame(around: long)
        XCTAssertGreaterThanOrEqual(around.width, long.width)
        XCTAssertLessThanOrEqual(around.minX, long.minX)
        XCTAssertGreaterThanOrEqual(around.maxX, long.maxX)

        let capsule = NSRect(x: 410, y: 612, width: 96, height: 20)
        let panel = PaneIdentityMorphGeometry.panelFrame(around: capsule)
        // 胶囊在面板坐标系里的位置。生产路径靠坐标转换拿到同一个结果——面板在
        // 子窗口里是内缩的，那边不能拿 frame 相减。
        let collapsed = NSRect(x: capsule.minX - panel.minX, y: capsule.minY - panel.minY,
                               width: capsule.width, height: capsule.height)
        let expanded = PaneIdentityMorphGeometry.expandedIslandFrame(
            in: NSRect(origin: .zero, size: panel.size),
            height: PaneIdentityPanel.baseHeight)

        XCTAssertEqual(panel.midX, capsule.midX, accuracy: 0.001)
        XCTAssertEqual(collapsed.midX, expanded.midX, accuracy: 0.001)
        XCTAssertEqual(collapsed.maxY, expanded.maxY, accuracy: 0.001)
        XCTAssertEqual(
            collapsed.minX - expanded.minX,
            expanded.maxX - collapsed.maxX,
            accuracy: 0.001)
        XCTAssertLessThan(expanded.minY, collapsed.minY)
    }

    func testLongTaskListUsesAViewportInsideTheIsland() throws {
        _ = NSApplication.shared

        let panel = PaneIdentityPanel()
        panel.frame = NSRect(
            x: 0,
            y: 0,
            width: PaneIdentityPanel.panelWidth,
            height: PaneIdentityPanel.maxHeight)
        panel.taskProvider = {
            (1...12).map { index in
                PaneIdentityPanel.TaskChoice(
                    name: "Task \(index)",
                    fileURL: URL(fileURLWithPath: "/tmp/task-\(index).md"),
                    running: false,
                    current: false)
            }
        }
        panel.onIslandHeightChange = { [weak panel] height in
            guard let panel else { return }
            panel.island.frame = NSRect(
                x: 0,
                y: panel.bounds.height - height,
                width: PaneIdentityPanel.panelWidth,
                height: height)
        }

        panel.layoutSubtreeIfNeeded()
        panel.toggleTaskList()
        panel.layoutSubtreeIfNeeded()

        let lastTaskLabel = try XCTUnwrap(
            panel.descendants.compactMap { $0 as? NSTextField }.first {
                $0.stringValue == "Task 12"
            })
        let viewport = try XCTUnwrap(
            lastTaskLabel.enclosingScrollView,
            "A task list longer than the seven-row island must scroll instead of drawing below it")
        let viewportFrame = panel.convert(viewport.bounds, from: viewport)
        let documentView = try XCTUnwrap(viewport.documentView)

        XCTAssertTrue(
            panel.island.frame.contains(viewportFrame),
            "The scrolling viewport must remain within the visible island background")
        XCTAssertGreaterThan(
            documentView.bounds.height,
            viewport.documentVisibleRect.height,
            "Overflowing task rows must remain reachable by scrolling")
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
