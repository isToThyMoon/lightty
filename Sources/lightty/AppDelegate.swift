import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        GhosttyRuntime.shared = GhosttyRuntime()
        AppState.shared = AppState()
        buildMenu()
        AppState.shared.newWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 面板可能还开着；跟随 Ghostty 习惯：最后一个终端窗口关掉即退出
        true
    }

    // MARK: - 菜单

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 lightty", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        // 菜单只提供鼠标入口。包括退出在内的键盘动作都必须先进
        // surface，再由 libghostty 按全局 config keybind 决定是否回调壳层。
        appMenu.addItem(withTitle: "退出 lightty", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")

        let taskMenuItem = NSMenuItem()
        mainMenu.addItem(taskMenuItem)
        let taskMenu = NSMenu(title: "任务")
        taskMenuItem.submenu = taskMenu

        // 终端类动作不设菜单快捷键：按键直达 surface，由 core 按用户 config 的
        // keybind（含默认 cmd+N/T/D/W、cmd+[]、cmd+alt+方向等）匹配后经 action_cb 回来。
        // 菜单项仅供鼠标点选。
        taskMenu.addItem(makeItem("新任务（新窗口）", #selector(newTaskWindow)))
        taskMenu.addItem(makeItem("新任务（新标签页）", #selector(newTaskTab)))
        taskMenu.addItem(.separator())
        taskMenu.addItem(makeItem("向右分 pane", #selector(splitRight)))
        taskMenu.addItem(makeItem("向下分 pane", #selector(splitDown)))
        taskMenu.addItem(makeItem("关闭 pane", #selector(closePane)))
        taskMenu.addItem(.separator())
        // 任务侧栏由标题栏按钮的 hover / click 驱动。不得占用 cmd+K：它属于
        // Ghostty 默认 keybind `super+k=clear_screen`，必须直达 surface/core。
        taskMenu.addItem(makeItem("任务侧边栏", #selector(toggleSidebar)))

        NSApp.mainMenu = mainMenu
    }

    /// 故意不接收 keyEquivalent：从类型接口上阻止 lightty 重新拦截
    /// Ghostty 快捷键。任务菜单是壳层的纯鼠标 adapter。
    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - actions

    @objc private func newTaskWindow() {
        guard let terminal = AppState.shared.keyWindowController?.activePane?.terminal else {
            AppState.shared.newWindow()
            return
        }
        terminal.performBindingAction("new_window")
    }

    @objc private func newTaskTab() {
        guard let controller = AppState.shared.keyWindowController else {
            AppState.shared.newWindow()
            return
        }
        controller.activePane?.terminal.performBindingAction("new_tab")
    }

    @objc private func splitRight() {
        AppState.shared.keyWindowController?.activePane?.terminal
            .performBindingAction("new_split:right")
    }

    @objc private func splitDown() {
        AppState.shared.keyWindowController?.activePane?.terminal
            .performBindingAction("new_split:down")
    }

    @objc private func closePane() {
        AppState.shared.keyWindowController?.activePane?.terminal
            .performBindingAction("close_surface")
    }

    @objc private func toggleSidebar() { AppState.shared.keyWindowController?.toggleSidebar() }
}
