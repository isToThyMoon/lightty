import AppKit
import LighttyCore

/// pane 聚焦的唯一入口：菜单栏菜单项与系统通知点击共用一份实现。
///
/// 放在这里而不是各自复制一份，是因为「激活 app → 还原最小化 → 切工作区 →
/// 交还终端焦点 → 标记已读」这串顺序有讲究（后台 tab 的 pane 成不了
/// first responder，必须先 `selectTab` 再 `focusTerminal`），两处走岔会出
/// 难查的焦点 bug。
enum PaneFocus {
    @discardableResult
    static func reveal(paneID: UUID) -> Bool {
        guard let match = AppState.shared?.runningPanes()
            .first(where: { $0.pane.dragIdentifier == paneID })
        else { return false }
        NSApp.activate(ignoringOtherApps: true)
        if let window = match.controller.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        match.controller.reveal(pane: match.pane)
        // 用户已经亲眼看到这个 pane 了，done 的粘滞在此终结
        PaneStatusStore.shared.markRead(paneID)
        return true
    }
}

/// 菜单栏状态项：跨窗口俯瞰所有 pane 的 agent 状态，并提供跳转入口。
///
/// 生命周期取舍：`applicationShouldTerminateAfterLastWindowClosed` 目前是
/// `true`，关掉最后一个窗口 app 就退出——这与「菜单栏常驻」是冲突的语义。
/// 本期**不做常驻**：状态项只在 app 活着（即有窗口）时存在，退出即消失。
/// 真要常驻得先改终止策略，那是独立决策，不在本 stream 范围内。
final class StatusBarController: NSObject, NSMenuDelegate {
    static let shared = StatusBarController()

    /// 全库第一个 UserDefaults 键。命名空间前缀是为了将来加别的偏好时
    /// 不至于和 AppKit / Sparkle 写进同一个域的键撞名。
    static let enabledDefaultsKey = "lightty.statusBar.enabled"

    private var statusItem: NSStatusItem?
    private let menu = NSMenu()

    /// 见 `scheduleRefresh()`：合并同一 runloop tick 内的多次状态变更
    private var refreshScheduled = false
    /// 菜单打开期间才需要即时重建；关着的时候交给 `menuNeedsUpdate`
    private var menuIsOpen = false
    private var installed = false

    private override init() { super.init() }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - 安装

    /// 集成方在 `applicationDidFinishLaunching` 里调一次即可。
    func install() {
        guard !installed else { return }
        installed = true
        UserDefaults.standard.register(defaults: [Self.enabledDefaultsKey: true])
        menu.delegate = self
        // 分节标题要保持灰掉，不能被 AppKit 的自动 enable 逻辑点亮
        menu.autoenablesItems = false
        NotificationCenter.default.addObserver(
            self, selector: #selector(scheduleRefresh),
            name: .lighttyPaneStatusDidChange, object: nil)
        applyEnabledState()
    }

