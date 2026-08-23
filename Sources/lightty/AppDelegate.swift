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

    // MARK: - 菜单（快捷键统一挂菜单，先于 keyDown 分发）

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 lightty", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 lightty", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let taskMenuItem = NSMenuItem()
        mainMenu.addItem(taskMenuItem)
        let taskMenu = NSMenu(title: "任务")
        taskMenuItem.submenu = taskMenu

        // 终端类动作不设菜单快捷键：按键直达 surface，由 core 按用户 config 的
        // keybind（含默认 cmd+N/T/D/W、cmd+[]、cmd+alt+方向等）匹配后经 action_cb 回来。
        // 菜单项仅供鼠标点选。
        taskMenu.addItem(makeItem("新任务（新窗口）", #selector(newTaskWindow)))
        taskMenu.addItem(makeItem("新任务（右侧 pane）", #selector(newTaskPane)))
        taskMenu.addItem(.separator())
        taskMenu.addItem(makeItem("向右分 pane", #selector(splitRight)))
        taskMenu.addItem(makeItem("向下分 pane", #selector(splitDown)))
        taskMenu.addItem(makeItem("关闭 pane", #selector(closePane)))
        taskMenu.addItem(.separator())
        // lightty 拓展功能才有自己的快捷键：cmd+K 任务侧边栏（悬浮左侧，唯一任务入口）
        taskMenu.addItem(makeItem("任务侧边栏", #selector(toggleSidebar), "k"))

        NSApp.mainMenu = mainMenu
    }

    private func makeItem(
        _ title: String,
        _ action: Selector,
        _ key: String = "",
        _ mods: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = self
        return item
    }

    // MARK: - actions

    @objc private func newTaskWindow() { AppState.shared.newWindow() }

    @objc private func newTaskPane() {
        guard let controller = AppState.shared.keyWindowController else {
            AppState.shared.newWindow()
            return
        }
        controller.newTaskPaneRight()
    }

    @objc private func splitRight() {
        guard let c = AppState.shared.keyWindowController, let pane = c.activePane else { return }
        c.split(pane, direction: .right)
    }

    @objc private func splitDown() {
        guard let c = AppState.shared.keyWindowController, let pane = c.activePane else { return }
        c.split(pane, direction: .down)
    }

    @objc private func closePane() {
        guard let controller = AppState.shared.keyWindowController,
              let pane = controller.activePane else { return }
        controller.close(pane: pane)
    }

    @objc private func toggleSidebar() { AppState.shared.keyWindowController?.toggleSidebar() }
}
