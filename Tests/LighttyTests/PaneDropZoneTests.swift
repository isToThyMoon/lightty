import XCTest
@testable import lightty

/// 锁住与 vendor `TerminalSplitDropZone.calculate` 的逐式对齐：归一化距离、
/// 对角线切四个等面积三角区。回归背景：曾用绝对距离，瘦高 pane 里左右区
/// 吞掉几乎全部面积，上下分无从落点。
final class PaneDropZoneTests: XCTestCase {
    /// 瘦高 pane（真实事故形状）：中部偏下必须判 bottom，不能被左右吞掉。
    func testTallPaneCenterBottomIsBottom() {
        let bounds = NSRect(x: 0, y: 0, width: 277, height: 948)
        // y-up：y=200 在下方 21% 处，归一化后距底边最近
        XCTAssertEqual(
            PaneDropZone.calculate(at: NSPoint(x: 138, y: 200), in: bounds), .bottom)
        XCTAssertEqual(
            PaneDropZone.calculate(at: NSPoint(x: 138, y: 748), in: bounds), .top)
    }

    /// 四个三角区各自的代表点（宽 pane 同样成立——对扁宽形状是对称回归）。
    func testFourTriangularRegions() {
        let bounds = NSRect(x: 0, y: 0, width: 1000, height: 500)
        XCTAssertEqual(
            PaneDropZone.calculate(at: NSPoint(x: 50, y: 250), in: bounds), .left)
        XCTAssertEqual(
            PaneDropZone.calculate(at: NSPoint(x: 950, y: 250), in: bounds), .right)
        XCTAssertEqual(
            PaneDropZone.calculate(at: NSPoint(x: 500, y: 480), in: bounds), .top)
        XCTAssertEqual(
            PaneDropZone.calculate(at: NSPoint(x: 500, y: 20), in: bounds), .bottom)
    }

    /// bounds 原点不在零点时归一化仍正确（PaneView bounds 恒零原点，防未来走样）。
    func testOffsetBounds() {
        let bounds = NSRect(x: 100, y: 50, width: 200, height: 800)
        XCTAssertEqual(
            PaneDropZone.calculate(at: NSPoint(x: 200, y: 120), in: bounds), .bottom)
    }
}
