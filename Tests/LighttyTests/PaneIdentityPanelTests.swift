import AppKit
import LighttyCore
import XCTest
@testable import lightty

@MainActor
final class PaneIdentityPanelTests: XCTestCase {
    func testExpandedIslandContainsLongBoundCapsule() {
        let capsule = NSRect(x: 100, y: 600, width: 480, height: 20)
        let panel = PaneIdentityMorphGeometry.panelFrame(around: capsule)
        XCTAssertGreaterThanOrEqual(panel.width, capsule.width)
        XCTAssertLessThanOrEqual(panel.minX, capsule.minX)
        XCTAssertGreaterThanOrEqual(panel.maxX, capsule.maxX)
    }

    func testAnimationStartsAtDisplayedFrameWithoutMovingContent() {
        _ = NSApplication.shared
        let panel = PaneIdentityPanel()
        panel.frame = NSRect(x: 0, y: 0, width: 272, height: PaneIdentityPanel.maxHeight)
        let start = NSRect(x: 80, y: panel.bounds.height - 20, width: 112, height: 20)
        panel.applyIslandFrame(start, duration: 0)
        panel.layoutSubtreeIfNeeded()
        let origin = panel.identityRowOriginInPanel
        panel.applyIslandFrame(
            PaneIdentityMorphGeometry.expandedIslandFrame(in: panel.bounds, height: 250),
            duration: 0.24)
        XCTAssertEqual(panel.islandFrame, start)
        XCTAssertEqual(panel.identityRowOriginInPanel, origin)
        panel.applyIslandFrame(start, duration: 0)
    }

