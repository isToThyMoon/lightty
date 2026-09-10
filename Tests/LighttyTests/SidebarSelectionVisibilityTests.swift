import AppKit
import XCTest

@testable import lightty

/// 两个侧栏的选中态不是一回事，所以画不画也不该一样。
///
/// Sessions 的选中是派生的（跟着当前聚焦终端里那段会话走），侧栏没焦点时也要
/// 看得见——它回答的正是「我这个标签页里跑的是哪一段」。Handoff 的选中只是
/// 键盘光标（`tableViewSelectionDidChange` 是空的），失焦还留着就会被当成状态，
/// 而那一行真正的状态信号是绿点。
final class SidebarSelectionVisibilityTests: XCTestCase {
    /// `drawSelection` 只在 AppKit 认为该画时才落笔，这里靠「画了没有」反推：
    /// 把行渲染进位图，看选中色有没有出现。
    @MainActor
    private func paintsSelection(onlyWhenFocused: Bool, focused: Bool) -> Bool {
        let view = ShellTableRowView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        view.showsSelectionOnlyWhenFocused = onlyWhenFocused
        view.isSelected = true
        view.isEmphasized = focused
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            XCTFail("拿不到位图")
            return false
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        // 行内衬 2pt，取正中一点即可
        guard let color = rep.colorAt(x: 100, y: 20) else { return false }
        return color.alphaComponent > 0.01
    }

    @MainActor
    func testHandoffRowHidesSelectionWhenTheListIsNotFocused() {
        XCTAssertTrue(paintsSelection(onlyWhenFocused: true, focused: true),
            "键盘在这张表上时，光标要看得见")
        XCTAssertFalse(paintsSelection(onlyWhenFocused: true, focused: false),
            "焦点在终端里时，键盘光标不该还亮着——它不代表任何状态")
    }

    @MainActor
    func testSessionsRowKeepsSelectionWhileUnfocused() {
        XCTAssertTrue(paintsSelection(onlyWhenFocused: false, focused: false),
            "会话侧栏的选中是派生状态，失焦也要看得见")
    }
}
