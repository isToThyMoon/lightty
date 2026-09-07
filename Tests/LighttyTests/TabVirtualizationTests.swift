import AppKit
import XCTest
@testable import lightty

@MainActor
final class TabVirtualizationTests: XCTestCase {
    func testVirtualizedTabDisclosurePreservesPaneRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = NSApplication.shared
        AppState.shared = AppState(taskDirectory: directory, sweepStalePanes: false)
        if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }
        let controller = TerminalWindowController()
        defer { controller.window?.close() }
        let column = TabColumnView()
        controller.window!.contentView!.addSubview(column)
        column.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        let table = try XCTUnwrap(descendants(column).compactMap { $0 as? NSTableView }.first)
        column.layoutSubtreeIfNeeded()
        table.layoutSubtreeIfNeeded()
        let count = table.numberOfRows
        XCTAssertGreaterThan(count, 1)
        let collapse = try XCTUnwrap(descendants(table).compactMap { $0 as? NSButton }.first { $0.toolTip == L("Collapse tab") })
        collapse.performClick(nil)
        table.layoutSubtreeIfNeeded()
        XCTAssertEqual(table.numberOfRows, count - 1)
        let expand = try XCTUnwrap(descendants(table).compactMap { $0 as? NSButton }.first { $0.toolTip == L("Expand tab") })
        expand.performClick(nil)
        table.layoutSubtreeIfNeeded()
        XCTAssertEqual(table.numberOfRows, count)
        XCTAssertEqual(controller.panes().count, 1)
    }

    func testThousandTabsOnlyInstantiateViewportRows() throws {
        for count in [50, 100, 1000] { try checkViewportReuse(count: count) }
    }

    private func checkViewportReuse(count: Int) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let column = TabColumnView()
        window.contentView = column
        column.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        column.reload(overview: (0..<count).map { (UUID(), $0, "Tab \($0)", false, []) })
        column.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        let table = try XCTUnwrap(descendants(column).compactMap { $0 as? NSTableView }.first)
        table.layoutSubtreeIfNeeded()
        XCTAssertEqual(table.numberOfRows, count)
        func materialized() -> Int { descendants(table).filter { $0 is SidebarHoverRow }.count }
        XCTAssertGreaterThan(materialized(), 0)
        XCTAssertLessThan(materialized(), 40, "Views must scale with viewport, not total tabs")
        let start = ProcessInfo.processInfo.systemUptime
        // Retain observed containers: pointer recycling cannot masquerade as view reuse.
        var observed: [ObjectIdentifier: NSView] = [:]
        for step in 0..<100 {
            let index = (step * 10) % count
            table.scrollRowToVisible(index)
            table.layoutSubtreeIfNeeded()
            let visible = table.rows(in: table.visibleRect)
            for row in visible.location..<(visible.location + visible.length) {
                if let view = table.view(atColumn: 0, row: row, makeIfNecessary: false) {
                    observed[ObjectIdentifier(view)] = view
                }
            }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        table.scrollRowToVisible(count - 1)
        table.layoutSubtreeIfNeeded()
        XCTAssertLessThan(materialized(), 40)
        XCTAssertLessThan(observed.count, 80, "Scrolling must reuse containers, not just release offscreen rows")
        XCTAssertNotNil(table.view(atColumn: 0, row: count - 1, makeIfNecessary: false))
        XCTAssertTrue(descendants(table).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Tab \(count - 1)" })
        print("Virtual tabs: \(count) models, \(materialized()) views, 100 viewport jumps: \(elapsed * 1000) ms")
    }
}
