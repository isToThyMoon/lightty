import XCTest
@testable import lightty

/// 锁住与 vendor `TerminalSplitDropZone.calculate` 的逐式对齐：归一化距离、
/// 对角线切四个等面积三角区。回归背景：曾用绝对距离，瘦高 pane 里左右区
/// 吞掉几乎全部面积，上下分无从落点。
final class PaneDropZoneTests: XCTestCase {
    /// 同一个 `calculate`：bounds × 点 → 归一化后离哪条边最近就是哪个区。
    func testDropZoneIsTheNearestNormalisedEdge() {
        struct Case {
            let name: String
            let bounds: NSRect
            let point: NSPoint
            let expected: PaneDropZone
        }
        let tall = NSRect(x: 0, y: 0, width: 277, height: 948)
        let wide = NSRect(x: 0, y: 0, width: 1000, height: 500)
        let cases: [Case] = [
            // 瘦高 pane（真实事故形状）：中部偏下必须判 bottom，不能被左右吞掉。
            // y-up：y=200 在下方 21% 处，归一化后距底边最近。
            Case(name: "tall pane, lower middle is bottom", bounds: tall, point: NSPoint(x: 138, y: 200), expected: .bottom),
            Case(name: "tall pane, upper middle is top", bounds: tall, point: NSPoint(x: 138, y: 748), expected: .top),
            // 四个三角区各自的代表点（宽 pane 同样成立——对扁宽形状是对称回归）。
            Case(name: "wide pane, left region", bounds: wide, point: NSPoint(x: 50, y: 250), expected: .left),
            Case(name: "wide pane, right region", bounds: wide, point: NSPoint(x: 950, y: 250), expected: .right),
            Case(name: "wide pane, top region", bounds: wide, point: NSPoint(x: 500, y: 480), expected: .top),
            Case(name: "wide pane, bottom region", bounds: wide, point: NSPoint(x: 500, y: 20), expected: .bottom),
            // bounds 原点不在零点时归一化仍正确（PaneView bounds 恒零原点，防未来走样）。
            Case(name: "offset bounds", bounds: NSRect(x: 100, y: 50, width: 200, height: 800),
                 point: NSPoint(x: 200, y: 120), expected: .bottom),
        ]
        for c in cases {
            XCTAssertEqual(PaneDropZone.calculate(at: c.point, in: c.bounds), c.expected, c.name)
        }
    }
}
