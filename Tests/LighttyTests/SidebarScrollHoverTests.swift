import AppKit
import XCTest
@testable import lightty

@MainActor
final class SidebarScrollHoverTests: XCTestCase {
    func testSidebarPreservesResponsiveScrolling() {
        XCTAssertTrue(SidebarListScrollView.isCompatibleWithResponsiveScrolling)
    }

    func testBoundsOnlyScrollingIsScopedAndSettles() {
        let scrolling = SidebarListScrollView(frame: .zero)
        let other = SidebarListScrollView(frame: .zero)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scrolling.contentView)
        XCTAssertTrue(scrolling.suppressesPointerFeedback)
        XCTAssertFalse(other.suppressesPointerFeedback)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertFalse(scrolling.suppressesPointerFeedback)
    }

    func testCursorTrackingDoesNotRetainVirtualizedRow() {
        weak var releasedRow: NSView?
        weak var releasedOwner: AnyObject?
        autoreleasepool {
            let row = NSView(frame: .zero)
            HoverCursor.installPointingHand(on: row)
            releasedRow = row
            releasedOwner = row.trackingAreas.last?.owner as AnyObject?
            XCTAssertNotNil(releasedOwner)
        }
        XCTAssertNil(releasedRow)
        XCTAssertNil(releasedOwner)
    }

    func testNativeScrollLifecycleSuppressesRowCursorUntilScrollEnds() throws {
        let scroll = SidebarListScrollView(frame: NSRect(x: 0, y: 0, width: 280, height: 400))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 2000))
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 40))
        scroll.documentView = document
        document.addSubview(row)
        HoverCursor.installPointingHand(on: row)
        let owner = try XCTUnwrap(row.trackingAreas.last?.owner as? NSResponder)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0))
        defer { NSCursor.arrow.set() }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        ShellHoverGate.release(in: nil)
        owner.cursorUpdate(with: event)
        XCTAssertEqual(NSCursor.current, NSCursor.pointingHand)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        // A stationary finger / scrollbar hold must not let the idle timer reopen hover.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
        for _ in 0..<20 {
            owner.cursorUpdate(with: event)
            XCTAssertEqual(NSCursor.current, NSCursor.arrow)
        }
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        owner.cursorUpdate(with: event)
        XCTAssertEqual(NSCursor.current, NSCursor.pointingHand)
    }

    /// 标签页行前只有一个图标，hover 也不换成折叠箭头——同一个位置换图标会让人
    /// 以为那里多了一个控件。折叠仍然点它触发，说明留在 tooltip 里。
    func testTabRowKeepsOneGlyphAndNeverSwapsInAChevron() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = NSApplication.shared
        AppState.shared = AppState(taskDirectory: directory, sweepStalePanes: false)
        if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }
        let controller = TerminalWindowController()
        defer { controller.window?.close() }
        // 单 pane 标签页是叶子行，没有容器行；分屏一次才有标签页行 + pane 行可测。
        controller.split(try XCTUnwrap(controller.activePane), direction: .right)
        let column = TabColumnView()
        controller.window!.contentView!.addSubview(column)
        column.frame = NSRect(x: 0, y: 0, width: 280, height: 400)
        column.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        ShellHoverGate.release(in: nil)
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        let row = try XCTUnwrap(descendants(column).first { $0 is SidebarHoverRow })
        let glyph = try XCTUnwrap(descendants(row).compactMap { $0 as? NSButton }
            .first { $0.toolTip == L("Collapse tab") || $0.toolTip == L("Expand tab") })
        XCTAssertEqual(glyph.image?.accessibilityDescription, L("Tab"))
        row.sidebarHoverEntered()
        column.layoutSubtreeIfNeeded()
        XCTAssertEqual(glyph.image?.accessibilityDescription, L("Tab"),
                       "Hover must not swap the tab glyph for a chevron")
        XCTAssertFalse(glyph.isHidden)
        // 展开/收起靠同一形状的空心与实心区分，仍然只有一个图标。
        glyph.performClick(nil)
        column.layoutSubtreeIfNeeded()
        let collapsed = try XCTUnwrap(descendants(column).compactMap { $0 as? NSButton }
            .first { $0.toolTip == L("Expand tab") })
        XCTAssertEqual(collapsed.image?.accessibilityDescription, L("Collapsed tab"))
        collapsed.performClick(nil)
        column.layoutSubtreeIfNeeded()
        XCTAssertEqual(try XCTUnwrap(descendants(column).compactMap { $0 as? NSButton }
            .first { $0.toolTip == L("Collapse tab") }).image?.accessibilityDescription, L("Tab"))
    }

    func testTabAndPaneHoverClearWithoutMouseExitedOnScroll() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = NSApplication.shared
        AppState.shared = AppState(taskDirectory: directory, sweepStalePanes: false)
        if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }
        let controller = TerminalWindowController()
        defer { controller.window?.close() }
        // 单 pane 标签页是叶子行，没有容器行；分屏一次才有标签页行 + pane 行可测。
        controller.split(try XCTUnwrap(controller.activePane), direction: .right)
        let column = TabColumnView()
        controller.window!.contentView!.addSubview(column)
        column.frame = NSRect(x: 0, y: 0, width: 280, height: 400)
        column.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        ShellHoverGate.release(in: nil)
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        let rows = descendants(column).filter { $0 is SidebarHoverRow }
        XCTAssertGreaterThanOrEqual(rows.count, 2, "Exercise real tab and pane rows")
        let scroll = try XCTUnwrap(descendants(column).compactMap { $0 as? SidebarListScrollView }.first)
        for row in rows {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
            let buttons = descendants(row).compactMap { $0 as? NSButton }
            let idle = buttons.map(\.isHidden)
            row.sidebarHoverEntered()
            XCTAssertNotEqual(buttons.map(\.isHidden), idle)
            scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: scroll.contentView.bounds.minY + 10))
            XCTAssertEqual(buttons.map(\.isHidden), idle, "Scroll clears hover without mouseExited")
            row.sidebarHoverEntered() // Stale tracking event while content moves under pointer.
            XCTAssertEqual(buttons.map(\.isHidden), idle, "Scrolling suppresses transient hover")
        }
    }

    func testScrollingDoesNotInvalidateEveryUnhoveredRow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = SidebarListScrollView(frame: window.contentView!.bounds)
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 4000))
        scroll.documentView = document
        window.contentView!.addSubview(scroll)
        let rows = (0..<100).map { index -> ShellTableRowView in
            let row = ShellTableRowView(frame: NSRect(x: 0, y: index * 40, width: 280, height: 40))
            document.addSubview(row)
            return row
        }
        window.displayIfNeeded()
        rows.forEach { $0.needsDisplay = false }
        let initiallyDirty = rows.filter(\.needsDisplay).count
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<500 {
            NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }
        print("Scroll hover 100 rows / 500 callbacks:", ProcessInfo.processInfo.systemUptime - start)
        XCTAssertEqual(rows.filter(\.needsDisplay).count, initiallyDirty, "Unchanged hover must not add dirty rows")
    }
}