    // MARK: - 开关

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey)
        applyEnabledState()
    }

    /// 供集成方挂到 app 菜单上——状态项自己的菜单只能把自己**关掉**，
    /// 关掉之后就没有入口再打开了，必须在别处留一个开关。
    @objc func toggleEnabled(_ sender: Any?) {
        let turningOff = isEnabled
        setEnabled(!turningOff)
        guard turningOff else { return }
        // 关掉后菜单栏上什么都不剩，不说明一句用户会以为 app 坏了
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = L("Menu bar status hidden")
            alert.informativeText = L("You can show it again from the lightty menu.")
            alert.addButton(withTitle: L("OK"))
            alert.runModal()
        }
    }

    private func applyEnabledState() {
        if isEnabled {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.imagePosition = .imageLeading
            item.menu = menu
            statusItem = item
            updateIcon()
        } else {
            guard let item = statusItem else { return }
            statusItem = nil
            NSStatusBar.system.removeStatusItem(item)
        }
    }

    // MARK: - 刷新

    /// `PreToolUse` 每次工具调用都触发一次状态变更，高频。这里照
    /// `WorkspaceColumnView.scheduleReload()` 的写法压到下一个 runloop tick，
    /// 一串连续事件只重建一次。
    ///
    /// 标志位没加锁：契约规定 `lighttyPaneStatusDidChange` 由 store 在主线程 post。
    @objc private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    private func refresh() {
        updateIcon()
        // 菜单关着时重建纯属浪费——下次打开 `menuNeedsUpdate` 会兜底。
        // 只有菜单正开着（用户盯着看）才需要当场改。
        if menuIsOpen { rebuildMenu() }
    }

    // MARK: - 图标

    /// 三档观感，按「值不值得打断用户」递增：
    /// 全空闲 = 空心虚线圈（几乎看不见）；有 agent 在跑 = 省略号（有动静）；
    /// 有 done/attention = 实心彩色符号 + 未读数（这是"快看我"档）。
    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let store = PaneStatusStore.shared
        let aggregate = store.aggregate
        let unread = store.unreadCount

        let names: [String]
        let tint: NSColor?
        switch aggregate {
        case .idle:
            names = ["circle.dashed", "circle.dotted", "circle"]
            tint = nil
        case .thinking, .tool:
            names = ["ellipsis.circle", "circle"]
            tint = nil
        case .done:
            names = ["checkmark.circle.fill", "checkmark.circle"]
            // 走 ShellStyle 而不是 .systemGreen：绿色已经是「已绑定任务」的常驻色，
            // 用绿色表示「跑完了」会被读成「没变化」。同一状态在菜单栏与 pane 头
            // 必须同色，否则用户得学两套配色。
            tint = ShellStyle.statusColor(for: .done)
        case .attention:
            names = ["exclamationmark.circle.fill", "exclamationmark.circle"]
            tint = ShellStyle.statusColor(for: .attention)
        }

        let weight: NSFont.Weight = tint == nil ? .regular : .semibold
        var config = NSImage.SymbolConfiguration(pointSize: 14, weight: weight)
        if let tint {
            config = config.applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        }
        let image = Self.symbol(names, accessibility: L("Pane status"))?
            .withSymbolConfiguration(config)
        // 未上色的档次走 template，跟随菜单栏明暗/强调反色；
        // 上了色的档次必须关掉 template，否则调色板会被系统抹平成单色。
        image?.isTemplate = (tint == nil)
        button.image = image
        button.title = unread > 0 ? " \(unread)" : ""
        button.toolTip = L("Pane status")
    }

    /// SF Symbol 名字随系统版本增删（最低支持 macOS 13）。逐个试，
    /// 第一个能解析的就用——少一个符号只是观感退化，不该让状态项整个消失。
    private static func symbol(_ names: [String], accessibility: String) -> NSImage? {
        for name in names {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: accessibility) {
                return image
            }
        }
        return nil
    }

    private static func glyph(for state: PaneActivity) -> NSImage? {
        let names: [String]
        let color: NSColor
        switch state {
        // 形状承担主要区分（色觉障碍下仍可辨），颜色与 pane 头共用同一套 token
        case .idle:
            names = ["circle", "circle.fill"]
            color = ShellStyle.statusColor(for: .idle)
        case .thinking:
            names = ["ellipsis.circle", "circle.fill"]
            color = ShellStyle.statusColor(for: .thinking)
        case .tool:
            names = ["gearshape.fill", "circle.fill"]
            color = ShellStyle.statusColor(for: .tool)
        case .attention:
            names = ["exclamationmark.circle.fill", "circle.fill"]
            color = ShellStyle.statusColor(for: .attention)
        case .done:
            names = ["checkmark.circle.fill", "circle.fill"]
            color = ShellStyle.statusColor(for: .done)
        }
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = symbol(names, accessibility: "")?.withSymbolConfiguration(config)
        image?.isTemplate = false
        return image
    }

    // MARK: - 菜单

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }
    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    private func rebuildMenu() {
        menu.removeAllItems()

        let controllers = AppState.shared?.windowControllers ?? []
        let multiWindow = controllers.count > 1
        var listed = 0

        for (windowIndex, controller) in controllers.enumerated() {
            let overview = controller.workspaceOverview().filter { !$0.panes.isEmpty }
            guard !overview.isEmpty else { continue }
            if multiWindow { addSectionHeader(L("Window %d", windowIndex + 1)) }
            // 菜单栏空间更紧：单工作区时仍直接平铺；侧栏则始终保留可折叠容器行。
            let showWorkspaces = overview.count > 1
            for entry in overview {
                if showWorkspaces { addSectionHeader(entry.title) }
                let indent = (multiWindow ? 1 : 0) + (showWorkspaces ? 1 : 0)
                for pane in entry.panes {
                    menu.addItem(paneItem(for: pane, indent: indent))
                    listed += 1
                }
            }
        }

        if listed == 0 {
            let empty = NSMenuItem(title: L("No panes"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        menu.addItem(.separator())

        let markAll = NSMenuItem(
            title: L("Mark All as Read"), action: #selector(markAllRead), keyEquivalent: "")
        markAll.target = self
        markAll.isEnabled = PaneStatusStore.shared.unreadCount > 0
        menu.addItem(markAll)

        let toggle = NSMenuItem(
            title: L("Show in Menu Bar"), action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.state = .on
        menu.addItem(toggle)
    }

    /// macOS 13 没有 `NSMenuItem.sectionHeader(title:)`，用禁用项 + 小字模拟。
    private func addSectionHeader(_ title: String) {
        let item = NSMenuItem()
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        item.isEnabled = false
        menu.addItem(item)
    }

    /// 沿用 `AppDelegate.makeItem` 的约定：**一律 `keyEquivalent: ""`**。
    /// 壳层菜单只是鼠标 adapter，按键必须直达 surface 交给 libghostty 的
    /// keybind 处理，菜单抢一个就少一个终端快捷键。
    private func paneItem(for pane: PaneView, indent: Int) -> NSMenuItem {
        let state = PaneStatusStore.shared.status(for: pane.dragIdentifier)?.state ?? .idle
        let item = NSMenuItem(title: "", action: #selector(focusPane(_:)), keyEquivalent: "")
        item.target = self
        // 存 UUID 而不是 PaneView：菜单不该让一个已经关掉的 pane 续命
        item.representedObject = pane.dragIdentifier
        item.image = Self.glyph(for: state)
        item.indentationLevel = indent
        item.attributedTitle = paneTitle(for: pane)
        return item
    }

    private func paneTitle(for pane: PaneView) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let name = pane.header.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = NSMutableAttributedString(
            string: name.isEmpty ? L("Pane") : name, attributes: [.font: font])
        if let task = pane.header.titleOfBoundTask, !task.isEmpty {
            title.append(NSAttributedString(
                string: "  \(task)",
                attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return title
    }

    // MARK: - actions

    @objc private func focusPane(_ sender: NSMenuItem) {
        guard let paneID = sender.representedObject as? UUID else { return }
        PaneFocus.reveal(paneID: paneID)
    }

    @objc private func markAllRead() {
        PaneStatusStore.shared.markAllRead()
    }
}
