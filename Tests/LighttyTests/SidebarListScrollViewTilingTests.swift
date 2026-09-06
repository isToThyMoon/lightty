import AppKit
import XCTest

@testable import lightty

/// `SidebarListScrollView.tile()` 的重入。
///
/// 2026-09-09 两次采样都抓到同一个环：我们的 `tile()` 调 `super.tile()`，AppKit
/// 改 clip 的 frame，帧变化通知一路走回 `_tileWithoutRecursing`，又调进我们的
/// `tile()`——而我们在这一层再调一次 `super.tile()`，等于绕过 AppKit 自己那道闸。
/// 表现是 100% CPU、界面完全无响应。
///
/// **这里没能复现那个环。** 试过合成条件（文档高于视口、宽度顶在滚动条显隐的
/// 临界点、legacy 与 overlay 两种样式）都不递归——环是从真实显示事务里起的
/// （样本里是 `stepTransactionFlush` → `viewWillDraw`），单元测试构不出那个上下文。
/// 所以下面三条守的是**环的燃料**（不收敛、重入），不是环本身；重入闸有没有真的
/// 治住那个卡死，只能靠跑起来看。
final class SidebarListScrollViewTilingTests: XCTestCase {
    /// 数递归深度。带保险丝，免得没有闸的时候测试真的挂死在这里。
    private final class CountingScrollView: SidebarListScrollView {
        static let fuse = 64
        private var depth = 0
        private(set) var deepest = 0

        override func tile() {
            depth += 1
            deepest = max(deepest, depth)
            if depth < Self.fuse { super.tile() }
            depth -= 1
        }
    }

    @MainActor
    private func makeScrollView() -> CountingScrollView {
        let scroll = CountingScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 300))
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 240, height: 900))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        column.width = 240
        table.addTableColumn(column)
        table.rowHeight = 48
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // 环的推手是滚动条显隐决定：显不显示改变可用宽度，可用宽度又反过来决定
        // 显不显示。用 legacy 样式让滚动条真的占位，并把文档宽度顶到临界点。
        scroll.scrollerStyle = .legacy
        scroll.verticalScroller = SidebarScroller()
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 300),
                            styleMask: [.titled], backing: .buffered, defer: false)
        host.contentView?.addSubview(scroll)
        return scroll
    }

    /// 一次 `tile()` 不该把自己卷进去。
    ///
    /// 诚实说明：**这条在把重入闸删掉之后同样通过**——合成条件下 AppKit 根本没有
    /// 重入进来。它只能证明闸本身没有把正常那一次也挡掉，证明不了闸治住了卡死。
    @MainActor
    func testTilingDoesNotReenterItself() {
        let scroll = makeScrollView()
        scroll.tile()
        XCTAssertLessThan(scroll.deepest, CountingScrollView.fuse,
            "tile() 递归到保险丝了——重入闸没起作用")
        XCTAssertLessThanOrEqual(scroll.deepest, 2,
            "重入应当当场返回，不该再层层深入")
    }

    /// 环的燃料是「不收敛」：`super.tile()` 把宽度算回满宽、我们再减掉导轨，
    /// 两个值来回翻。所以连做两次必须落在同一个结果上。
    @MainActor
    func testTilingIsIdempotent() {
        let scroll = makeScrollView()
        scroll.tile()
        let first = scroll.contentView.frame
        scroll.tile()
        XCTAssertEqual(scroll.contentView.frame, first, "同样的输入连做两次要落在同一个结果上")
    }

    /// 闸不能把本职工作一起挡掉：导轨那一段仍然要留出来。
    @MainActor
    func testTheRailIsStillReserved() {
        let scroll = makeScrollView()
        scroll.tile()
        XCTAssertLessThanOrEqual(
            scroll.contentView.frame.maxX,
            scroll.bounds.width - SidebarListScrollView.railWidth + 0.5,
            "内容区右边要给滚动条留出导轨")
    }
}
