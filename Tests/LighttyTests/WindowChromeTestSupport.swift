import AppKit
import XCTest
@testable import lightty

extension TerminalWindowController {
    /// `init` 把标题栏附件、两个侧栏和待恢复的快照排到下一拍才装（见 `TerminalWindowController.init`
    /// 里的 `DispatchQueue.main.async`）；那一拍里装侧栏又会把列表刷新合流到再下一拍。
    /// 要碰侧栏、或要求初始结构已定的测试先让这两跳落地。
    ///
    /// 不等任务侧栏滑到位：滑入由 CADisplayLink 驱动，不上屏的测试窗口永远不走帧。
    func waitForInitialLayout(file: StaticString = #filePath, line: UInt = #line) throws {
        try drainMainQueue(file: file, line: line)
        try drainMainQueue(file: file, line: line)
    }
}
