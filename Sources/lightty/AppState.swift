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

    /// Ghostty `new_tab` 的宿主实现：新 controller/新 surface 进入来源窗口的原生
    /// macOS tab group。split tree 留在各 tab 内，二者不再复用同一种布局。
    @discardableResult
    func newTab(
        from parentController: TerminalWindowController,
        initialPane: PaneView
    ) -> TerminalWindowController {
        guard let parentWindow = parentController.window else {
            return newWindow(initialPane: initialPane)
        }

        let controller = TerminalWindowController(initialPane: initialPane, isNativeTab: true)
        windowControllers.append(controller)
        guard let childWindow = controller.window else { return controller }

        if parentWindow.isMiniaturized { parentWindow.deminiaturize(nil) }
        childWindow.setFrame(parentWindow.frame, display: false)
        if let tabGroup = parentWindow.tabGroup,
           tabGroup.windows.contains(where: { $0 === childWindow }) {
            tabGroup.removeWindow(childWindow)
        }
        if childWindow.tabbingMode != .disallowed {
            parentWindow.addTabbedWindow(childWindow, ordered: .above)
        }
        for (window, pane) in [
            (parentWindow, parentController.activePane),
            (childWindow, Optional(initialPane)),
        ] {
            window.titleVisibility = .visible
            window.tab.title = pane?.header.title ?? "未命名"
            window.title = ""
        }
        // 与 Ghostty 一样把 presentation 推到下一轮：此时 AppKit 的 tabGroup 已稳定，
        // 新 tab 不会先以独立窗口 frame 出现，tab bar 也能在首次选中时完整绘制。
        DispatchQueue.main.async { [weak parentWindow, weak childWindow] in
            guard let parentWindow, let childWindow else { return }
            if let group = parentWindow.tabGroup, group.windows.count > 1 {
                group.selectedWindow = childWindow
                if !group.isTabBarVisible { parentWindow.toggleTabBar(nil) }
            }
            parentWindow.makeKeyAndOrderFront(nil)
            initialPane.focusTerminal()
        }
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
