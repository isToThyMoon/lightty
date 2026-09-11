import AppKit
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 应用内更新（Sparkle）。只在打包形态下启动：SUFeedURL 由打包脚本写进
    /// Info.plist，swift build 的裸可执行没有它，此时保持 nil、菜单项不出现。
    private var updaterController: SPUStandardUpdaterController?
    private var aboutWindowController: AboutWindowController?

    private var textEditingShortcuts: TextEditingShortcuts?
    private var shiftTapMonitor: Any?
    private var lastShiftTap: TimeInterval = 0
    private weak var fontDownloadMenuItem: NSMenuItem?
    private var fontDownloadAlert: NSAlert?
    private var fontDownloadDidFinish = false
    private let fontDownloadPreview = TerminalFontDownloadPreview()
    private var isFontDownloadPreviewMode = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesStorageFailed),
            name: FilePreferences.failureNotification, object: FilePreferences.shared)
        if FilePreferences.shared.lastError != nil {
            DispatchQueue.main.async { [weak self] in self?.preferencesStorageFailed() }
        }
        AppearancePreference.apply()
        AgentLaunchPreference.migrateLegacyCommands()
        GhosttyRuntime.shared = GhosttyRuntime()
        AppState.shared = AppState()
        textEditingShortcuts = TextEditingShortcuts()
        installShiftTapMonitor()
        // 语言 / 终端主题在设置页改了之后菜单文案与勾选态要跟上：整份重建。
        NotificationCenter.default.addObserver(
            self, selector: #selector(rebuildMenuForPreferences),
            name: .lighttyPreferencesDidChange, object: nil)
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        }
        buildMenu()
        // Finder 右键 Services（New Lightty Tab/Window Here）。菜单项由打包脚本写进
        // Info.plist 的 NSServices；这里只挂接收方。必须在 AppState 就绪之后。
        NSApp.servicesProvider = FinderServiceProvider()
        // 重链 shim + 重新生成插件源目录。
        // hook 注册的是 ~/.lightty/bin/lightty-hook 这个固定路径，真实 helper 在
        // app bundle 里，用户把 app 挪个位置绝对路径就断了。而两家都在安装时**拷贝**
        // 插件，所以重新生成不改变已装插件的行为——它保证的是升级 lightty 后
        // needsUpdate 有个正确的对照物。内容没变则不落盘。
        HookInstaller.refresh()
        // agent 状态呈现：菜单栏聚合态 + 跑完/需要介入时的系统通知。
        // 两者都幂等、都不在这里申请通知权限（首次真要发通知时才问）。
        StatusBarController.shared.install()
        PaneNotifier.shared.install()
        // Session data has application lifetime; opening a sidebar never bootstraps it.
        AppState.shared.sessionLibrary.start()
        // 绑定状态 socket。必须在首个 pane spawn 之前：pane 的 shell 一起来就带着
        // LIGHTTY_SOCK，agent 随时可能打第一发；socket 没绑好那一发就发进虚空。
        PaneStatusStore.shared.start()
        // 会话恢复：上次关窗/退出时的窗口、标签页、pane（含命名、cwd、任务绑定、
        // agent --resume）。没有快照或快照为空才开默认窗口。
        let restored = WorkspaceStore.shared.load().map(WorkspaceRestorer.restore) ?? []
        let first = restored.first ?? AppState.shared.newWindow()
        // 之后任何结构/命名/状态变化都刷快照（节流合并）
        for name in [Notification.Name.lighttyTasksDidChange, .lighttyPaneStatusDidChange] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(scheduleSessionSave), name: name, object: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        // 主动引导：装了 agent 却没装 hook 时才弹，且只弹一次（用户按「暂不」后
        // 只走菜单）。推到下一个 runloop tick：蒙层挂在 themeFrame 上，同步调用时
        // 窗口未必已经建好视图树，guard 不满足就会**静默不弹**——那种"看起来没坏
        // 但功能不见了"的失败最难查。顺带让窗口先完成出现动画。
        DispatchQueue.main.async {
            HookSetupOverlay.presentIfNeeded(in: first)
        }
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

    @objc private func scheduleSessionSave() {
        WorkspaceStore.shared.scheduleSave()
    }

    @objc private func preferencesStorageFailed() {
        let alert = AppBranding.makeAlert()
        alert.messageText = L("Preferences could not be saved.")
        alert.informativeText = L("Check ~/.lightty/preferences.json and its permissions. An unreadable or newer file will not be overwritten.")
        alert.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        FilePreferences.shared.flush()
        // cmd+Q 等路径窗口还都在，此刻定格会话；关最后一个窗口的路径已在
        // windowWillClose 定格过（frozen），这里不会覆盖。
        WorkspaceStore.shared.saveNow()
        // 关 fd、unlink socket 文件。残留文件并非致命（下次启动按 pid 判活清掉），
        // 但干净退出不该给下一次启动留活。
        PaneStatusStore.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 面板可能还开着；跟随 Ghostty 习惯：最后一个终端窗口关掉即退出
        true
    }

    // MARK: - 菜单

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(makeItem(L("New Window"), #selector(dockNewWindow)))
        menu.addItem(makeItem(L("New Tab"), #selector(dockNewTab)))
        for controller in AppState.shared?.windowControllers ?? [] {
            guard controller.tabCount > 0 else { continue }
            menu.addItem(.separator())
            controller.appendDockTabItems(to: menu)
        }
        return menu
    }

    @objc private func dockNewWindow() {
        NSApp.activate(ignoringOtherApps: true)
        newTaskWindow()
    }

    @objc private func dockNewTab() {
        NSApp.activate(ignoringOtherApps: true)
        if let controller = AppState.shared.keyWindowController {
            controller.window?.deminiaturize(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            controller.hideSettings()
            if controller.activePane == nil {
                controller.addTab(initialPane: PaneView())
                return
            }
        }
        newTaskTab()
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.delegate = self
        appMenuItem.submenu = appMenu
        appMenu.addItem(makeItem(L("About lightty"), #selector(showAbout)))
        if let updaterController {
            let check = NSMenuItem(
                title: L("Check for Updates…"),
                action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                keyEquivalent: "")
            check.target = updaterController
            appMenu.addItem(check)
        }
        appMenu.addItem(.separator())
        appMenu.addItem(makeItem(L("Settings…"), #selector(showSettings)))
        appMenu.addItem(.separator())
        let fontDownload = NSMenuItem(
            title: L("Download Maple Mono NF CN…"),
            action: #selector(downloadLighttyFont(_:)),
            keyEquivalent: "")
        fontDownload.target = self
        appMenu.addItem(fontDownload)
        fontDownloadMenuItem = fontDownload
        updateFontMenuItems()
        // 菜单栏状态项可以被它自己的菜单关掉，关掉后就没有入口再打开了——
        // 这里是唯一的复位开关，不能省。
        let statusBarToggle = NSMenuItem(
            title: L("Show in Menu Bar"),
            action: #selector(StatusBarController.toggleEnabled(_:)),
            keyEquivalent: "")
        statusBarToggle.target = StatusBarController.shared
        appMenu.addItem(statusBarToggle)
        appMenu.addItem(.separator())
        // 标准 Services 子菜单：内容由系统按当前选区填充（其它 app 提供的服务），
        // 与 Ghostty 一样挂上，让 app 菜单符合 macOS 惯例。
        let servicesItem = NSMenuItem(title: L("Services"), action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: L("Services"))
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu
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
        taskMenu.addItem(makeItem(L("New Task (New Tab)"), #selector(newTaskTab)))
        taskMenu.addItem(.separator())
        taskMenu.addItem(makeItem(L("Split Pane Right"), #selector(splitRight)))
        taskMenu.addItem(makeItem(L("Split Pane Down"), #selector(splitDown)))
        taskMenu.addItem(makeItem(L("Close Pane"), #selector(closePane)))
        taskMenu.addItem(.separator())
        // 任务侧栏由标题栏按钮的 hover / click 驱动。不得占用 cmd+K：它属于
        // Ghostty 默认 keybind `super+k=clear_screen`，必须直达 surface/core。
        taskMenu.addItem(makeItem(L("Task Sidebar"), #selector(toggleSidebar)))
        taskMenu.addItem(makeItem(L("Tab Sidebar"), #selector(toggleTabSidebar)))

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

    @objc private func showAbout() {
        if aboutWindowController == nil { aboutWindowController = AboutWindowController() }
        aboutWindowController?.present()
    }

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

    @objc private func showSettings() {
        guard let controller = AppState.shared.keyWindowController else {
            AppState.shared.newWindow().showSettings()
            return
        }
        controller.showSettings()
    }

    @objc private func rebuildMenuForPreferences() { buildMenu() }

    @objc private func toggleSidebar() { AppState.shared.keyWindowController?.toggleSidebar() }
    @objc private func toggleTabSidebar() {
        AppState.shared.keyWindowController?.toggleTabSidebar()
    }

    @objc private func downloadLighttyFont(_ sender: NSMenuItem) {
        TerminalFontManager.shared.refreshAvailability()
        updateFontMenuItems()
        guard isFontDownloadPreviewMode
                || !TerminalFontManager.shared.isLighttyFontAvailable
        else { return }
        guard let controller = AppState.shared.keyWindowController else { return }
        presentFontDownload(in: controller, preview: isFontDownloadPreviewMode)
    }

    private func updateFontMenuItems() {
        let manager = TerminalFontManager.shared
        fontDownloadMenuItem?.title = isFontDownloadPreviewMode
            ? L("Preview Font Download…")
            : L("Download Maple Mono NF CN…")
        fontDownloadMenuItem?.isHidden = manager.isLighttyFontAvailable
            && !isFontDownloadPreviewMode
        fontDownloadMenuItem?.isEnabled = !manager.isDownloading && !fontDownloadPreview.isRunning
    }

    private func presentFontDownload(
        in controller: TerminalWindowController,
        preview: Bool
    ) {
        guard let window = controller.window,
              window.attachedSheet == nil,
              !TerminalFontManager.shared.isDownloading,
              !fontDownloadPreview.isRunning
        else { return }

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 44))
        let label = NSTextField(labelWithString: L("Downloading font…"))
        label.frame = NSRect(x: 0, y: 26, width: 320, height: 18)
        let progress = NSProgressIndicator(frame: NSRect(x: 0, y: 4, width: 320, height: 14))
        progress.minValue = 0
        progress.maxValue = 1
        progress.isIndeterminate = false
        accessory.addSubview(label)
        accessory.addSubview(progress)

        let alert = AppBranding.makeAlert()
        alert.messageText = preview
            ? L("Previewing Font Download")
            : L("Installing Maple Mono NF CN")
        alert.informativeText = preview
            ? L("Preview mode makes no network request and changes no font files.")
            : L("The verified font will be installed in ~/Library/Fonts and will be available to other apps.")
        alert.accessoryView = accessory
        alert.addButton(withTitle: L("Cancel"))
        fontDownloadAlert = alert
        fontDownloadDidFinish = false
        updateFontMenuItems()

        alert.beginSheetModal(for: window) { [weak self] _ in
            guard let self, !self.fontDownloadDidFinish else { return }
            if preview { self.fontDownloadPreview.cancel() }
            else { TerminalFontManager.shared.cancelDownload() }
        }

        let phaseHandler: (TerminalFontDownloadPhase) -> Void = { phase in
            switch phase {
            case .downloading(let fraction):
                progress.isIndeterminate = false
                progress.stopAnimation(nil)
                progress.doubleValue = fraction
            case .installing:
                label.stringValue = L("Verifying and installing…")
                progress.isIndeterminate = true
                progress.startAnimation(nil)
                // 下载阶段可以安全取消；进入校验/原子替换后只剩很短的一段，
                // 中途打断反而可能留下不完整的用户字体组合。
                alert.buttons.first?.isEnabled = false
            }
        }
        let completionHandler: (Result<Void, Error>) -> Void = { [weak self, weak window] result in
            guard let self else { return }
            self.fontDownloadDidFinish = true
            if let window, window.attachedSheet == alert.window {
                window.endSheet(alert.window)
            }
            self.fontDownloadAlert = nil
            self.updateFontMenuItems()

            switch result {
            case .success:
                if preview {
                    self.presentFontResult(
                        title: L("Font download preview complete"),
                        detail: L("The preview completed without network or filesystem changes."),
                        in: window)
                } else {
                    GhosttyRuntime.shared.reloadGlobalConfig()
                    self.presentFontResult(
                        title: L("Font installed"),
                        detail: L("Maple Mono NF CN is now available to Lightty and other apps."),
                        in: window)
                }
            case .failure(TerminalFontDownloadError.cancelled):
                break
            case .failure(let error):
                self.presentFontResult(
                    title: L("Could not install font"),
                    detail: error.localizedDescription,
                    in: window)
            }
        }
        if preview {
            fontDownloadPreview.start(
                progress: phaseHandler,
                completion: completionHandler)
        } else {
            TerminalFontManager.shared.download(
                progress: phaseHandler,
                completion: completionHandler)
        }
        updateFontMenuItems()
    }

    private func presentFontResult(title: String, detail: String, in window: NSWindow?) {
        let alert = AppBranding.makeAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: L("OK"))
        if let window { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }

}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        isFontDownloadPreviewMode = NSEvent.modifierFlags.contains(.option)
        TerminalFontManager.shared.refreshAvailability()
        updateFontMenuItems()
    }
}