    func testVisibleAnimationKeepsTitleAndTopEdgeFixedAndCanReverse() throws {
        _ = NSApplication.shared
        let panel = PaneIdentityPanel()
        panel.frame = NSRect(x: 0, y: 0, width: 496, height: PaneIdentityPanel.maxHeight)
        panel.update(paneName: "Long session title", taskName: "Bound task", dot: .systemGray, agent: .claude)
        let window = PaneIdentityWindow(content: panel)
        defer { window.orderOut(nil) }
        let start = NSRect(x: 8, y: panel.bounds.height - 20, width: 480, height: 20)
        let end = PaneIdentityMorphGeometry.expandedIslandFrame(in: panel.bounds, height: 280)
        panel.setIdentityAnchorOffset(start.minX)
        panel.applyIslandFrame(start, duration: 0)
        window.orderFront(nil)
        panel.layoutSubtreeIfNeeded()
        let title = try XCTUnwrap(panel.descendants.compactMap { $0 as? NSTextField }.first {
            $0.stringValue == "Long session title"
        })
        let titleFrame = panel.convert(title.bounds, from: title)
        var cancelledCompletionRan = false
        panel.applyIslandFrame(end, duration: 0.3) { cancelledCompletionRan = true }
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

    func testKeyboardSelectionSurvivesPendingWheelSettle() throws {
        try checkWheelSettle(keyboardTakesOver: true, expectedTask: "task-2.md")
    }

    func testWheelSettleHighlightsRowUnderPointer() throws {
        try checkWheelSettle(keyboardTakesOver: false, expectedTask: "task-4.md")
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

    /// 形变的核心不变式：岛体在长，内容在面板坐标系里必须纹丝不动。
    ///
    /// 内容住在岛体的裁剪层里，frame 原点取岛体原点的相反数——所以岛体长开只是
    /// 「露出更多」，内容一个像素都不许挪。第一行还要和 header 上的胶囊逐像素交接，
    /// 挪了就穿帮。
    func testContentStaysPutWhileTheIslandGrows() throws {
        _ = NSApplication.shared
        let panel = PaneIdentityPanel()
        panel.frame = NSRect(x: 0, y: 0, width: PaneIdentityPanel.panelWidth,
                             height: PaneIdentityPanel.maxHeight)
        panel.update(paneName: "Terminal", taskName: "Some task", dot: .systemGray, agent: nil)

        let collapsed = NSRect(x: 29, y: PaneIdentityPanel.maxHeight - 20, width: 214, height: 20)
        panel.applyIslandFrame(collapsed, duration: 0)
        panel.layoutSubtreeIfNeeded()
        let before = panel.identityRowOriginInPanel

        let expanded = NSRect(x: 0, y: PaneIdentityPanel.maxHeight - 62,
                              width: PaneIdentityPanel.panelWidth, height: 62)
        panel.applyIslandFrame(expanded, duration: 0)
        panel.layoutSubtreeIfNeeded()

        XCTAssertEqual(panel.identityRowOriginInPanel.x, before.x, accuracy: 0.001)
        XCTAssertEqual(panel.identityRowOriginInPanel.y, before.y, accuracy: 0.001)
    }

    /// 内容必须住在岛体里。放在岛体外面就不受裁剪，岛体还只有胶囊大小时，
    /// 底下已经躺着一整屏列表——那就是"整块区域从上往下砸下来"的由来。
    func testEveryPieceOfContentIsClippedByTheIsland() throws {
        let (panel, search, scroll) = try makeTaskList()
        for view in [search, scroll] {
            var ancestor = view.superview
            var insideIsland = false
            while let current = ancestor {
                if current === panel.island { insideIsland = true; break }
                ancestor = current.superview
            }
            XCTAssertTrue(insideIsland, "\(type(of: view)) 必须在岛体的裁剪层里")
        }
    }

    /// 阴影单独一层并挖空内部：岛体是半透明的，阴影画在它自己的图层上会透上来
    /// 把文字压暗。
    func testIslandShadowIsCutOutSoItCannotDarkenContent() throws {
        _ = NSApplication.shared
        let panel = PaneIdentityPanel()
        panel.frame = NSRect(x: 0, y: 0, width: PaneIdentityPanel.panelWidth,
                             height: PaneIdentityPanel.maxHeight)
        panel.applyIslandFrame(NSRect(x: 0, y: 0, width: 272, height: 62),
                               duration: 0)

        XCTAssertNil(panel.island.layer?.shadowPath, "岛体自己不许画阴影")
        let cutout = try XCTUnwrap(panel.islandShadow.layer?.mask as? CAShapeLayer)
        XCTAssertEqual(cutout.fillRule, .evenOdd, "挖空靠 even-odd，不是靠盖一层")
        XCTAssertNotNil(cutout.path)
        XCTAssertNotNil(panel.islandShadow.layer?.shadowPath)
    }

    /// 任务行必须一眼看得出能点：常驻底色 + 右端箭头 + 左侧「任务」标签。
    /// 它原来和上一行（点了直接打字改 pane 名）一样是透明底的一行字，
    /// 两种行为同一张脸，用户只能靠试。
    func testTaskRowLooksLikeAPickerInsteadOfPlainText() throws {
        _ = NSApplication.shared
        let panel = PaneIdentityPanel()
        panel.frame = NSRect(x: 0, y: 0, width: PaneIdentityPanel.panelWidth,
                             height: PaneIdentityPanel.maxHeight)
        panel.update(paneName: "Terminal", taskName: nil, dot: .systemGray, agent: nil)
        panel.layoutSubtreeIfNeeded()

        let row = try XCTUnwrap(panel.descendants.first {
            $0.identifier == PaneIdentityPanel.taskFieldIdentifier
        })
        let fill = try XCTUnwrap(row.layer?.backgroundColor)
        XCTAssertGreaterThan(fill.alpha, 0, "静息态就该有底色，不能等 hover 才出现")

        let labels = row.descendants.compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(labels.contains(L("Task")), "左侧要有说明这一行是什么的标签")
        XCTAssertTrue(labels.contains(L("Not set")), "未选择时要说“未选择”，不是“绑定任务”")

        let chevrons = row.descendants.compactMap { ($0 as? NSImageView)?.image }
        XCTAssertFalse(chevrons.isEmpty, "右端要有下拉箭头")

        let pencils = panel.descendants.compactMap { ($0 as? NSButton)?.image?
            .accessibilityDescription }
        XCTAssertFalse(pencils.contains(L("Rename task")),
                       "改名不再挂在任务行右边那支铅笔上")
    }

    /// 还没绑任务时，面板一打开就把列表摊开；已经绑了就保持两行。
    func testTaskListOpensOnItsOwnOnlyWhenNoTaskIsBound() {
        _ = NSApplication.shared
        for (taskName, expectsOpen) in [(String?.none, true), (.some("Some task"), false)] {
            let panel = PaneIdentityPanel()
            panel.frame = NSRect(x: 0, y: 0, width: PaneIdentityPanel.panelWidth,
                                 height: PaneIdentityPanel.maxHeight)
            panel.taskProvider = {
                [.init(name: "Some task", fileURL: URL(fileURLWithPath: "/tmp/t.md"),
                       running: false, current: taskName != nil)]
            }
            panel.update(paneName: "Terminal", taskName: taskName, dot: .systemGray, agent: nil)
            panel.expandTaskListForFirstUse()
            XCTAssertEqual(panel.currentIslandHeight > PaneIdentityPanel.baseHeight,
                           expectsOpen, "taskName = \(String(describing: taskName))")
        }
    }

    /// 行只看「点了没」，不看事件内容——但 `NSEvent()` 是个空壳，构造一个真的更稳。
    private func click(_ view: NSView) throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: event)
    }

