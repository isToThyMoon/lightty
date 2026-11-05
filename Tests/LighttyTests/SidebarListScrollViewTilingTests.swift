import AppKit
import XCTest

@testable import lightty

final class SidebarListScrollViewTilingTests: XCTestCase {
    /// A fixed native lane must survive content growth, shrinkage, sidebar resizing, and the
    /// system's preferred scroller style flipping to overlay (a mouse unplugged, a setting changed).
    /// 回归：0.34.0 起浮层滚动条盖在行上，行背景伸到滑块底下，滚动条没留空。
    @MainActor
    func testRailStaysSeparateWhenContentAndWindowSizeChange() throws {
        let scroll = SidebarListScrollView(frame: NSRect(x: 0, y: 0, width: 266, height: 400))
        let document = NSView()
        document.autoresizingMask = [.width]
        scroll.documentView = document
        let host = NSWindow(contentRect: scroll.frame, styleMask: [.borderless],
                            backing: .buffered, defer: false)
        host.contentView = scroll
        defer { host.orderOut(nil) }
        host.orderFrontInvisibly()

        for (width, style) in [(266, NSScroller.Style.legacy), (190, .overlay), (320, .overlay)] {
            host.setContentSize(NSSize(width: width, height: 400))
            scroll.scrollerStyle = style
            XCTAssertEqual(scroll.scrollerStyle, .legacy)
            var viewportWidth: CGFloat?
            for height: CGFloat in [100, 2000, 100, 0, 2000] {
                document.setFrameSize(NSSize(width: scroll.contentSize.width, height: height))
                scroll.tile()
                host.contentView?.layoutSubtreeIfNeeded()
                let scroller = try XCTUnwrap(scroll.verticalScroller)
                XCTAssertFalse(scroller.isHidden)
                XCTAssertLessThanOrEqual(scroll.contentView.frame.maxX, scroller.frame.minX,
                    "Row actions must stay outside the scroller lane")
                if let viewportWidth {
                    XCTAssertEqual(scroll.contentView.frame.width, viewportWidth,
                        "Content growth must not change viewport width")
                }
                viewportWidth = scroll.contentView.frame.width
                if height > scroll.contentSize.height {
                    document.scroll(NSPoint(x: 0, y: 500))
                    XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
                }
            }
        }
    }
}
