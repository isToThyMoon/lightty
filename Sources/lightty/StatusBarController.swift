import AppKit
import LighttyCore

/// pane 聚焦的唯一入口：菜单栏菜单项与系统通知点击共用一份实现。
///
/// 放在这里而不是各自复制一份，是因为「激活 app → 还原最小化 → 切标签页 →
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
        // 落点提示：从菜单栏/通知跳过来，多分屏下必须告诉视线去哪
        match.pane.flashReveal()
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
        FilePreferences.shared.register(defaults: [Self.enabledDefaultsKey: true])
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
        FilePreferences.shared.bool(forKey: Self.enabledDefaultsKey)
    }

    func setEnabled(_ enabled: Bool) {
        FilePreferences.shared.set(enabled, forKey: Self.enabledDefaultsKey)
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
            let alert = AppBranding.makeAlert()
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
    /// `TabColumnView.scheduleReload()` 的写法压到下一个 runloop tick，
    /// 一串连续事件只重建一次。
    ///
    /// 标志位没加锁：契约规定 `lighttyPaneStatusDidChange` 由 store 在主线程 post。
    private lazy var refreshes = Coalescer(.nextTick) { [weak self] in self?.refresh() }
    @objc private func scheduleRefresh() { refreshes.schedule() }

    private func refresh() {
        updateIcon()
        // 菜单关着时重建纯属浪费——下次打开 `menuNeedsUpdate` 会兜底。
        // 只有菜单正开着（用户盯着看）才需要当场改。
        if menuIsOpen { rebuildMenu() }
    }

    // MARK: - 图标

    /// 全部单色模板（menu bar 规范：第三方彩色图标在一排系统单色项里必然突兀），
    /// 档位靠形状轻重表达：全空闲 = 虚线圈（几乎看不见）；在跑 = 省略号线框；
    /// done/attention = 实心圆 + 镂空勾/问号 + 计数（最重的"快看我"档）。
    /// 状态的颜色语义保留在下拉菜单的行内圆点里——自绘区域用色是正常的。
    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let store = PaneStatusStore.shared
        let aggregate = store.aggregate
        let unread = store.unreadCount

        let names: [String]
        switch aggregate {
        case .idle:
            names = ["circle.dashed", "circle.dotted", "circle"]
        case .thinking, .tool:
            names = ["ellipsis.circle", "circle"]
        case .done:
            names = ["checkmark.circle.fill", "checkmark.circle"]
        case .attention:
            // 问号而非叹号：这个状态是「agent 在问你」（等批准/等回答），
            // 不是警告或出错，叹号的语义不对
            names = ["questionmark.circle.fill", "questionmark.circle"]
        }

        // 标准做法：模板 symbol 原样交给按钮，由系统垂直居中——symbol 图片
        // 内嵌基线与对齐元数据，任何自定义 padding 重绘都会破坏它们（曾因此
        // 陷入图标/计数交替错位的手调循环）。16pt 是用户拍板的视觉尺寸。
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let image = Self.symbol(names, accessibility: L("Pane status"))?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        button.image = image

        // 计数跟着档位换语义：要人 = 卡住数、跑完 = 未读数；
        // 在跑只在 >1 时标数——单个在跑省略号本身已经表达，数字纯属噪声。
        let count: Int
        switch aggregate {
        case .attention: count = store.attentionCount
        case .done: count = unread
        case .thinking, .tool: count = store.activeCount > 1 ? store.activeCount : 0
        case .idle: count = 0
        }
        // 计数走标准图文对齐：给按钮设 font + 普通 title，NSButton 按 symbol
        // 内嵌基线对齐文字基线——这正是 symbol 携带基线元数据的用途，
        // 不要用 attributedTitle 手调 baselineOffset。
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.title = count > 0 ? " \(count)" : ""
        button.toolTip = Self.summaryTooltip(store: store)
        if ProcessInfo.processInfo.environment["LIGHTTY_DEBUG_LAYOUT"] != nil,
            let frame = button.window?.frame {
            NSLog("[DEBUG-sb] item frame %@", NSStringFromRect(frame))
        }
    }

    /// 悬停即知全局：如「2 running · 1 needs you」。全空闲退回静态名。
    private static func summaryTooltip(store: PaneStatusStore) -> String {
        var parts: [String] = []
        if store.activeCount > 0 { parts.append(L("%d running", store.activeCount)) }
        if store.attentionCount > 0 { parts.append(L("%d needs you", store.attentionCount)) }
        if store.unreadCount > 0 { parts.append(L("%d finished", store.unreadCount)) }
        return parts.isEmpty ? L("Pane status") : parts.joined(separator: " · ")
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

    /// 菜单行圆点：与侧栏 pane 行同一视觉语言、同一取色入口（`dotColor`）。
    /// 之前这里用一组大号 SF Symbol，跟侧栏的小圆点撞形不撞色，被读成
    /// 「两套状态标记」；语义现在由行内状态文字承担，圆点只管颜色。
    private static func dot(bound: Bool, state: PaneActivity) -> NSImage {
        let color = ShellStyle.dotColor(bound: bound, activity: state)
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            // 块内取色：动态色随菜单当前明暗外观解析
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - 菜单

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }
    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    /// 菜单按「要不要你处理」分组，不按窗口 / 标签页：等你的、跑完没看的在最上面，
    /// 其次是在跑的，空闲的收进「其他 N 个终端」子菜单。以前按标签页平铺，「标签页 5」
    /// 这类标题几乎不带信息却占了一半行数，要找的那一行只多一个小圆点，得逐行扫。
    private enum MenuGroup { case attention, done, running, other }

    private static func group(of state: PaneActivity?) -> MenuGroup {
        switch state {
        case .attention: return .attention
        case .done: return .done
        case .thinking, .tool: return .running
        case .idle, nil: return .other
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let store = PaneStatusStore.shared
        // 窗口 → 标签页 → pane 的自然顺序；在跑的和空闲的保持这个顺序。
        let panes = (AppState.shared?.windowControllers ?? []).flatMap { $0.tabOverview().flatMap(\.panes) }
        var grouped: [MenuGroup: [(pane: PaneView, status: PaneStatus?)]] = [:]
        for pane in panes {
            let status = store.status(for: pane.dragIdentifier)
            grouped[Self.group(of: status?.state), default: []].append((pane, status))
        }
        // 要你处理的最近变化的在前：刚跑完、刚问你的，最可能是你正要找的。
        for key in [MenuGroup.attention, .done] {
            grouped[key]?.sort { ($0.status?.ts ?? .distantPast) > ($1.status?.ts ?? .distantPast) }
        }

        var listedGroup = false
        for (key, title) in [(MenuGroup.attention, L("Needs you")), (.done, L("Finished")), (.running, L("In progress"))] {
            guard let entries = grouped[key], !entries.isEmpty else { continue }
            // 「待处理」「已完成」是一类，挨着放；和在跑的之间隔一条线。
            if key == .running && listedGroup { menu.addItem(.separator()) }
            addSectionHeader(title)
            for entry in entries { menu.addItem(paneItem(for: entry.pane, status: entry.status)) }
            listedGroup = true
        }
        if let others = grouped[.other], !others.isEmpty {
            if listedGroup {
                menu.addItem(.separator())
                let item = NSMenuItem(title: L("%d other panes", others.count), action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for entry in others { submenu.addItem(paneItem(for: entry.pane, status: entry.status)) }
                item.submenu = submenu
                menu.addItem(item)
            } else {
                // 全都空闲：没有更要紧的，直接列出来，不让人多点一层。
                for entry in others { menu.addItem(paneItem(for: entry.pane, status: entry.status)) }
            }
        }

        if panes.isEmpty {
            let empty = NSMenuItem(title: L("No panes"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        menu.addItem(.separator())

        let markAll = NSMenuItem(
            title: L("Mark All as Read"), action: #selector(markAllRead), keyEquivalent: "")
        markAll.target = self
        markAll.isEnabled = PaneStatusStore.shared.hasUnreadReminders
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
    private func paneItem(for pane: PaneView, status: PaneStatus?) -> NSMenuItem {
        let bound = !(pane.boundTask?.name ?? "").isEmpty
        let item = NSMenuItem(title: "", action: #selector(focusPane(_:)), keyEquivalent: "")
        item.target = self
        // 存 UUID 而不是 PaneView：菜单不该让一个已经关掉的 pane 续命
        item.representedObject = pane.dragIdentifier
        item.image = Self.marker(bound: bound, state: status?.state)
        item.attributedTitle = paneTitle(for: pane, status: status)
        // 完整信息（工具名 + detail）走 tooltip，与 pane 头同一份文案
        item.toolTip = TabPaneStatusPresentation.detailLine(for: status)
        return item
    }

    /// 行首标记。要你处理的两档换成带色的问号 / 勾（与菜单栏图标同一组符号），比小圆点
    /// 大一圈、形状也不同，扫一眼就能和别的行分开；其余仍是与侧栏同色的圆点。
    private static func marker(bound: Bool, state: PaneActivity?) -> NSImage {
        let name: String
        switch state {
        case .attention: name = "questionmark.circle.fill"
        case .done: name = "checkmark.circle.fill"
        default: return dot(bound: bound, state: state ?? .idle)
        }
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(.init(paletteColors: [ShellStyle.statusColor(for: state ?? .idle)]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return dot(bound: bound, state: state ?? .idle) }
        image.isTemplate = false
        return image
    }

    /// 分组标题已经说了状态，行里不再重复状态词。要你处理的行标题加粗，行尾写多久之前
    /// ——同时有几条时，靠它分辨哪条是刚才那个。
    private func paneTitle(for pane: PaneView, status: PaneStatus?) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let urgent = status?.state == .attention || status?.state == .done
        let name = pane.header.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = NSMutableAttributedString(
            string: name.isEmpty ? L("Pane") : name,
            attributes: [.font: urgent ? NSFont.boldSystemFont(ofSize: font.pointSize) : font])
        if urgent, let status {
            title.append(NSAttributedString(
                string: "  \(Self.elapsed(since: status.ts))",
                attributes: [
                    .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: ShellStyle.statusColor(for: status.state),
                ]))
        }
        if let task = pane.boundTask?.name, !task.isEmpty {
            title.append(NSAttributedString(
                string: "  \(task)",
                attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return title
    }

    /// 与会话列表同一种写法（界面语种、短格式）；一分钟内说「刚刚」。
    private static func elapsed(since date: Date) -> String {
        guard Date().timeIntervalSince(date) >= 60 else { return L("just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = LanguagePreference.current().locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
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