    /// 「让 Agent 总结」在第一层——任务行正下方，点一次胶囊就能看到。
    ///
    /// 它原先在任务列表底部，够着它要点两次（胶囊 → 任务行）。这是任务进行中反复
    /// 要做的动作，不该藏在管归属的那一层里。
    func testSummarizeRowSitsOnTheFirstLevelUnderTheTaskRow() throws {
        _ = NSApplication.shared
        let panel = PaneIdentityPanel()
        panel.frame = NSRect(x: 0, y: 0, width: PaneIdentityPanel.panelWidth,
                             height: PaneIdentityPanel.maxHeight)
        panel.handoffActionProvider = { .ready }
        panel.update(paneName: "Terminal", taskName: "Some task", dot: .systemGray, agent: .claude)
        panel.layoutSubtreeIfNeeded()

        // 没有展开任何列表，这一行就该在。
        let row = try XCTUnwrap(panel.descendants.first {
            $0.identifier == PaneIdentityPanel.handoffRowIdentifier
        }, "第一层就该有这一行，不必先展开任务列表")
        let taskRow = try XCTUnwrap(panel.descendants.first {
            $0.identifier == PaneIdentityPanel.taskFieldIdentifier
        })
        let rowFrame = panel.convert(row.bounds, from: row)
        let taskFrame = panel.convert(taskRow.bounds, from: taskRow)
        XCTAssertLessThan(rowFrame.maxY, taskFrame.minY + 0.5,
                          "要在任务行下方（面板坐标系 y 向上）")

        let titles = row.descendants.compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(titles.contains(L("Have the Agent summarize it")))
    }

    /// 条件出现：认不出 agent 就没有这一行，而且岛体不该为它留空。
    func testSummarizeRowCostsNoHeightWhenItIsAbsent() {
        _ = NSApplication.shared
        for provider in [nil, { PaneIdentityPanel.HandoffAction.ready }]
            as [(() -> PaneIdentityPanel.HandoffAction?)?] {
            let panel = PaneIdentityPanel()
            panel.frame = NSRect(x: 0, y: 0, width: PaneIdentityPanel.panelWidth,
                                 height: PaneIdentityPanel.maxHeight)
            panel.handoffActionProvider = provider
            panel.update(paneName: "Terminal", taskName: "Some task",
                         dot: .systemGray, agent: .claude)
            panel.layoutSubtreeIfNeeded()

            let present = panel.descendants.contains {
                $0.identifier == PaneIdentityPanel.handoffRowIdentifier
            }
            XCTAssertEqual(present, provider != nil)
            XCTAssertEqual(
                panel.currentIslandHeight,
                PaneIdentityPanel.baseHeight
                    + (provider == nil ? 0 : PaneIdentityPanel.handoffRowSpace),
                "没有这一行时岛体不该凭空多出一块空白")
        }
    }

