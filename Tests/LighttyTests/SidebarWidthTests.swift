import XCTest
@testable import lightty

/// 两条侧栏的可拖宽度守同一套规则：区间钳制、越界才拖关、偏好按区间读回。
final class SidebarWidthTests: XCTestCase {
    private struct Case {
        let name: String
        let preference: SidebarWidthPreference
        let fallback: CGFloat
    }

    private let cases = [
        Case(name: "标签页侧栏", preference: TabSidebarWidthPreference.preference,
             fallback: TabSidebarSizing.minimumWidth),
        Case(name: "第一侧栏", preference: PrimarySidebarWidthPreference.preference,
             fallback: PrimarySidebarSizing.range.maximum),
    ]

    func testClosingRequiresOvershootingMinimumWidth() {
        for c in cases {
            let range = c.preference.range
            XCTAssertFalse(range.shouldClose(rawWidth: range.minimum - range.closeOvershoot), c.name)
            XCTAssertTrue(range.shouldClose(rawWidth: range.minimum - range.closeOvershoot - 1), c.name)
        }
    }

    /// 宽度落在 [minimum, maximum] 里：钳制函数与偏好读写都守这一条。
    func testWidthPreferenceClampsToSizingRangeAndRoundTrips() throws {
        for c in cases {
            let range = c.preference.range
            // 钳制：越界一点就贴回边界
            XCTAssertEqual(range.clamped(range.minimum - 1), range.minimum, c.name)
            XCTAssertEqual(range.clamped(range.maximum + 1), range.maximum, c.name)

            // 偏好：没存过用各自的默认、写入读回、超大钳到最大值
            let suiteName = "SidebarWidthTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            XCTAssertEqual(c.preference.width(in: defaults), c.fallback, c.name)

            let mid = ((range.minimum + range.maximum) / 2).rounded()
            c.preference.setWidth(mid, in: defaults)
            XCTAssertEqual(c.preference.width(in: defaults), mid, c.name)

            defaults.set(10_000.0, forKey: c.preference.defaultsKey)
            XCTAssertEqual(c.preference.width(in: defaults), range.maximum, c.name)
        }
    }

    /// 列表能滚动时 overlay 滚动条占满整条导轨，拖动条只把滑块那一段让给它，
    /// 其余导轨仍能抓住边线；不能滚动的列表整条导轨都归拖动条。
    @MainActor
    func testDragStripYieldsOnlyTheScrollerKnob() throws {
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
        XCTAssertTrue(strip.hitTest(offKnob) === strip, "导轨其余位置归拖动条")

        document.frame.size.height = 100
        scroll.tile()
        XCTAssertTrue(strip.hitTest(onKnob) === strip, "不可滚时整条导轨都能拖")
    }

    /// 第一侧栏：默认宽就是最大宽（历史固定宽），最小宽是它的 2/3。
    func testPrimarySidebarRangeIsTwoThirdsToFull() {
        XCTAssertEqual(PrimarySidebarSizing.range.maximum, ShellStyle.taskPanelWidth)
        XCTAssertEqual(PrimarySidebarSizing.range.minimum, (ShellStyle.taskPanelWidth * 2 / 3).rounded())
        XCTAssertEqual(TabSidebarWidthPreference.width(), TabSidebarSizing.minimumWidth)
    }
}
