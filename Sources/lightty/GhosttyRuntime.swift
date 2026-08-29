import AppKit
import GhosttyKit
import UserNotifications

/// 启动时从 ghostty 配置读出的 terminal host 所需值。
/// 仅用于 surface、pane chrome、分隔线和透明窗口底座；应用标题栏/任务侧栏有独立
/// 的 ShellStyle，不能从这些值派生（HANDOVER 8.2.1）。
struct GhosttyConfigValues {
    var backgroundColor: NSColor = .windowBackgroundColor
    var foregroundColor: NSColor = .textColor
    var backgroundOpacity: Double = 1
    var backgroundBlur: Int16 = 0
    var splitDividerColor: NSColor = .separatorColor

    var isTransparent: Bool { backgroundOpacity < 1 }
}

/// libghostty 生命周期与回调的唯一持有者。
/// 调用序列与回调约定见 docs/libghostty-embedding.md（钉在 vendor 的 ghostty.h，API 不稳定）。
final class GhosttyRuntime {
    static var shared: GhosttyRuntime!

    let app: ghostty_app_t
    private(set) var configValues: GhosttyConfigValues
    private(set) var configDiagnostics: [String]
    /// 保留官方加载链产生的 config，供 soft reload 使用。
    /// libghostty 会在 app/surface update 时 clone，但 runtime 仍需要拥有自己这份。
    private var loadedConfig: ghostty_config_t
    private var notificationObservers: [NSObjectProtocol] = []
    private var appearanceObservation: NSKeyValueObservation?

    init() {
        // GhosttyKit 静态库不携带 themes/terminfo 等资源。必须在 ghostty_init 读取并
        // 固化进程环境之前定位 app bundle 或开发期 vendor 资源目录。
        GhosttyResources.configureEnvironmentIfNeeded()
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            fatalError("ghostty_init failed")
        }