    /// 没绑任务就没有这一行：没有可写回的地址，摆出来只是噪音。
    func testSummarizeRowNeedsABoundTask() {
        _ = NSApplication.shared
        let panel = PaneIdentityPanel()
        panel.frame = NSRect(x: 0, y: 0, width: PaneIdentityPanel.panelWidth,
                             height: PaneIdentityPanel.maxHeight)
        panel.handoffActionProvider = { .ready }
        panel.update(paneName: "Terminal", taskName: nil, dot: .systemGray, agent: .claude)
        panel.layoutSubtreeIfNeeded()
        XCTAssertFalse(panel.descendants.contains {
            $0.identifier == PaneIdentityPanel.handoffRowIdentifier
        })
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

    /// 改名的入口在列表底部，和解除绑定并排——不是任务行右边那支 20×20 的铅笔。
    func testRenameLivesInTheListNextToUnbind() throws {
        _ = NSApplication.shared
        let panel = PaneIdentityPanel()
        panel.frame = NSRect(x: 0, y: 0, width: PaneIdentityPanel.panelWidth,
                             height: PaneIdentityPanel.maxHeight)
        panel.taskProvider = {
            [.init(name: "Some task", fileURL: URL(fileURLWithPath: "/tmp/t.md"),
                   running: false, current: true)]
        }
        panel.update(paneName: "Terminal", taskName: "Some task", dot: .systemGray, agent: nil)
        panel.toggleTaskList()
        panel.layoutSubtreeIfNeeded()

        let labels = panel.descendants.compactMap { $0 as? NSTextField }
        let titles = labels.map(\.stringValue)
        XCTAssertTrue(titles.contains(L("Rename this task…")))
        XCTAssertTrue(titles.contains(L("Unbind")))

        // 三行三个颜色：候选是普通文字色，改名走强调色，解绑走红色。同色的话
        // 底下这两行看着就是"又两个任务"。
        let choice = try XCTUnwrap(labels.first { $0.stringValue == "Some task" })
        let rename = try XCTUnwrap(labels.first { $0.stringValue == L("Rename this task…") })
        let unbind = try XCTUnwrap(labels.first { $0.stringValue == L("Unbind") })
        // 动态色每次取都是新实例，比的是解析出来的值。
        let appearance = panel.effectiveAppearance
        func resolved(_ field: NSTextField) -> CGColor? {
            field.textColor?.shellResolvedCGColor(for: appearance)
        }
        XCTAssertEqual(resolved(rename),
                       ShellStyle.navigationAccent.shellResolvedCGColor(for: appearance))
        XCTAssertNotEqual(resolved(rename), resolved(choice))
        XCTAssertNotEqual(resolved(unbind), resolved(choice))
        XCTAssertNotEqual(resolved(unbind), resolved(rename))

        // 而且必须钉在滚动区外面：任务一多，跟着候选一起滚就又被挤到看不见了。
        let scroll = try XCTUnwrap(panel.descendants.compactMap { $0 as? NSScrollView }.first)
        let scrolled = Set((scroll.documentView?.descendants ?? []).compactMap {
            ($0 as? NSTextField)?.stringValue
        })
        XCTAssertFalse(scrolled.contains(L("Rename this task…")))
        XCTAssertFalse(scrolled.contains(L("Unbind")))
    }

    /// 胶囊与灵动岛第一行必须逐像素同构：展开时胶囊瞬间隐身、第一行顶上，收起反过来。
    /// 差一个像素，交接那一帧就能看见文字跳——胶囊加了 agent 图标而岛体没跟上时，
    /// 文字整整往回缩了 14pt。
    func testIslandFirstRowKeepsTheCapsuleTitleOffset() {
        _ = NSApplication.shared
        if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }
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

    private func makeTaskList() throws -> (PaneIdentityPanel, NSTextField, NSScrollView) {
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
        panel.toggleTaskList()
        panel.layoutSubtreeIfNeeded()
        let search = try XCTUnwrap(panel.descendants.compactMap { $0 as? NSTextField }
            .first { $0.placeholderAttributedString?.string == L("Search, or type a new task name and press Return") })
        let scroll = try XCTUnwrap(panel.descendants.compactMap { $0 as? NSScrollView }.first)
        return (panel, search, scroll)
    }

    private func filter(_ query: String, panel: PaneIdentityPanel, search: NSTextField) {
        search.stringValue = query
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        panel.layoutSubtreeIfNeeded()
    }

    func testMorphExpandsEquallyLeftAndRightAndOnlyDownward() {
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

    func testIdentityIconAndTitleStayFixedWhileIslandExpands() throws {
        _ = NSApplication.shared
        let panel = PaneIdentityPanel()
        panel.frame = NSRect(
            x: 0, y: 0,
            width: PaneIdentityPanel.panelWidth,
            height: PaneIdentityPanel.maxHeight)
        panel.update(paneName: "Terminal", taskName: nil, dot: .systemGray, agent: nil)
        panel.setIdentityAnchorOffset(74)
        panel.layoutSubtreeIfNeeded()

        let title = try XCTUnwrap(
            panel.descendants.compactMap { $0 as? NSTextField }.first {
                $0.stringValue == "Terminal"
            })
        let before = panel.convert(title.bounds, from: title)

        // 必须走形变入口：直接给 island.frame 赋值会把内容一起带偏，这也正是
        // `applyIslandFrame` 存在的理由。
        panel.applyIslandFrame(
            PaneIdentityMorphGeometry.expandedIslandFrame(
                in: panel.bounds, height: PaneIdentityPanel.baseHeight),
            duration: 0)
        panel.layoutSubtreeIfNeeded()
        let after = panel.convert(title.bounds, from: title)

        XCTAssertEqual(after.minX, before.minX, accuracy: 0.001)
        XCTAssertEqual(after.midY, before.midY, accuracy: 0.001)
    }

    func testSearchPlaceholderFitsWithinIsland() throws {
        _ = NSApplication.shared

        let panel = PaneIdentityPanel()
        panel.frame = NSRect(
            x: 0,
            y: 0,
            width: PaneIdentityPanel.panelWidth,
            height: PaneIdentityPanel.maxHeight)
        panel.update(paneName: "Terminal", taskName: nil, dot: .systemGray, agent: nil)
        panel.layoutSubtreeIfNeeded()

        let searchField = try XCTUnwrap(
            panel.descendants.compactMap { $0 as? NSTextField }.first {
                $0.placeholderAttributedString?.string
                    == L("Search, or type a new task name and press Return")
            })
        let placeholder = try XCTUnwrap(searchField.placeholderAttributedString)

        XCTAssertLessThanOrEqual(
            placeholder.size().width,
            searchField.bounds.width,
            "The default placeholder copy must fit instead of being clipped at the island edge")
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
