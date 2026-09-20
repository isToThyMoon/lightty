import AppKit
import LighttyCore
import UserNotifications

/// pane 跑完 / 需要介入时的系统通知。
///
/// 三条设计约束，每条都对应一个真实的坑：
/// 1. **权限懒申请**：全库从未调过 `requestAuthorization`。首次启动就弹系统
///    授权框是伏击用户——他还没见过这个功能凭什么授权。改成第一次真的要发
///    通知的那一刻才申请。
/// 2. **必须装 delegate**：不装 `UNUserNotificationCenterDelegate` 时，app 在
///    前台通知根本不显示。而本功能恰好有「app 在前台但 pane 在别的窗口/标签页」
///    这一档，没有 delegate 那一档就静默失效了。
/// 3. **一个 pane 恒定一条**：request id 由 pane 算出来，同一个 pane 再次收工是
///    替换通知中心里那条旧的，不是再堆一条；读掉或 pane 关掉就撤回。多个 agent
///    同时收工各发各的——macOS 自己会按 app 折叠成一组，刷屏由系统兜住。
final class PaneNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PaneNotifier()

    private static let categoryID = "lightty.pane.status"
    private static let openActionID = "lightty.pane.open"
    private static let paneIDKey = "paneID"

    /// 一个 pane 一个固定 request id：替换与撤回都认它。
    private static func requestID(for paneID: UUID) -> String {
        "lightty.pane.\(paneID.uuidString)"
    }

    /// 投递前的缓冲窗口。取 0.6s：一发状态里连着几个 pane 跳变时统一投递；
    /// 也给「刚收工用户就切了过去」留出反悔余地——投递前会重新核一次是否已在眼前。
    private static let coalesceWindow: TimeInterval = 0.6

    private enum Authorization { case unknown, granted, denied }
    private struct DesktopMessage {
        let title: String
        let body: String
    }
    private var authorization: Authorization = .unknown
    /// 首次授权是异步的，期间来的批次挂在这里等结果，不重复弹框
    private var authWaiters: [(Bool) -> Void] = []
    private var authRequestInFlight = false

    /// pane → 上一次见到的未读提醒。只有跨越进未读 done/attention 才提醒；
    /// 读过的 attention 仍是等待状态，但不再排队发通知。
    private var lastStates: [UUID: PaneActivity] = [:]
    private var pending: [UUID] = []
    /// 只有本轮新跨入 done/attention 才记在这里，避免把后来的普通 OSC 通知
    /// 与一个早已存在的未读状态误配。
    private var pendingReminders: [UUID: PaneActivity] = [:]
    /// OSC 通知仍逐条保留；配对成功时只消费最后一条，其余照常投递。
    private var pendingDesktopMessages: [UUID: [DesktopMessage]] = [:]
    private var installed = false

    private override init() { super.init() }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// `swift build` 出来的裸可执行没有 bundle identifier，
    /// `UNUserNotificationCenter.current()` 在那种形态下会直接崩。
    /// 开发形态静默降级成「不发通知」，菜单栏那半边照常工作。
    /// 模块内公开：ghostty 的 desktop_notification（OSC 9/777）也走这一个守卫，
    /// 不然裸可执行下 shell 里随便一个 `printf '\e]9;hi\a'` 就能把 app 打崩。
    static var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    // MARK: - 安装

    /// 集成方在 `applicationDidFinishLaunching` 里调一次即可。
    /// **这里不申请权限**，只装 delegate 和 category（两者都不会弹框）。
    func install() {
        guard !installed else { return }
        installed = true
        if let center = Self.center {
            center.delegate = self
            let open = UNNotificationAction(
                identifier: Self.openActionID, title: L("Open"), options: [.foreground])
            center.setNotificationCategories([
                UNNotificationCategory(
                    identifier: Self.categoryID, actions: [open],
                    intentIdentifiers: [], options: [])
            ])
        }
        // 安装瞬间已经是 done 的 pane 不该补发提醒：先把现状录进基线
        seedStates()
        NotificationCenter.default.addObserver(
            self, selector: #selector(paneStatusDidChange),
            name: .lighttyPaneStatusDidChange, object: nil)
    }

    private func seedStates() {
        for (_, pane) in AppState.shared?.runningPanes() ?? [] {
            let id = pane.dragIdentifier
            lastStates[id] = PaneStatusStore.shared.unreadActivity(for: id) ?? .idle
        }
    }

    // MARK: - 状态扫描

    /// 这里**不**做 debounce：跳变检测靠的是与上一次快照比对，
    /// 压到下一个 tick 会把「tool → done → 用户点开变 idle」这类中间态漏掉。
    /// 扫描本身是 O(pane 数)（个位数），廉价；要压的是"发出去"那一步。
    @objc private func paneStatusDidChange() {
        let running = AppState.shared?.runningPanes() ?? []
        var alive = Set<UUID>()
        for (controller, pane) in running {
            let id = pane.dragIdentifier
            alive.insert(id)
            let state = PaneStatusStore.shared.unreadActivity(for: id) ?? .idle
            // 安装时已经把当时所有 pane 录进基线（见 seedStates），所以此刻
            // 第一次见到的 pane 一定是安装之后新建的，它的初始态只能是 idle——
            // 直接跳成 done 是货真价实的跳变，该提醒。
            let previous = lastStates[id] ?? .idle
            lastStates[id] = state
            guard previous != state else { continue }
            if state == .done || state == .attention {
                guard !isOnScreen(pane, in: controller) else { continue }
                pendingReminders[id] = state
                enqueue(id)
            } else if previous == .done || previous == .attention {
                // 跌出未读：用户点进去读了，或者 agent 又开工把提醒顶掉了。
                // 通知中心里那条已经没有意义——收回去。
                withdrawReminder(id)
            }
        }
        // pane 关掉后连同它的待发提醒和已投递的通知一起清掉
        for id in lastStates.keys where !alive.contains(id) { withdraw(id) }
        lastStates = lastStates.filter { alive.contains($0.key) }
    }

    /// 「用户此刻正看着这个 pane 吗」。看得着就不打扰——通知的价值全在
    /// 用户注意力不在这儿的时候。
    ///
    /// 判定收紧到 key window：一个在后台窗口里的 pane 哪怕像素上露着，
    /// 用户的注意力也不在它身上（spec 把"不同窗口"明确算作不可见）。
    private func isOnScreen(_ pane: PaneView, in controller: TerminalWindowController) -> Bool {
        guard NSApp.isActive else { return false }
        guard let window = controller.window,
              window.isKeyWindow,
              !window.isMiniaturized,
              window.occlusionState.contains(.visible)
        else { return false }
        // 后台标签页（tab）里的 pane 没有渲染在屏幕上
        return controller.tabOverview().contains { entry in
            entry.isActive && entry.panes.contains { $0 === pane }
        }
    }

    // MARK: - 投递与撤回

    private lazy var flushes = Coalescer(.after(Self.coalesceWindow)) { [weak self] in self?.flush() }

    private func enqueue(_ paneID: UUID) {
        // 攒的是「哪几个 pane」，合流只管「什么时候投递」——两件事分开。
        if !pending.contains(paneID) { pending.append(paneID) }
        flushes.schedule()
    }

    /// OSC 9/777 与同一 pane 的新完成状态共用短暂缓冲窗口。窗口内两路都到达时
    /// 组装成一条；没有配对时按 Ghostty 原来的标题和正文独立投递。
    func enqueueDesktopNotification(title: String, body: String, from view: TerminalSurfaceView?) {
        let message = DesktopMessage(title: title, body: body)
        guard let view,
              let pane = AppState.shared?.runningPanes().first(where: { $0.pane.terminal === view })?.pane
        else {
            Self.postDesktop(message)
            return
        }
        let id = pane.dragIdentifier
        pendingDesktopMessages[id, default: []].append(message)
        enqueue(id)
    }

    private func withdrawReminder(_ paneID: UUID) {
        pendingReminders.removeValue(forKey: paneID)
        if pendingDesktopMessages[paneID]?.isEmpty != false {
            pending.removeAll { $0 == paneID }
        }
        Self.center?.removeDeliveredNotifications(withIdentifiers: [Self.requestID(for: paneID)])
    }

    /// 这条提醒作废了：还没投的从队列里摘掉，投出去的从通知中心收回。
    /// 不需要授权——没授权过就没有东西可收，调用是空转。
    private func withdraw(_ paneID: UUID) {
        pending.removeAll { $0 == paneID }
        pendingReminders.removeValue(forKey: paneID)
        pendingDesktopMessages.removeValue(forKey: paneID)
        Self.center?.removeDeliveredNotifications(withIdentifiers: [Self.requestID(for: paneID)])
    }

    private func flush() {
        let ids = pending
        pending.removeAll()
        guard !ids.isEmpty else { return }
        let desktopOnly = ids.filter { pendingReminders[$0] == nil }
        desktopOnly.forEach(post)

        let reminders = ids.filter { pendingReminders[$0] != nil }
        guard !reminders.isEmpty else { return }
        withAuthorization { [weak self] granted in
            guard let self else { return }
            if granted {
                reminders.forEach(self.post)
            } else {
                // 系统权限是 app 级的；即使被拒绝也消费本批，避免缓存滞留。
                reminders.forEach(self.discard)
            }
        }
    }

    private func discard(_ paneID: UUID) {
        pendingReminders.removeValue(forKey: paneID)
        pendingDesktopMessages.removeValue(forKey: paneID)
    }

    /// 懒申请 + 降级：拒绝过一次就把结论记下来，之后所有批次静默丢弃。
    /// （系统本身也不会因为再调一次就重新弹框，这里只是省掉无谓的往返。）
    private func withAuthorization(_ body: @escaping (Bool) -> Void) {
        switch authorization {
        case .granted: body(true); return
        case .denied: body(false); return
        case .unknown: break
        }
        guard let center = Self.center else {
            authorization = .denied
            body(false)
            return
        }
        authWaiters.append(body)
        guard !authRequestInFlight else { return }
        authRequestInFlight = true

        center.getNotificationSettings { [weak self] settings in
            guard self != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch settings.authorizationStatus {
                case .notDetermined:
                    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                        DispatchQueue.main.async { self.settleAuthorization(granted) }
                    }
                case .denied:
                    self.settleAuthorization(false)
                default:
                    self.settleAuthorization(true)
                }
            }
        }
    }

    private func settleAuthorization(_ granted: Bool) {
        authorization = granted ? .granted : .denied
        authRequestInFlight = false
        let waiters = authWaiters
        authWaiters.removeAll()
        waiters.forEach { $0(granted) }
    }

    /// 缓冲窗口 + 授权往返期间，pane 可能已被关掉、已读，或者用户已经切了过去，
    /// 三件事都在这里按当下重新核一次。
    private func post(_ paneID: UUID) {
        let reminder = pendingReminders.removeValue(forKey: paneID)
        let desktops = pendingDesktopMessages.removeValue(forKey: paneID) ?? []
        guard let reminder else {
            desktops.forEach(Self.postDesktop)
            return
        }

        let running = AppState.shared?.runningPanes() ?? []
        guard let match = running.first(where: { $0.pane.dragIdentifier == paneID }),
              PaneStatusStore.shared.unreadActivity(for: paneID) == reminder,
              !isOnScreen(match.pane, in: match.controller)
        else {
            desktops.forEach(Self.postDesktop)
            return
        }

        let pairedDesktop = desktops.last
        desktops.dropLast().forEach(Self.postDesktop)
        guard let center = Self.center else { return }

        let content = UNMutableNotificationContent()
        content.categoryIdentifier = Self.categoryID
        content.sound = .default
        content.userInfo = [Self.paneIDKey: paneID.uuidString]
        let statusTitle = reminder == .attention ? L("Needs your attention") : L("Agent finished")
        if let pairedDesktop {
            content.title = "\(statusTitle) · \(Self.displayName(for: match.pane))"
            content.body = pairedDesktop.body.isEmpty ? pairedDesktop.title : pairedDesktop.body
        } else {
            content.title = statusTitle
            content.body = Self.displayName(for: match.pane)
        }

        let id = Self.requestID(for: paneID)
        // 同 id 覆盖只对**待发**的那条有文档保证，已投递的没明说。
        // 先撤再发，替换语义就是确定的（两个调用按序进同一个队列）。
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// 未与状态提醒配对的 OSC 通知保持原行为：随机 request id、不使用 lightty
    /// category，因此前台展示策略仍由系统决定，也不会被 pane 的已读状态撤回。
    private static func postDesktop(_ message: DesktopMessage) {
        guard let center = center else { return }
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        content.sound = .default
        center.add(UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil))
    }

    private static func displayName(for pane: PaneView) -> String {
        if let task = pane.boundTask?.name, !task.isEmpty { return task }
        let name = pane.header.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? L("Pane") : name
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // 只强制展示本模块的通知。`GhosttyRuntime` 的响铃通知在装 delegate 之前
        // 就是前台不显示的——那是它的既有行为，不该被这里顺手改掉。
        guard notification.request.content.categoryIdentifier == Self.categoryID else {
            completionHandler([])
            return
        }
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let raw = response.notification.request.content.userInfo[Self.paneIDKey] as? String
        switch response.actionIdentifier {
        case Self.openActionID, UNNotificationDefaultActionIdentifier:
            // 跳过去会让它拿到焦点 → markRead → 扫描里撤回，不需要在这里收。
            guard let uuid = raw.flatMap(UUID.init(uuidString:)) else { break }
            DispatchQueue.main.async { _ = PaneFocus.reveal(paneID: uuid) }
        default:
            break
        }
        completionHandler()
    }
}
