import AppKit
import XCTest
@testable import lightty

@MainActor
final class PaneIdentityPanelTests: XCTestCase {
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
