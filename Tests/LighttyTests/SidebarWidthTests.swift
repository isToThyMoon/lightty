import XCTest
@testable import lightty

/// 两条侧栏的可拖宽度守同一套规则：区间钳制、越界才拖关、偏好按区间读回。
final class SidebarWidthTests: XCTestCase {
    /// 原生常驻滚动条的轨道用于翻页；短列表的空槽仍然可以拖动侧栏边线。
    @MainActor
    func testDragStripYieldsScrollableTrack() throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        let scroll = SidebarListScrollView(frame: NSRect(x: 12, y: 0, width: 186, height: 400))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 2000))
        scroll.documentView = document
        let strip = EdgeDragStrip(range: TabSidebarSizing.range)
        strip.frame = NSRect(x: 186, y: 0, width: 14, height: 400)
        host.addSubview(scroll)
        host.addSubview(strip)
        scroll.tile()
        host.layoutSubtreeIfNeeded()

        let scroller = try XCTUnwrap(scroll.verticalScroller)
        XCTAssertFalse(scroller.isHidden, "2000 高的文档在 400 高的视口里必然可滚")
        let knob = scroller.convert(scroller.rect(for: .knob), to: host)
        XCTAssertFalse(knob.isEmpty)
        let onKnob = NSPoint(x: 193, y: knob.midY)
        XCTAssertTrue(strip.frame.contains(onKnob))
        XCTAssertNil(strip.hitTest(onKnob), "滑块上让给滚动条")
        let offKnob = NSPoint(x: 193, y: knob.midY < 200 ? 390 : 10)
        XCTAssertNil(strip.hitTest(offKnob), "可滚动时轨道用于翻页")

        document.frame.size.height = 100
        scroll.tile()
        XCTAssertTrue(strip.hitTest(onKnob) === strip, "不可滚时整条导轨都能拖")
    }
}
