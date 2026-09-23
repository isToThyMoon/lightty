import AppKit
import Testing
@testable import lightty

/// 菜单宽度跟着内容走，夹在 `ShellStyle.Menu` 的上下限之间——以前写死 240，
/// 一项短命令也撑成一张大卡。
@MainActor
struct ShellMenuWidthTests {
    private func width(_ items: [ShellMenuPopover.Item]) -> CGFloat {
        _ = NSApplication.shared
        let controller = ShellMenuController(items: items)
        return controller.view.fittingSize.width
    }

    @Test func menusSizeToTheirContentWithinBounds() {
        let short = width([.action("重命名标签页", symbol: ShellSymbol.rename, handler: {})])
        let longer = width([.action("关闭当前窗口所有标签页", symbol: ShellSymbol.close, handler: {})])
        let huge = width([.action(String(repeating: "很长的菜单项", count: 20), symbol: ShellSymbol.close, handler: {})])
        let tiny = width([.action("关", handler: {})])
        #expect(short < 240, "one short item must not be stretched to the old fixed width")
        #expect(longer > short, "wider text makes a wider menu")
        #expect(huge == ShellStyle.Menu.maxWidth, "very long rows stop at the upper bound and truncate")
        #expect(tiny == ShellStyle.Menu.minWidth, "tiny menus keep a comfortable minimum")
    }
}
