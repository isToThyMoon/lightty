import AppKit
import LighttyCore

/// 把 `PaneStatusStore` 的通知分发到各呈现面（pane 头胶囊、展开中的灵动岛、
/// 标签页侧栏行）。
///
/// 为什么是「推」而不是让每个 pane 自己订阅：pane 侧不需要任何订阅代码，
/// `PaneView` 保持与本功能无关（S1 独占该文件），注销时序也不必每个 pane 各管一套。
///
/// **定向分发**：通知的 `object` 带着变化的 pane UUID（传输层换成 datagram socket
/// 之后，一发报文就是一个 pane 的事），只更新那一个 pane。`object` 为 nil 才走全量
/// （`markAllRead` 这类一次改多个 pane 的操作）。
/// 广播式的全量遍历在 50 pane 的目标规模下就是每发报文 50 次无用功。
///
/// **只在主线程使用**：store 是主线程独占的，AppKit 更新也必须在主线程；
/// 通知本身由 store 在主线程 post，天然满足。
final class PaneStatusPresenter {
    static let shared = PaneStatusPresenter()

    private var installed = false
    /// 本 tick 内待更新的 pane。合流的是「同一 pane 连发几次」，不是「丢掉中间态」——
    /// 呈现面只关心最终颜色，读的是 store 里的当前值。
    private var pendingPanes: Set<UUID> = []
    /// 收到过不带 pane 的通知（全量语义），本 tick 走全量分支。
    private var needsFullPass = false
    /// 本批合流里出现过 hook 状态变化（而不是只有会话库/聚焦的变更）。
    ///
    /// 这是个**累加器**，和 `pendingPanes` / `needsFullPass` 同类：一批里可能两族
    /// 通知都有，而 flush 只跑一次，必须记住这一批里到底有没有 hook 事件。
    /// 给通知加载荷消不掉它——只要还合流，就得攒。
    private var sawStatusEvent = false

    /// 侧栏列是随窗口生灭的视图，弱表省掉一套注销时序。
    private let columns = NSHashTable<TabColumnView>.weakObjects()

    private init() {}

