import AppKit
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 应用内更新（Sparkle）。只在打包形态下启动：SUFeedURL 由打包脚本写进
    /// Info.plist，swift build 的裸可执行没有它，此时保持 nil、菜单项不出现。
    private var updaterController: SPUStandardUpdaterController?

    private var shiftTapMonitor: Any?
    private var lastShiftTap: TimeInterval = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        GhosttyRuntime.shared = GhosttyRuntime()
        AppState.shared = AppState()
        installShiftTapMonitor()
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        }
        buildMenu()
        AppState.shared.newWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// ⇧⇧ 双击呼出全文搜索浮层。选修饰键双击是因为终端键位（cmd+K/P 等）
    /// 全部直达 surface 归 core keybind 管，壳层不抢；裸 shift 敲击不产生
    /// 任何终端输入，安全。监听不吞事件（原样放行）。
    private func installShiftTapMonitor() {
        shiftTapMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]
        ) { [weak self] event in
            self?.handleShiftTap(event)
            return event
        }
    }

    private func handleShiftTap(_ event: NSEvent) {
        if event.type == .keyDown {
            lastShiftTap = 0
            return
        }
        guard event.keyCode == 56 || event.keyCode == 60 else {  // 左/右 shift
            lastShiftTap = 0
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .shift {  // 纯 shift 按下
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastShiftTap < 0.35 {
                lastShiftTap = 0
                AppState.shared.keyWindowController?.toggleSearchPalette()
            } else {
                lastShiftTap = now
            }
        } else if !flags.isEmpty {  // shift 与其他修饰键组合，不算
            lastShiftTap = 0
        }
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
        appMenu.addItem(withTitle: L("About lightty"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        if let updaterController {
            let check = NSMenuItem(
                title: L("Check for Updates…"),
                action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                keyEquivalent: "")
            check.target = updaterController
            appMenu.addItem(check)
        }
        appMenu.addItem(.separator())
        // 菜单只提供鼠标入口。包括退出在内的键盘动作都必须先进
        // surface，再由 libghostty 按全局 config keybind 决定是否回调壳层。
        appMenu.addItem(withTitle: L("Quit lightty"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")

        let taskMenuItem = NSMenuItem()
        mainMenu.addItem(taskMenuItem)
        let taskMenu = NSMenu(title: L("Tasks"))
        taskMenuItem.submenu = taskMenu

        // 终端类动作不设菜单快捷键：按键直达 surface，由 core 按用户 config 的
        // keybind（含默认 cmd+N/T/D/W、cmd+[]、cmd+alt+方向等）匹配后经 action_cb 回来。
        // 菜单项仅供鼠标点选。
        taskMenu.addItem(makeItem(L("New Task (New Window)"), #selector(newTaskWindow)))
        taskMenu.addItem(makeItem(L("New Task (New Workspace)"), #selector(newTaskTab)))
        taskMenu.addItem(.separator())
        taskMenu.addItem(makeItem(L("Split Pane Right"), #selector(splitRight)))
        taskMenu.addItem(makeItem(L("Split Pane Down"), #selector(splitDown)))
        taskMenu.addItem(makeItem(L("Close Pane"), #selector(closePane)))
        taskMenu.addItem(.separator())
        // 任务侧栏由标题栏按钮的 hover / click 驱动。不得占用 cmd+K：它属于
        // Ghostty 默认 keybind `super+k=clear_screen`，必须直达 surface/core。
        taskMenu.addItem(makeItem(L("Task Sidebar"), #selector(toggleSidebar)))

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
