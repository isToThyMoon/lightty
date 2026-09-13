import Foundation
import LighttyCore

/// 测试 adapter：手动触发的任务目录变更源。`source` 交给 `TaskBindings`，`fire()` 代替一次
/// 防抖后的目录事件；`token` 弱引用监听凭据，用来确认 `TaskBindings` 释放时监听跟着结束。
final class ManualTaskFolderChanges {
    private(set) var directory: URL?
    private var onChange: (() -> Void)?
    private(set) weak var token: AnyObject?
    /// 置上后 `source` 抛错，模拟目录打不开。
    var failure: Error?

    var source: TaskFolderChangeSource {
        { [unowned self] directory, onChange in
            if let failure { throw failure }
            self.directory = directory
            self.onChange = onChange
            let token = NSObject()
            self.token = token
            return token
        }
    }

    func fire() { onChange?() }
}
