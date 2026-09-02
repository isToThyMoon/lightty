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
///    前台通知根本不显示。而本功能恰好有「app 在前台但 pane 在别的窗口/工作区」
///    这一档，没有 delegate 那一档就静默失效了。
/// 3. **合并**：多个 agent 同时收工必须并成一条，不能刷屏。
final class PaneNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PaneNotifier()

    private static let categoryID = "lightty.pane.status"
    private static let openActionID = "lightty.pane.open"
    private static let paneIDsKey = "paneIDs"

    /// 合并窗口。取 0.6s：够把「三个 agent 前后脚收工」并成一条，
    /// 又不至于让单个 pane 的完成提醒迟到到用户已经切回来了。
    private static let coalesceWindow: TimeInterval = 0.6

    private enum Authorization { case unknown, granted, denied }
    private var authorization: Authorization = .unknown
    /// 首次授权是异步的，期间来的批次挂在这里等结果，不重复弹框
    private var authWaiters: [(Bool) -> Void] = []
    private var authRequestInFlight = false

    /// pane → 上一次见到的状态。只有**跨越**进 done/attention 才提醒，
    /// 停在 done 上的后续事件不该反复响。
    private var lastStates: [UUID: PaneActivity] = [:]
    private var pending: [UUID] = []
    private var flushScheduled = false
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
            lastStates[id] = PaneStatusStore.shared.status(for: id)?.state ?? .idle
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
            let state = PaneStatusStore.shared.status(for: id)?.state ?? .idle
            // 安装时已经把当时所有 pane 录进基线（见 seedStates），所以此刻
            // 第一次见到的 pane 一定是安装之后新建的，它的初始态只能是 idle——
            // 直接跳成 done 是货真价实的跳变，该提醒。
            let previous = lastStates[id] ?? .idle
            lastStates[id] = state
            guard previous != state else { continue }
            guard state == .done || state == .attention else { continue }
            guard !isOnScreen(pane, in: controller) else { continue }
            enqueue(id)
        }
        // pane 关掉后连同它的待发提醒一起清掉
        lastStates = lastStates.filter { alive.contains($0.key) }
        pending.removeAll { !alive.contains($0) }
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
        // 后台工作区（tab）里的 pane 没有渲染在屏幕上
        return controller.workspaceOverview().contains { entry in
            entry.isActive && entry.panes.contains { $0 === pane }
        }
    }

    // MARK: - 合并与投递

    private func enqueue(_ paneID: UUID) {
        if !pending.contains(paneID) { pending.append(paneID) }
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coalesceWindow) { [weak self] in
            self?.flushScheduled = false
            self?.flush()
        }
    }

    private func flush() {
        let ids = pending
        pending.removeAll()
        guard !ids.isEmpty else { return }
        withAuthorization { [weak self] granted in
            guard granted else { return }
            self?.post(ids)
        }
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

        center.getNotificationSettings { settings in
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

    private func post(_ ids: [UUID]) {
        guard let center = Self.center else { return }
        let running = AppState.shared?.runningPanes() ?? []
        // 合并窗口 + 授权往返期间 pane 可能已被关掉或已读，按当下重新过滤
        let entries: [(name: String, state: PaneActivity)] = ids.compactMap { id in
            guard let match = running.first(where: { $0.pane.dragIdentifier == id }) else { return nil }
            let state = PaneStatusStore.shared.status(for: id)?.state ?? .idle
            guard state == .done || state == .attention else { return nil }
            return (Self.displayName(for: match.pane), state)
        }
        guard !entries.isEmpty else { return }

        let content = UNMutableNotificationContent()
        content.categoryIdentifier = Self.categoryID
        content.sound = .default
        content.userInfo = [Self.paneIDsKey: ids.map(\.uuidString)]
        let needsAttention = entries.contains { $0.state == .attention }
        if entries.count == 1 {
            content.title = needsAttention ? L("Needs your attention") : L("Agent finished")
            content.body = entries[0].name
        } else {
            content.title = needsAttention
                ? L("%d panes need your attention", entries.count)
                : L("%d agents finished", entries.count)
            content.body = entries.map(\.name).joined(separator: ", ")
        }
        center.add(UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private static func displayName(for pane: PaneView) -> String {
        let name = pane.header.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = name.isEmpty ? L("Pane") : name
        guard let task = pane.header.titleOfBoundTask, !task.isEmpty else { return base }
        return "\(base) · \(task)"
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
        let ids = response.notification.request.content.userInfo[Self.paneIDsKey] as? [String] ?? []
        switch response.actionIdentifier {
        case Self.openActionID, UNNotificationDefaultActionIdentifier:
            DispatchQueue.main.async {
                // 合并通知带着一串 pane：跳到第一个还活着的那个
                for id in ids {
                    guard let uuid = UUID(uuidString: id) else { continue }
                    if PaneFocus.reveal(paneID: uuid) { break }
                }
            }
        default:
            break
        }
        completionHandler()
    }
}
