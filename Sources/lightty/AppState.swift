import AppKit
import LighttyCore

/// 全局状态：任务绑定（连同它持有的 TaskStore，~/.lightty/tasks，唯一持久语义层）+ 存活窗口。
/// 任务目录的监听也在任务绑定里：Agent 在外部写回任务文件，列表与终端标题自己跟上。
final class AppState {
    static var shared: AppState!

    /// 任务绑定的唯一所有者，也是新建 / 改名 / 归档 / 删除任务的入口（要传导到绑定的终端）。
    /// 任务存储只经它的 `store` 访问：只读，或不影响绑定终端的写（例如只改 workdir）。
    let taskBindings: TaskBindings
    let sessionLibrary: SessionLibrary
    var windowControllers: [TerminalWindowController] = []
    /// 标签页默认名的序号源，全部窗口共用一份。
    let tabNumbering = TabNumbering()
    /// 造终端的唯一入口：检查、拼命令、关联、绑定、放置。删除会话期间的互斥也由它持有。
    private(set) lazy var paneLauncher = PaneLauncher(
        sessionLibrary: sessionLibrary, taskBindings: taskBindings,
        runningPanes: { [weak self] in self?.runningPanes() ?? [] },
        openWindow: { [weak self] pane in self?.newWindow(initialPane: pane) })

    /// - Parameter taskFolderChanges: 任务目录变更源，测试注入手动触发的替身；默认是真实监听。
    init(taskDirectory: URL? = nil, sweepStalePanes: Bool = true,
         sessionLibrary: SessionLibrary? = nil,
         taskFolderChanges: PathChangeSource = PathWatcher.changeSource) {
        // LIGHTTY_TASK_DIR：调试用的任务目录覆盖（跑一套假任务而不动 ~/.lightty/tasks）
        let override = ProcessInfo.processInfo.environment["LIGHTTY_TASK_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let dir = taskDirectory ?? override ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lightty/tasks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.taskBindings = TaskBindings(store: TaskStore(directory: dir), folderChanges: taskFolderChanges)
        self.sessionLibrary = sessionLibrary ?? SessionLibrary(fileURL: (taskDirectory != nil || override != nil ? dir : dir.deletingLastPathComponent())
            .appendingPathComponent(PersistenceFormat.organization.fileName), providers: taskDirectory != nil ? [] : nil)
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
        controller.syncSessionWindow()
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

    /// 绑着该任务、且此刻挂在窗口里的终端，按窗口树遍历序。谁绑着它由 `taskBindings`
    /// 回答；这里只把终端身份落到可跳转的窗口位置上。
    func boundPanes(of fileURL: URL) -> [(controller: TerminalWindowController, pane: PaneView)] {
        let ids = taskBindings.panes(for: fileURL)
        guard !ids.isEmpty else { return [] }
        return runningPanes().filter { ids.contains($0.pane.dragIdentifier) }
    }
}
