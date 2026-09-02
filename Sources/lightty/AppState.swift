import AppKit
import LighttyCore

/// 全局状态：TaskStore（~/.lightty/tasks，唯一持久语义层）+ 存活窗口。
/// TaskFolderWatcher 尚未接进壳（HANDOVER 7.4 已知限制）：文件外部更新后 UI 不自动刷新。
final class AppState {
    static var shared: AppState!

    let taskStore: TaskStore
    var windowControllers: [TerminalWindowController] = []

    init(taskDirectory: URL? = nil, sweepStalePanes: Bool = true) {
        let dir = taskDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lightty/tasks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.taskStore = TaskStore(directory: dir)
        // 上次崩溃/强杀留下的 pane 运行时目录在这里回收（按 owner.pid 判活，
        // 不会误删另一个 lightty 实例的）。必须在任何 pane 创建之前跑。
        if sweepStalePanes {
            PaneStatusStore.shared.sweepStale()
        }
    }

    @discardableResult
    func newWindow(initialPane: PaneView = PaneView()) -> TerminalWindowController {
        let controller = TerminalWindowController(initialPane: initialPane)
        windowControllers.append(controller)
        controller.window?.makeKeyAndOrderFront(nil)
        initialPane.focusTerminal()
        return controller
    }

    /// Ghostty `new_tab` 的宿主实现：在来源窗口内追加一个 lightty tab
    /// （窗口内 pane 树容器；不是 macOS 原生 tab group）。
    func newTab(
        from parentController: TerminalWindowController,
        initialPane: PaneView
    ) {
        guard parentController.window != nil else {
            newWindow(initialPane: initialPane)
            return
        }
        parentController.addTab(initialPane: initialPane)
        initialPane.focusTerminal()
    }

    var keyWindowController: TerminalWindowController? {
        windowControllers.first { $0.window?.isKeyWindow == true } ?? windowControllers.last
    }

    /// 全部运行中 pane（跨窗口）
    func runningPanes() -> [(controller: TerminalWindowController, pane: PaneView)] {
        windowControllers.flatMap { c in c.panes().map { (c, $0) } }
    }

    /// 任务重命名的唯一入口：移动文件 + 同步所有绑定该任务的 pane + 广播刷新。
    /// pane 端 pill 菜单与侧栏详情页都走这里，避免两处各自为政漏同步。
    @discardableResult
    func renameTask(at url: URL, to name: String) throws -> URL {
        let newURL = try taskStore.rename(at: url, to: name)
        for (_, pane) in runningPanes()
        where pane.taskFileURL?.standardizedFileURL == url.standardizedFileURL {
            pane.noteTaskRenamed(to: newURL, name: name)
        }
        NotificationCenter.default.post(name: .lighttyTasksDidChange, object: nil)
        return newURL
    }
}
