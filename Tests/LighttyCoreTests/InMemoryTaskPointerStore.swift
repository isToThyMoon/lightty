import Foundation
import LighttyCore

/// 测试 adapter：把两份文件摊成内存里的值。`recordInjection` 模拟 hook 写去重标记。
/// 只有 Core 测试用它，所以放在测试 target，不进生产代码。
final class InMemoryTaskPointerStore: TaskPointerStore {
    private(set) var pointers: [UUID: String] = [:]
    private(set) var markers: [UUID: String] = [:]

    func write(taskFile: URL, for pane: UUID) {
        pointers[pane] = taskFile.path
    }

    func clear(for pane: UUID) {
        pointers.removeValue(forKey: pane)
        markers.removeValue(forKey: pane)
    }

    func recordInjection(for pane: UUID, session: String, path: String) {
        markers[pane] = "\(session)\n\(path)"
    }
}
