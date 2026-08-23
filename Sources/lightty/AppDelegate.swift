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

        // cmd+N：新任务 → 独立窗口（交给 aerospace 平铺）
        taskMenu.addItem(makeItem("新任务（新窗口）", #selector(newTaskWindow), "n"))
        // cmd+T：新任务 → 当前窗口右侧并排 pane
        taskMenu.addItem(makeItem("新任务（右侧 pane）", #selector(newTaskPane), "t"))
        taskMenu.addItem(.separator())
        // cmd+D / cmd+shift+D：分屏继承当前任务
        taskMenu.addItem(makeItem("向右分 pane", #selector(splitRight), "d"))
        taskMenu.addItem(makeItem("向下分 pane", #selector(splitDown), "d", [.command, .shift]))
        taskMenu.addItem(.separator())
        taskMenu.addItem(makeItem("关闭 pane", #selector(closePane), "w"))
        taskMenu.addItem(.separator())
        taskMenu.addItem(makeItem("任务面板", #selector(togglePanel), "k"))
        taskMenu.addItem(makeItem("任务侧边栏", #selector(toggleSidebar), "k", [.command, .shift]))

        let navMenuItem = NSMenuItem()
        mainMenu.addItem(navMenuItem)
        let navMenu = NSMenu(title: "导航")
        navMenuItem.submenu = navMenu
        navMenu.addItem(makeItem("下一个 pane", #selector(nextPane), "]"))
        navMenu.addItem(makeItem("上一个 pane", #selector(prevPane), "["))
        navMenu.addItem(makeItem("左 pane", #selector(paneLeft), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option]))
        navMenu.addItem(makeItem("右 pane", #selector(paneRight), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option]))
        navMenu.addItem(makeItem("上 pane", #selector(paneUp), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option]))
        navMenu.addItem(makeItem("下 pane", #selector(paneDown), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option]))

        NSApp.mainMenu = mainMenu
    }

    private func makeItem(
        _ title: String,
        _ action: Selector,
        _ key: String,
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

    @objc private func splitRight() { AppState.shared.keyWindowController?.splitActivePane(vertical: true) }
    @objc private func splitDown() { AppState.shared.keyWindowController?.splitActivePane(vertical: false) }

    @objc private func closePane() {
        guard let controller = AppState.shared.keyWindowController,
              let pane = controller.activePane else { return }
        controller.close(pane: pane)
    }

    @objc private func togglePanel() { TaskPanelController.shared.toggle() }
    @objc private func toggleSidebar() { SidebarController.shared.toggle() }

    @objc private func nextPane() { AppState.shared.keyWindowController?.focusPane(offset: 1) }
    @objc private func prevPane() { AppState.shared.keyWindowController?.focusPane(offset: -1) }
    @objc private func paneLeft() { AppState.shared.keyWindowController?.focusPane(direction: .leading) }
    @objc private func paneRight() { AppState.shared.keyWindowController?.focusPane(direction: .trailing) }
    @objc private func paneUp() { AppState.shared.keyWindowController?.focusPane(direction: .top) }
    @objc private func paneDown() { AppState.shared.keyWindowController?.focusPane(direction: .bottom) }
}
