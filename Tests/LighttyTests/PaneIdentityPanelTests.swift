import AppKit
import XCTest
@testable import lightty

@MainActor
final class PaneIdentityPanelTests: XCTestCase {
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

private extension NSView {
    var descendants: [NSView] {
        subviews + subviews.flatMap(\.descendants)
    }
}
