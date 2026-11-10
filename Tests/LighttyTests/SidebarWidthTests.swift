import XCTest
@testable import lightty

/// 两条侧栏的可拖宽度守同一套规则：区间钳制、偏好按区间读回。
final class SidebarWidthTests: XCTestCase {
    /// 滚动条在拖动条下面时只让出滑块：空轨道和贴边一带都拖侧栏边线，长列表也抓得住。
    @MainActor
    func testDragStripYieldsOnlyTheKnob() throws {
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
        XCTAssertTrue(strip.hitTest(offKnob) === strip, "空轨道拖边线")
        XCTAssertTrue(strip.hitTest(NSPoint(x: 198, y: knob.midY)) === strip, "贴边一带压着滑块也拖边线")

        document.frame.size.height = 100
        scroll.tile()
        XCTAssertTrue(strip.hitTest(onKnob) === strip, "不可滚时整条导轨都能拖")
    }
}