        // 终端配置边界：只走 Ghostty 的全局配置链，并把 finalize 后的同一份 config
        // 原样交给 ghostty_app_new。lightty 不加载覆盖文件，也不改写任何 terminal 选项。
        // 有意跳过 load_cli_args：这里的命令行属于 lightty，而不是 Ghostty.app。
        guard let config = ghostty_config_new() else { fatalError("ghostty_config_new failed") }
        ghostty_config_load_default_files(config)
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)
        self.configValues = Self.readConfigValues(config)
        self.configDiagnostics = Self.readDiagnostics(config)
        self.loadedConfig = config

        var rt = ghostty_runtime_config_s()
        rt.userdata = nil
        rt.supports_selection_clipboard = true
        rt.wakeup_cb = { _ in
            // 任意线程 → 主队列 tick，全进程仅此一处
            DispatchQueue.main.async { GhosttyRuntime.shared?.tick() }
        }
        rt.action_cb = { _, target, action in
            GhosttyRuntime.handleAction(target: target, action: action)
        }
        rt.read_clipboard_cb = { userdata, location, state in
            GhosttyRuntime.readClipboard(userdata, location: location, state: state)
        }
        rt.confirm_read_clipboard_cb = { userdata, string, state, request in
            GhosttyRuntime.confirmClipboardRead(
                userdata,
                string: string,
                state: state,
                request: request)
        }
        rt.write_clipboard_cb = { _, location, content, count, confirm in
            GhosttyRuntime.writeClipboard(
                location: location,
                content: content,
                count: count,
                confirm: confirm)
        }
        rt.close_surface_cb = { userdata, _ in
            guard let userdata else { return }
            let view = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async { view.requestClose() }
        }

        guard let app = ghostty_app_new(&rt, config) else { fatalError("ghostty_app_new failed") }
        self.app = app

        // 官方 App bridge 的进程级输入状态。键盘布局变更后 core 必须
        // 重建 key map，否则同一份 config 在切输入法后会产生不同结果。
        // Config probe 模式不创建 NSApplication，此时 NSApp 合法为 nil。
        ghostty_app_set_focus(app, NSApp?.isActive ?? false)
        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(
                forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                ghostty_app_keyboard_changed(self.app)
            },
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                ghostty_app_set_focus(self.app, true)
            },
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                ghostty_app_set_focus(self.app, false)
            },
        ]

        // 系统明暗外观桥（对齐官方 AppDelegate.appearanceObserver）：libghostty
        // 不自行感知系统外观，必须由壳层上报，config 的
        // `theme = light:X,dark:Y` 才会随系统切换。Config probe 模式 NSApp 为 nil。
        appearanceObservation = NSApp?.observe(
            \.effectiveAppearance, options: [.new, .initial]
        ) { [weak self] _, change in
            guard let self, let appearance = change.newValue else { return }
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ghostty_app_set_color_scheme(
                self.app,
                dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
        }
    }

    deinit {
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        ghostty_app_free(app)
        ghostty_config_free(loadedConfig)
    }

    /// 与 Ghostty `+show-config` 可直接 diff 的最小配置探针。
    /// 只用于开发诊断，不参与正常 UI 或配置逻辑。
    var terminalConfigProbe: String {
        let values = [
            "background = \(configValues.backgroundColor.hexRGB)",
            "foreground = \(configValues.foregroundColor.hexRGB)",
            "background-opacity = \(configValues.backgroundOpacity)",
            "background-blur = \(configValues.backgroundBlur)",
        ]
        let diagnostics = configDiagnostics.map { "diagnostic = \($0)" }
        return (values + diagnostics).joined(separator: "\n")
    }

    func tick() {
        ghostty_app_tick(app)
    }

    /// 与官方 Ghostty.Config 相同的文件加载链。这是 reload 的唯一入口，
    /// 不允许 lightty overlay 或壳层二次解析。
    private static func loadGlobalConfig() -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        ghostty_config_load_default_files(config)
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)
        return config
    }

    private func reloadConfig(surface: ghostty_surface_t?, soft: Bool) {
        if soft {
            if let surface {
                ghostty_surface_update_config(surface, loadedConfig)
            } else {
                ghostty_app_update_config(app, loadedConfig)
            }
            return
        }

        guard let fresh = Self.loadGlobalConfig() else { return }
        if let surface {
            // 对齐官方：surface target 只刷新当前 surface。
            ghostty_surface_update_config(surface, fresh)
            ghostty_config_free(fresh)
        } else {
            ghostty_app_update_config(app, fresh)
            ghostty_config_free(loadedConfig)
            loadedConfig = fresh
            configValues = Self.readConfigValues(fresh)
            configDiagnostics = Self.readDiagnostics(fresh)
        }
    }

    // MARK: - action 派发
    // 快捷键完全交给 core：core 读 Ghostty 全局 config 的 keybind（含默认值）
    // 匹配后经此回调让壳层完成原生宿主动作。lightty 不设第二套键位。

    private static func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        func targetSurface() -> ghostty_surface_t? {
            guard target.tag == GHOSTTY_TARGET_SURFACE else { return nil }
            return target.target.surface
        }

        func targetView() -> TerminalSurfaceView? {
            guard let surface = targetSurface(),
                  let userdata = ghostty_surface_userdata(surface) else { return nil }
            return Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        }

        // target surface → (窗口控制器, pane)
        func locate() -> (TerminalWindowController, PaneView)? {
            guard let view = targetView() else { return nil }
            for controller in AppState.shared.windowControllers {
                if let pane = controller.panes().first(where: { $0.terminal === view }) {
                    return (controller, pane)
                }
            }
            return nil
        }

        switch action.tag {
        case GHOSTTY_ACTION_NEW_WINDOW:
            let configuration = targetSurface().map {
                TerminalSurfaceConfiguration(
                    inheriting: $0,
                    context: GHOSTTY_SURFACE_CONTEXT_WINDOW)
            } ?? .init()
            DispatchQueue.main.async {
                AppState.shared.newWindow(initialPane: PaneView(surfaceConfiguration: configuration))
            }
            return true

        case GHOSTTY_ACTION_NEW_TAB:
            guard let surface = targetSurface() else { return false }
            let configuration = TerminalSurfaceConfiguration(
                inheriting: surface,
                context: GHOSTTY_SURFACE_CONTEXT_TAB)
            DispatchQueue.main.async {
                guard let (parent, _) = locate() else { return }
                AppState.shared.newTab(
                    from: parent,
                    initialPane: PaneView(surfaceConfiguration: configuration))
            }
            return true

        case GHOSTTY_ACTION_NEW_SPLIT:
            guard let surface = targetSurface() else { return false }
            let direction: TerminalWindowController.SplitDirection
            switch action.action.new_split {
            case GHOSTTY_SPLIT_DIRECTION_RIGHT: direction = .right
            case GHOSTTY_SPLIT_DIRECTION_DOWN: direction = .down
            case GHOSTTY_SPLIT_DIRECTION_LEFT: direction = .left
            case GHOSTTY_SPLIT_DIRECTION_UP: direction = .up
            default: return false
            }
            let configuration = TerminalSurfaceConfiguration(
                inheriting: surface,
                context: GHOSTTY_SURFACE_CONTEXT_SPLIT)
            DispatchQueue.main.async {
                guard let (controller, pane) = locate() else { return }
                controller.split(
                    pane,
                    direction: direction,
                    surfaceConfiguration: configuration)
            }
            return true

        case GHOSTTY_ACTION_GOTO_TAB:
            guard let (controller, _) = locate() else { return false }
            let requested = action.action.goto_tab
            DispatchQueue.main.async {
                let target: TerminalWindowController.GotoTab
                switch requested {
                case GHOSTTY_GOTO_TAB_PREVIOUS: target = .previous
                case GHOSTTY_GOTO_TAB_NEXT: target = .next
                case GHOSTTY_GOTO_TAB_LAST: target = .last
                default: target = .index(Int(requested.rawValue)) // 1-based
                }
                controller.gotoTab(target)
            }
            return true

        case GHOSTTY_ACTION_GOTO_WINDOW:
            let controllers = AppState.shared.windowControllers.filter {
                guard let window = $0.window else { return false }
                return window.isVisible && !window.isMiniaturized
            }
            guard controllers.count > 1 else { return false }
            let currentController = locate()?.0 ?? AppState.shared.keyWindowController
            guard let currentController,
                  let current = controllers.firstIndex(where: { $0 === currentController }) else {
                return false
            }
            let offset: Int
            switch action.action.goto_window {
            case GHOSTTY_GOTO_WINDOW_PREVIOUS: offset = -1
            case GHOSTTY_GOTO_WINDOW_NEXT: offset = 1
            default: return false
            }
            let destination = controllers[
                (current + offset + controllers.count) % controllers.count]
            DispatchQueue.main.async {
                guard let window = destination.window else { return }
                window.makeKeyAndOrderFront(nil)
                destination.activePane?.focusTerminal()
            }
            return true

        case GHOSTTY_ACTION_GOTO_SPLIT:
            let goto_ = action.action.goto_split
            DispatchQueue.main.async {
                guard let (controller, _) = locate() else { return }
                switch goto_ {
                case GHOSTTY_GOTO_SPLIT_PREVIOUS: controller.focusPane(offset: -1)
                case GHOSTTY_GOTO_SPLIT_NEXT: controller.focusPane(offset: 1)
                case GHOSTTY_GOTO_SPLIT_UP: controller.focusPane(direction: .top)
                case GHOSTTY_GOTO_SPLIT_LEFT: controller.focusPane(direction: .leading)
                case GHOSTTY_GOTO_SPLIT_DOWN: controller.focusPane(direction: .bottom)
                case GHOSTTY_GOTO_SPLIT_RIGHT: controller.focusPane(direction: .trailing)
                default: break
                }
            }
            return true

        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            DispatchQueue.main.async { locate()?.0.equalizeAllSplits() }
            return true

        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
            guard locate() != nil else { return false }
            DispatchQueue.main.async {
                guard let (controller, pane) = locate() else { return }
                _ = controller.toggleSplitZoom(pane)
            }
            return true

        case GHOSTTY_ACTION_RESIZE_SPLIT:
            let resize = action.action.resize_split
            let direction: TerminalWindowController.SplitDirection
            switch resize.direction {
            case GHOSTTY_RESIZE_SPLIT_UP: direction = .up
            case GHOSTTY_RESIZE_SPLIT_DOWN: direction = .down
            case GHOSTTY_RESIZE_SPLIT_LEFT: direction = .left
            case GHOSTTY_RESIZE_SPLIT_RIGHT: direction = .right
            default: return false
            }
            let amount = CGFloat(resize.amount)
            DispatchQueue.main.async {
                guard let (controller, pane) = locate() else { return }
                controller.resizeSplit(pane, direction: direction, amount: amount)
            }
            return true

        case GHOSTTY_ACTION_INITIAL_SIZE:
            // core 按 window-width/height × cell 算好的初始尺寸（点）。
            // 应用后格子正好占满、无余数——window-padding-balance 下顶部不再多出一截。
            let size = action.action.initial_size
            DispatchQueue.main.async {
                if ProcessInfo.processInfo.environment["LIGHTTY_DEBUG_LAYOUT"] != nil {
                    NSLog("INITIAL_SIZE %dx%d, located=%@", size.width, size.height,
                          locate() != nil ? "yes" : "no")
                }
                guard let (controller, _) = locate(), let window = controller.window,
                      controller.panes().count == 1,
                      controller.tabCount == 1 else { return }
                window.setContentSize(NSSize(
                    width: CGFloat(size.width),
                    height: CGFloat(size.height) + PaneHeaderView.height))
                window.center()
            }
            return true

        case GHOSTTY_ACTION_CELL_SIZE:
            guard let view = targetView() else { return false }
            let size = action.action.cell_size
            DispatchQueue.main.async { [weak view] in
                view?.setCellSize(backingWidth: size.width, backingHeight: size.height)
            }
            return true

        case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
            guard let window = locate()?.0.window else { return false }
            DispatchQueue.main.async { window.toggleFullScreen(nil) }
            return true

        case GHOSTTY_ACTION_TOGGLE_MAXIMIZE:
            guard let window = locate()?.0.window else { return false }
            DispatchQueue.main.async { window.zoom(nil) }
            return true

        case GHOSTTY_ACTION_PRESENT_TERMINAL:
            guard let (controller, pane) = locate(), let window = controller.window else {
                return false
            }
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                pane.focusTerminal()
            }
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            guard let view = targetView() else { return false }
            let shape = action.action.mouse_shape
            DispatchQueue.main.async { [weak view] in view?.setCursorShape(shape) }
            return true

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            guard let view = targetView() else { return false }
            let visible = action.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE
            DispatchQueue.main.async { [weak view] in view?.setCursorVisibility(visible) }
            return true

        case GHOSTTY_ACTION_OPEN_CONFIG:
            DispatchQueue.main.async { ghostty_app_open_config(GhosttyRuntime.shared.app) }
            return true

        case GHOSTTY_ACTION_RELOAD_CONFIG:
            let surface = targetSurface()
            let soft = action.action.reload_config.soft
            DispatchQueue.main.async {
                GhosttyRuntime.shared.reloadConfig(surface: surface, soft: soft)
            }
            return true

        case GHOSTTY_ACTION_OPEN_URL:
            return openURL(action.action.open_url)

        case GHOSTTY_ACTION_UNDO:
            guard let manager = targetView()?.undoManager, manager.canUndo else { return false }
            DispatchQueue.main.async { manager.undo() }
            return true

        case GHOSTTY_ACTION_REDO:
            guard let manager = targetView()?.undoManager, manager.canRedo else { return false }
            DispatchQueue.main.async { manager.redo() }
            return true

        case GHOSTTY_ACTION_CLOSE_ALL_WINDOWS:
            DispatchQueue.main.async {
                AppState.shared.windowControllers.compactMap(\.window).forEach { $0.close() }
            }
            return true

        case GHOSTTY_ACTION_TOGGLE_VISIBILITY:
            DispatchQueue.main.async {
                if NSApp.isHidden {
                    NSApp.unhide(nil)
                    NSApp.activate(ignoringOtherApps: true)
                } else {
                    NSApp.hide(nil)
                }
            }
            return true

        case GHOSTTY_ACTION_START_SEARCH:
            guard let (_, pane) = locate() else { return false }
            let needle = action.action.start_search.needle.map { String(cString: $0) }
            DispatchQueue.main.async { [weak pane] in pane?.startTerminalSearch(needle: needle) }
            return true

        case GHOSTTY_ACTION_END_SEARCH:
            guard let (_, pane) = locate() else { return false }
            DispatchQueue.main.async { [weak pane] in
                pane?.endTerminalSearch(requestCore: false)
            }
            return true

        case GHOSTTY_ACTION_SEARCH_TOTAL:
            guard let (_, pane) = locate() else { return false }
            let raw = action.action.search_total.total
            let total = raw >= 0 ? Int(raw) : nil
            DispatchQueue.main.async { [weak pane] in pane?.updateTerminalSearchTotal(total) }
            return true

        case GHOSTTY_ACTION_SEARCH_SELECTED:
            guard let (_, pane) = locate() else { return false }
            let raw = action.action.search_selected.selected
            let selected = raw >= 0 ? Int(raw) : nil
            DispatchQueue.main.async { [weak pane] in
                pane?.updateTerminalSearchSelected(selected)
            }
            return true

        case GHOSTTY_ACTION_CLOSE_TAB:
            guard let (controller, _) = locate() else { return false }
            let mode = action.action.close_tab_mode
            DispatchQueue.main.async {
                switch mode {
                case GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS:
                    controller.closeTabs(mode: .this)
                case GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER:
                    controller.closeTabs(mode: .other)
                case GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT:
                    controller.closeTabs(mode: .right)
                default:
                    break
                }
            }
            return true

        case GHOSTTY_ACTION_CLOSE_WINDOW:
            guard let window = locate()?.0.window else { return false }
            DispatchQueue.main.async { window.close() }
            return true

        case GHOSTTY_ACTION_QUIT:
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return true

        case GHOSTTY_ACTION_RING_BELL:
            DispatchQueue.main.async {
                NSSound.beep()
                if let view = targetView() {
                    view.window?.dockTile.badgeLabel = "!"
                }
            }
            return true

        // MARK: - 标题

        case GHOSTTY_ACTION_SET_TITLE:
            guard let view = targetView() else { return false }
            guard let title = copiedString(
                action.action.set_title.title,
                length: UInt(strlen(action.action.set_title.title))) else { return false }
            DispatchQueue.main.async { [weak view] in view?.setTitle(title) }
            return true

        case GHOSTTY_ACTION_SET_TAB_TITLE:
            // tab = 工作区，名字归用户所有（双击标签改）；OSC 不允许覆盖。
            return true

        case GHOSTTY_ACTION_PROMPT_TITLE:
            return false

        case GHOSTTY_ACTION_PWD:
            return true

        // MARK: - 安全输入

        case GHOSTTY_ACTION_SECURE_INPUT:
            guard let view = targetView() else { return false }
            let mode = action.action.secure_input
            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                switch mode {
                case GHOSTTY_SECURE_INPUT_ON: view.passwordInput = true
                case GHOSTTY_SECURE_INPUT_OFF: view.passwordInput = false
                case GHOSTTY_SECURE_INPUT_TOGGLE: view.passwordInput = !view.passwordInput
                default: break
                }
            }
            return true

        // MARK: - 桌面通知

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let notification = action.action.desktop_notification
            guard let title = copiedString(notification.title, length: UInt(strlen(notification.title))) else {
                return false
            }
            let body = copiedString(notification.body, length: UInt(strlen(notification.body))) ?? ""
            DispatchQueue.main.async {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                let request = UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: nil)
                UNUserNotificationCenter.current().add(request)
            }
            return true

        // MARK: - 子进程退出

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            return true

        case GHOSTTY_ACTION_COMMAND_FINISHED:
            return true

        // MARK: - 进度

        case GHOSTTY_ACTION_PROGRESS_REPORT:
            return true

        // MARK: - 配置变更

        case GHOSTTY_ACTION_CONFIG_CHANGE:
            // core 在条件主题（系统明暗）解析后发来新 config：app 级替换全局缓存，
            // surface 级驱动 pane header 重新着色。config 指针只在回调内有效，
            // 必须同步读值，不能带进 async。
            let values = Self.readConfigValues(action.action.config_change.config)
            if let (_, pane) = locate() {
                DispatchQueue.main.async { [weak pane] in
                    guard let pane else { return }
                    pane.header.applyTerminalTheme(
                        background: values.backgroundColor,
                        foreground: values.foregroundColor)
                    if let window = pane.window, window.isOpaque {
                        window.backgroundColor = values.backgroundColor
                    }
                }
            } else {
                DispatchQueue.main.async {
                    GhosttyRuntime.shared?.configValues = values
                }
            }
            return true

        case GHOSTTY_ACTION_COLOR_CHANGE:
            // 主题明暗切换 / OSC 改色都会触发；转发给 pane header 让紧贴
            // terminal 的 chrome 跟随重新着色，非透明窗口底色也一并同步。
            guard let (_, pane) = locate() else { return true }
            let change = action.action.color_change
            let color = NSColor(
                srgbRed: CGFloat(change.r) / 255,
                green: CGFloat(change.g) / 255,
                blue: CGFloat(change.b) / 255,
                alpha: 1)
            DispatchQueue.main.async { [weak pane] in
                guard let pane else { return }
                pane.header.noteTerminalColorChange(kind: change.kind, color: color)
                if change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND,
                   let window = pane.window, window.isOpaque {
                    window.backgroundColor = color
                }
            }
            return true

        // MARK: - 选区 / 只读

        case GHOSTTY_ACTION_SELECTION_CHANGED:
            return true

        case GHOSTTY_ACTION_READONLY:
            guard let view = targetView() else { return false }
            let mode = action.action.readonly
            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                switch mode {
                case GHOSTTY_READONLY_ON: view.readonly = true
                case GHOSTTY_READONLY_OFF: view.readonly = false
                default: break
                }
            }
            return true

        // MARK: - Tab 移动

        case GHOSTTY_ACTION_MOVE_TAB:
            guard let (controller, _) = locate() else { return false }
            let amount = Int(action.action.move_tab.amount)
            DispatchQueue.main.async {
                controller.moveActiveTab(by: amount)
            }
            return true

        // MARK: - 链接 hover

        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            guard let view = targetView() else { return false }
            let overLink = action.action.mouse_over_link
            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                if overLink.url != nil {
                    NSCursor.pointingHand.set()
                } else {
                    view.window?.invalidateCursorRects(for: view)
                }
            }
            return true

        // MARK: - 窗口大小重置

        case GHOSTTY_ACTION_RESET_WINDOW_SIZE:
            return true

        // MARK: - 滚动条

        case GHOSTTY_ACTION_SCROLLBAR:
            return true

        // MARK: - 按键序列提示

        case GHOSTTY_ACTION_KEY_SEQUENCE:
            return true

        case GHOSTTY_ACTION_KEY_TABLE:
            return true

        // MARK: - 背景透明度切换

        case GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY:
            return true

        // MARK: - 复制标题到剪贴板

        case GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD:
            guard let view = targetView() else { return false }
            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(view.terminalTitle, forType: .string)
            }
            return true

        // MARK: - 浮动窗口

        case GHOSTTY_ACTION_FLOAT_WINDOW:
            return false

        // MARK: - 渲染器健康

        case GHOSTTY_ACTION_RENDERER_HEALTH:
            return true

        // MARK: - 导出终端 IO

        case GHOSTTY_ACTION_EXPORT_TERMINAL_IO:
            return false

        // 这些是 Ghostty.app 自己的产品壳功能。
        case GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE,
             GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL,
             GHOSTTY_ACTION_CHECK_FOR_UPDATES:
            return false

        case GHOSTTY_ACTION_INSPECTOR,
             GHOSTTY_ACTION_RENDER_INSPECTOR:
            return false

        default:
            return false
        }
    }

    /// action 中的字符串只在回调期间有效，必须在 async 之前拷贝。
    private static func copiedString(_ pointer: UnsafePointer<CChar>?, length: UInt) -> String? {
        guard let pointer else { return nil }
        let bytes = UnsafeRawBufferPointer(start: pointer, count: Int(length))
        return String(decoding: bytes, as: UTF8.self)
    }

    /// 对齐官方的 URL seam：普通/文本 action 交 Launch Services；OSC 8
    /// 是 terminal output 控制的不可信输入，非 web/mail scheme 先确认。
    private static func openURL(_ action: ghostty_action_open_url_s) -> Bool {
        guard let value = copiedString(action.url, length: action.len), !value.isEmpty else {
            return false
        }

        let url: URL
        if let candidate = URL(string: value), candidate.scheme != nil {
            url = candidate
        } else {
            url = URL(fileURLWithPath: NSString(string: value).standardizingPath)
        }

        if action.kind == GHOSTTY_ACTION_OPEN_URL_KIND_OSC8 {
            let trustedSchemes = ["http", "https", "mailto"]
            if !trustedSchemes.contains(url.scheme?.lowercased() ?? "") {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "打开终端链接？"
                    alert.informativeText = value
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "打开")
                    alert.addButton(withTitle: "取消")
                    let completion: (NSApplication.ModalResponse) -> Void = { response in
                        if response == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
                    }
                    if let window = NSApp.keyWindow {
                        alert.beginSheetModal(for: window, completionHandler: completion)
                    } else {
                        completion(alert.runModal())
                    }
                }
                return true
            }
        }

        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        return true
    }

    // MARK: - config 读取

    private static func readConfigValues(_ config: ghostty_config_t) -> GhosttyConfigValues {
        var v = GhosttyConfigValues()

        if let bg = getColor(config, "background") { v.backgroundColor = bg }
        if let fg = getColor(config, "foreground") { v.foregroundColor = fg }

        var opacity: Double = 1
        _ = get(config, &opacity, "background-opacity")
        v.backgroundOpacity = opacity

        var blur: Int16 = 0
        _ = get(config, &blur, "background-blur")
        v.backgroundBlur = blur

        // split-divider-color：未设时按官方公式从 background 推导
        if let divider = getColor(config, "split-divider-color") {
            v.splitDividerColor = divider
        } else {
            let bg = v.backgroundColor
            v.splitDividerColor = bg.isLightColor ? bg.darken(by: 0.08) : bg.darken(by: 0.4)
        }
        return v
    }

    private static func readDiagnostics(_ config: ghostty_config_t) -> [String] {
        (0..<ghostty_config_diagnostics_count(config)).map { index in
            String(cString: ghostty_config_get_diagnostic(config, index).message)
        }
    }

    private static func get<T>(_ config: ghostty_config_t, _ value: inout T, _ key: String) -> Bool {
        withUnsafeMutablePointer(to: &value) { ptr in
            ghostty_config_get(config, ptr, key, UInt(key.utf8.count))
        }
    }

    private static func getColor(_ config: ghostty_config_t, _ key: String) -> NSColor? {
        var c = ghostty_config_color_s()
        guard get(config, &c, key) else { return nil }
        return NSColor(
            srgbRed: CGFloat(c.r) / 255,
            green: CGFloat(c.g) / 255,
            blue: CGFloat(c.b) / 255,
            alpha: 1)
    }

    // MARK: - 剪贴板回调

    static let selectionPasteboard = NSPasteboard(
        name: NSPasteboard.Name("com.mitchellh.ghostty.selection"))

    private static func pasteboard(for location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD: return .general
        case GHOSTTY_CLIPBOARD_SELECTION: return selectionPasteboard
        default: return nil
        }
    }

    /// 对齐 Ghostty `getOpinionatedStringContents`：文件先取绝对路径并做
    /// shell-buffer escape，其他 pasteboard item 取 string，多项用空格连接。
    static func opinionatedString(from pasteboard: NSPasteboard) -> String? {
        let values = (pasteboard.pasteboardItems ?? []).compactMap { item -> String? in
            if let propertyList = item.propertyList(forType: .fileURL),
               let fileURL = NSURL(
                    pasteboardPropertyList: propertyList,
                    ofType: .fileURL) as URL?,
               fileURL.isFileURL {
                return escapeForShellBuffer(fileURL.path)
            }
            return item.string(forType: .string)
        }
        return values.isEmpty ? nil : values.joined(separator: " ")
    }

    private static func escapeForShellBuffer(_ value: String) -> String {
        var result = value
        for character in "\\ ()[]{}<>\"'`!#$&;|*?\t" {
            result = result.replacingOccurrences(
                of: String(character),
                with: "\\\(character)")
        }
        return result
    }

    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let userdata else { return false }
        let view = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        guard let surface = view.surface else { return false }
        guard let pasteboard = pasteboard(for: location),
              let str = opinionatedString(from: pasteboard) else { return false }
        str.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, false) }
        return true
    }

    private static func confirmClipboardRead(
        _ userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let userdata, let string else { return }
        let view = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        let contents = String(cString: string)
        DispatchQueue.main.async { [weak view] in
            guard let view, let surface = view.surface else { return }
            let alert = NSAlert()
            alert.messageText = request == GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ
                ? "允许终端读取剪贴板？"
                : "粘贴剪贴板内容？"
            alert.informativeText = String(contents.prefix(500))
            alert.alertStyle = .warning
            alert.addButton(withTitle: "允许")
            alert.addButton(withTitle: "取消")

            let completion: (NSApplication.ModalResponse) -> Void = { response in
                let approved = response == .alertFirstButtonReturn ? contents : ""
                approved.withCString {
                    ghostty_surface_complete_clipboard_request(surface, $0, state, true)
                }
            }
            if let window = view.window {
                alert.beginSheetModal(for: window, completionHandler: completion)
            } else {
                completion(alert.runModal())
            }
        }
    }

    private static func writeClipboard(
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        count: Int,
        confirm: Bool
    ) {
        guard let content, count > 0, let pasteboard = pasteboard(for: location) else { return }
        var text: String?
        for index in 0..<count {
            let item = content[index]
            guard let mime = item.mime, let data = item.data,
                  String(cString: mime).hasPrefix("text/") else { continue }
            text = String(cString: data)
            break
        }
        guard let text else { return }

        let apply = {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        DispatchQueue.main.async {
            guard confirm else {
                apply()
                return
            }
            let alert = NSAlert()
            alert.messageText = "允许终端写入剪贴板？"
            alert.informativeText = String(text.prefix(500))
            alert.alertStyle = .warning
            alert.addButton(withTitle: "允许")
            alert.addButton(withTitle: "取消")
            let completion: (NSApplication.ModalResponse) -> Void = { response in
                if response == .alertFirstButtonReturn { apply() }
            }
            if let window = NSApp.keyWindow {
                alert.beginSheetModal(for: window, completionHandler: completion)
            } else {
                completion(alert.runModal())
            }
        }
    }
}

extension NSColor {
    var isLightColor: Bool { luminance > 0.5 }

    var luminance: Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard let rgb = usingColorSpace(.sRGB) else { return 0 }
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        // 官方 OSColor+Extension 同式（ITU BT.709）
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    var hexRGB: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#000000" }
        return String(
            format: "#%02x%02x%02x",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded()))
    }

    func darken(by amount: CGFloat) -> NSColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard let hsb = usingColorSpace(.sRGB) else { return self }
        hsb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: s, brightness: min(b * (1 - amount), 1), alpha: a)
    }
}