    /// 集成步骤（AppDelegate）在启动时调一次即可，幂等。
    func install() {
        guard !installed else { return }
        installed = true
        // 两族通知各自一个入口。原来它们共用一个 selector，靠 `paneID(from:)`
        // 解不出 pane 来区分——而那两条通知的 `object` 是 controller / pane / window，
        // 「解码恰好失败」才走到全量。哪天有谁改了 `object` 的类型，就会静默地
        // 把一次全量退化成一次定向刷新，谁都不会发现。
        NotificationCenter.default.addObserver(
            self, selector: #selector(paneStatusDidChange(_:)),
            name: .lighttyPaneStatusDidChange, object: nil)
        for name: Notification.Name in [.lighttySessionLibraryDidChange, .lighttyTerminalSelectionDidChange] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(contextDidChange), name: name, object: nil)
        }
        needsFullPass = true
        flush()
    }

    /// 侧栏列挂上窗口时自报家门（列被夹在 TabSidebarView 里，
    /// 外面没有稳定路径能遍历到）。
    func register(column: TabColumnView) {
        columns.add(column)
        column.applyStatuses()
    }

    /// pane 自己的状态变了。`object` 带着是哪个 pane（nil 表示一次改了多个，走全量）。
    ///
    /// hook 的一次工具调用会连发 PreToolUse / PostToolUse，多个 pane 并行时更密，
    /// 所以攒起来合流到下一拍再分发。
    @objc private func paneStatusDidChange(_ notification: Notification) {
        sawStatusEvent = true
        if let paneID = PaneStatusStore.paneID(from: notification) {
            pendingPanes.insert(paneID)
        } else {
            needsFullPass = true
        }
        flushes.schedule()
    }

    /// 会话库或聚焦终端变了。它影响的是标题这类派生显示，哪个 pane 都可能变，
    /// 所以只能全量——这两条通知本来也不带 pane。
    @objc private func contextDidChange() {
        needsFullPass = true
        flushes.schedule()
    }

    /// 攒的是「哪几个 pane」（`pendingPanes` / `needsFullPass`），
    /// 合流只管「什么时候分发」——两件事分开。
    private lazy var flushes = Coalescer(.nextTick) { [weak self] in self?.flush() }

    /// 合流：多个 pane 同时收尾只拉一次。延迟一点再拉——标题是 turn 结束之后才写的。
    private lazy var libraryRefreshes = Coalescer(.after(1.5)) {
        AppState.shared?.sessionLibrary.refresh()
    }

    /// 拉一次还赶不上就再拉几次。
    ///
    /// 「一轮结束」和「agent 把标题写进自己目录」之间有延迟，长短取决于那一轮有多少
    /// 内容——固定等 1.5 秒只是赌它够快。实测输过：同一批起的三段会话，两段赶上了、
    /// 第三段没赶上，那一段的标题就永远停在「终端 N」，因为在此之后没有任何东西会
    /// 再拉一次。还有一种更隐蔽的输法：赶上的那一刻 agent 只写了预览、还没写正式
    /// 名字，标题于是停在预览上，看着像成了。
    ///
    /// **必须有上限。** `.done` 是粘滞态，而库自己的变更通知也会走进 `flush`，
    /// 无限重试会变成永远转下去——下面那句只认 `fromHook` 正是为了这个。
    static let titleAttempts = 5
    /// pane → 还能再拉几次。标题落地或次数用完就移除，不留残条。
    private var titleWaits: [UUID: Int] = [:]

    /// 标题没落地就再拉一次，直到次数用完。
    private func updateTitleWait(for pane: PaneView, landed: Bool) {
        let id = pane.dragIdentifier
        let next = Self.nextTitleWait(
            landed: landed, hasSession: pane.displayedSessionKey != nil, attemptsLeft: titleWaits[id])
        titleWaits[id] = next.remaining
        if next.refresh { scheduleLibraryRefresh() }
    }

    /// 「还要不要再拉一次库、还剩几次」。
    ///
    /// 抽成纯函数是为了让**会不会永远转下去**这条性质测得到：整个刷新链路是
    /// 单例 + 通知 + 合流，端到端构不出来，而这条重试恰恰是唯一有可能自激的地方。
    ///
    /// - 标题落地了：清掉记录，不再拉。
    /// - 这个 pane 里根本没有会话：标题本来就该是 pane 名，不是没赶上，不重试。
    /// - 次数用完：清掉记录。**这是终止的保证**，少了它就是永动机。
    static func nextTitleWait(landed: Bool, hasSession: Bool,
                              attemptsLeft: Int?) -> (remaining: Int?, refresh: Bool) {
        guard !landed, hasSession, let left = attemptsLeft, left > 0 else { return (nil, false) }
        return (left - 1, true)
    }
    private func scheduleLibraryRefresh() { libraryRefreshes.schedule() }

    private func flush() {
        let store = PaneStatusStore.shared
        let panes = pendingPanes
        let full = needsFullPass
        let fromHook = sawStatusEvent
        pendingPanes.removeAll()
        needsFullPass = false
        sawStatusEvent = false

        // AppState 在 applicationDidFinishLaunching 里才建；install 早于它也不该崩
        for (_, pane) in AppState.shared?.runningPanes() ?? []
        where full || panes.contains(pane.dragIdentifier) {
            // header 内部会把状态同步给展开中的灵动岛——面板挂在窗口 contentView 上，
            // 从这里够不到，而 header 有「胶囊隐身」这个现成标记能定位它
            let status = store.status(for: pane.dragIdentifier)
            pane.header.apply(status)
            let titleLanded = pane.refreshSessionTitle(
                records: AppState.shared?.sessionLibrary.records ?? [])
            // 一轮结束时 agent 才把总结标题写进自己的目录。会话库只有会话侧栏会去拉，
            // 不在这里补一次，pane 上的标题得等用户主动打开侧栏才更新。
            // 只认 hook 事件（`fromHook`）：`.done` 是粘滞态，若也认库自己的变更通知，
            // 刷新会把自己再触发一遍，永远转下去。
            if fromHook, status?.state == .done {
                titleWaits[pane.dragIdentifier] = Self.titleAttempts
                scheduleLibraryRefresh()
            }
            updateTitleWait(for: pane, landed: titleLanded)
        }

        // 侧栏与 header 同样定向：通知带着变化的 pane，只刷那几行。
        // 全量只在 markAllRead 这类无 pane 的变更时走。
        guard full || !panes.isEmpty else { return }
        for column in columns.allObjects {
            if full {
                column.applyStatuses()
            } else {
                for pane in panes { column.applyStatus(for: pane) }
            }
        }
    }
}
