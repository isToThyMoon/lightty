import Foundation
@testable import lightty

/// 测试里按位次点名标签页的便利写法。控制器对外一律按身份下命令（序号会随关闭、
/// 重排整体移动），位次只在测试这一侧、调用的那一刻换算成身份。
extension TerminalWindowController {
    func tabIDForTesting(at index: Int) -> UUID { tabOverview()[index].id }

    func selectTab(at index: Int) { selectTab(withID: tabIDForTesting(at: index)) }
    func closeTab(at index: Int) { closeTab(withID: tabIDForTesting(at: index)) }
    func renameTab(at index: Int, to title: String) { renameTab(withID: tabIDForTesting(at: index), to: title) }
}
