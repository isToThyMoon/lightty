import AppKit
import XCTest
@testable import lightty

@MainActor
final class PaneIdentityPanelTests: XCTestCase {
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

    func testConsecutiveFiltersDoNotRevealBeyondInterruptedMask() throws {
        let (panel, search, _) = try makeTaskList()
        let container = try XCTUnwrap(search.superview)
        // 同一帧内反向筛选：首段动画尚未呈现，不应跳到上一次目标高度。
        filter("Task 20", panel: panel, search: search)
        let shortHeight = container.bounds.height
        let shortMask = try XCTUnwrap(container.layer?.mask)
        XCTAssertEqual(shortMask.position.y, shortHeight,
                       "A shrinking container must not retain the previous mask's top edge")
        filter("Task", panel: panel, search: search)
        let mask = try XCTUnwrap(container.layer?.mask)
        let animation = try XCTUnwrap(mask.animation(forKey: "reveal") as? CABasicAnimation)
        let start = try XCTUnwrap(animation.fromValue as? CGFloat)
        XCTAssertLessThan(start, shortHeight)
        XCTAssertEqual(mask.position.y, container.bounds.height)
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
        let button = try XCTUnwrap(panel.descendants.compactMap { $0 as? NSButton }
            .first { $0.action == NSSelectorFromString("taskTapped") })
        button.performClick(nil)
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
        let collapsed = PaneIdentityMorphGeometry.collapsedIslandFrame(
            capsule: capsule, panelFrame: panel)
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
        panel.update(paneName: "Terminal", taskName: nil, dot: .systemGray)
        panel.setIdentityAnchorOffset(74)
        panel.layoutSubtreeIfNeeded()

        let title = try XCTUnwrap(
            panel.descendants.compactMap { $0 as? NSTextField }.first {
                $0.stringValue == "Terminal"
            })
        let before = panel.convert(title.bounds, from: title)

        panel.island.frame = PaneIdentityMorphGeometry.expandedIslandFrame(
            in: panel.bounds, height: PaneIdentityPanel.baseHeight)
        panel.layoutSubtreeIfNeeded()
        let after = panel.convert(title.bounds, from: title)

        XCTAssertEqual(after.minX, before.minX, accuracy: 0.001)
        XCTAssertEqual(after.midY, before.midY, accuracy: 0.001)
    }

    func testCollapseFadeIncludesOpenTaskList() throws {
        _ = NSApplication.shared

        let panel = PaneIdentityPanel()
        panel.frame = NSRect(
            x: 0,
            y: 0,
            width: PaneIdentityPanel.panelWidth,
            height: PaneIdentityPanel.maxHeight)
        panel.taskProvider = {
            [PaneIdentityPanel.TaskChoice(
                name: "Task",
                fileURL: URL(fileURLWithPath: "/tmp/task.md"),
                running: false,
                current: false)]
        }
        panel.update(paneName: "Terminal", taskName: nil, dot: .systemGray)
        panel.layoutSubtreeIfNeeded()

        let taskButton = try XCTUnwrap(
            panel.descendants.compactMap { $0 as? NSButton }.first {
                $0.action == NSSelectorFromString("taskTapped")
            })
        taskButton.performClick(nil)
        panel.layoutSubtreeIfNeeded()

        let searchField = try XCTUnwrap(
            panel.descendants.compactMap { $0 as? NSTextField }.first {
                $0.placeholderAttributedString?.string
                    == L("Search, or type a new task name and press Return")
            })
        let taskListContainer = try XCTUnwrap(searchField.superview)

        panel.setExpandedContentAlpha(0, animated: false)

        XCTAssertEqual(
            taskListContainer.alphaValue,
            0,
            "The open task list must fade with the island's other expanded content")
    }

    func testSearchPlaceholderFitsWithinIsland() throws {
        _ = NSApplication.shared

        let panel = PaneIdentityPanel()
        panel.frame = NSRect(
            x: 0,
            y: 0,
            width: PaneIdentityPanel.panelWidth,
            height: PaneIdentityPanel.maxHeight)
        panel.update(paneName: "Terminal", taskName: nil, dot: .systemGray)
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
        let taskButton = try XCTUnwrap(
            panel.descendants.compactMap { $0 as? NSButton }.first {
                $0.action == NSSelectorFromString("taskTapped")
            })
        taskButton.performClick(nil)
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
