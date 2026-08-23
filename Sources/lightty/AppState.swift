import AppKit
import LighttyCore

/// 全局状态：TaskStore（~/.lightty/tasks，唯一持久语义层）+ 存活窗口。
/// TaskFolderWatcher 尚未接进壳（HANDOVER 7.4 已知限制）：文件外部更新后 UI 不自动刷新。
final class AppState {
    static var shared: AppState!

    let taskStore: TaskStore
    var windowControllers: [TerminalWindowController] = []

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lightty/tasks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.taskStore = TaskStore(directory: dir)
    }

    @discardableResult
    func newWindow(initialPane: PaneView = PaneView()) -> TerminalWindowController {
        let controller = TerminalWindowController(initialPane: initialPane)
        windowControllers.append(controller)
        controller.window?.makeKeyAndOrderFront(nil)
        initialPane.focusTerminal()
        return controller
    }

    var keyWindowController: TerminalWindowController? {
        windowControllers.first { $0.window?.isKeyWindow == true } ?? windowControllers.last
    }

    /// 全部运行中 pane（跨窗口）
    func runningPanes() -> [(controller: TerminalWindowController, pane: PaneView)] {
        windowControllers.flatMap { c in c.panes().map { (c, $0) } }
    }
}
