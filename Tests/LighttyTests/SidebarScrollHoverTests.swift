import AppKit
import XCTest
@testable import lightty

@MainActor
final class SidebarScrollHoverTests: XCTestCase {
    func testSidebarPreservesResponsiveScrolling() {
        XCTAssertTrue(SidebarListScrollView.isCompatibleWithResponsiveScrolling)
    }

    /// 滚动期间压住 hover 反馈，停稳后自己放开：
    /// 只有 bounds 变化的滚动（合成通知）只压本实例、收敛定时器自行回落；
    /// 原生 live scroll 生命周期里指针静止也不放开，didEnd 后才恢复手形光标。
    func testScrollingSuppressesHoverFeedbackUntilItSettles() throws {
        // 只有 bounds 变化：闸门是每个列表自己的，且会自行回落
        let scrolling = SidebarListScrollView(frame: .zero)
        let other = SidebarListScrollView(frame: .zero)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scrolling.contentView)
        XCTAssertTrue(scrolling.suppressesPointerFeedback)
        XCTAssertFalse(other.suppressesPointerFeedback, "Another list's scroll must not close this one's gate")
        // 滚动停下 0.08 秒后收敛定时器自己放开闸门。
        try waitUntil("bounds-only scroll settles") { !scrolling.suppressesPointerFeedback }

        // 原生 live scroll：willStart 后行光标一直是箭头，didEnd 后恢复手形
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
        ShellHoverGate.release(in: nil)
        owner.cursorUpdate(with: event)
        XCTAssertEqual(NSCursor.current, NSCursor.pointingHand)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        // A stationary finger / scrollbar hold must not let the idle timer reopen hover.
        // 否定式：闸门「不该」自己放开，没有可等的信号。收敛定时器的窗口是 0.08 秒
        //（SidebarListScrollView），这里压过它三倍再查，确认它没在指针静止时被误触发。
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
        for _ in 0..<20 {
            owner.cursorUpdate(with: event)
            XCTAssertEqual(NSCursor.current, NSCursor.arrow)
        }
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        try waitUntil("live scroll settles") { !scroll.suppressesPointerFeedback }
        owner.cursorUpdate(with: event)
        XCTAssertEqual(NSCursor.current, NSCursor.pointingHand)
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

    private func hovered(_ row: ShellTableRowView) -> Bool {
        Mirror(reflecting: row).children.first { $0.label == "isHovered" }?.value as? Bool ?? false
    }

    /// 滚动把 hover 行滚出视口时没有 mouseExited，hover 也必须清掉；滚动期间来的
    /// 陈旧 tracking 事件也被压住。先用一个 ShellTableRowView 验证 boundsDidChange
    /// 这条路，再用真实的标签页行 / pane 行验证按钮显隐回到 idle。
    func testScrollClearsAndSuppressesRowHoverWithoutMouseExited() throws {
        _ = NSApplication.shared
        // 单个 ShellTableRowView：boundsDidChange 清 hover
        do {
            let scroll = SidebarListScrollView(frame: NSRect(x: 0, y: 0, width: 280, height: 100))
            let document = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 1000))
            let row = ShellTableRowView(frame: NSRect(x: 0, y: 0, width: 280, height: 48))
            document.addSubview(row); scroll.documentView = document
            let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = scroll
            // 装进窗口时的首次布局算一次滚动，列表自己的闸门要等收敛定时器放开。
            try waitUntil("initial layout settles") { !scroll.suppressesPointerFeedback }
            ShellHoverGate.release(in: nil)
            let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, trackingNumber: 0, userData: nil))
            row.mouseEntered(with: event)
            XCTAssertTrue(hovered(row))
            scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 500))
            NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            XCTAssertFalse(hovered(row), "Scrolling must clear hover even without mouseExited")
        }

        // 真实的标签页行与 pane 行：滚动后按钮显隐回到 idle，滚动中 hover 被压
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        AppState.shared = AppState(taskDirectory: directory, sweepStalePanes: false)
        ensureTerminalRuntime()
        let controller = TerminalWindowController()
        defer { controller.window?.close() }
        // 单 pane 标签页是叶子行，没有容器行；分屏一次才有标签页行 + pane 行可测。
        controller.split(try XCTUnwrap(controller.activePane), direction: .right)
        let column = TabColumnView()
        controller.window!.contentView!.addSubview(column)
        column.frame = NSRect(x: 0, y: 0, width: 280, height: 400)
        column.layoutSubtreeIfNeeded()
        // 控制器在下一拍才装标题栏和任务侧栏，装侧栏会关上 hover 闸门；等它装完再放开闸门，
        // 否则闸门会在测试中途被关上。
        try controller.waitForInitialLayout()
        ShellHoverGate.release(in: nil)
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        let rows = descendants(column).filter { $0 is SidebarHoverRow }
        XCTAssertGreaterThanOrEqual(rows.count, 2, "Exercise real tab and pane rows")
        let scroll = try XCTUnwrap(descendants(column).compactMap { $0 as? SidebarListScrollView }.first)
        for row in rows {
            // 上一轮的滚动关了列表自己的闸门，等收敛定时器放开它。
            try waitUntil("previous scroll settles") { !scroll.suppressesPointerFeedback }
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

    /// 两行连续 mouseEntered（中间没有 mouseExited）只剩后者 hovered：hover 互斥。
    func testEnteringAnotherRowClearsPreviousHoverWithoutExitEvent() throws {
        _ = NSApplication.shared
        let table = NSTableView()
        let scroll = SidebarListScrollView(frame: NSRect(x: 0, y: 0, width: 280, height: 100))
        scroll.documentView = table
        let first = ShellTableRowView(), second = ShellTableRowView()
        table.addSubview(first); table.addSubview(second)
        try waitUntil("initial layout settles") { !scroll.suppressesPointerFeedback }
        ShellHoverGate.release(in: nil)
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil))
        first.mouseEntered(with: event)
        second.mouseEntered(with: event)
        XCTAssertFalse(hovered(first), "Fast row transitions must not leave multiple hover backgrounds")
        XCTAssertTrue(hovered(second))
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
