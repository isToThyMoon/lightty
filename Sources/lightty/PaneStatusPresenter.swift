import AppKit
import LighttyCore

/// 把 `PaneStatusStore` 的通知分发到各呈现面（pane 头胶囊、展开中的灵动岛、
/// 工作区侧栏行）。
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
    private var flushScheduled = false
    /// 本 tick 内待更新的 pane。合流的是「同一 pane 连发几次」，不是「丢掉中间态」——
    /// 呈现面只关心最终颜色，读的是 store 里的当前值。
    private var pendingPanes: Set<UUID> = []
    /// 收到过不带 pane 的通知（全量语义），本 tick 走全量分支。
    private var needsFullPass = false
    /// 侧栏列是随窗口生灭的视图，弱表省掉一套注销时序。
    private let columns = NSHashTable<WorkspaceColumnView>.weakObjects()

    private init() {}

    /// 集成步骤（AppDelegate）在启动时调一次即可，幂等。
    func install() {
        guard !installed else { return }
        installed = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(statusDidChange(_:)),
            name: .lighttyPaneStatusDidChange, object: nil)
        needsFullPass = true
        flush()
    }

    /// 侧栏列挂上窗口时自报家门（列被夹在 WorkspaceSidebarView 里，
    /// 外面没有稳定路径能遍历到）。
    func register(column: WorkspaceColumnView) {
        columns.add(column)
        column.applyStatuses()
    }

    /// 合流到下一个 runloop tick——与 `WorkspaceColumnView.scheduleReload()` 同一个写法。
    /// hook 的一次工具调用会连发 PreToolUse / PostToolUse，多个 pane 并行时更密；
    /// 不合流就是一帧内重复走完整套分发。
    @objc private func statusDidChange(_ notification: Notification) {
        if let paneID = PaneStatusStore.paneID(from: notification) {
            pendingPanes.insert(paneID)
        } else {
            needsFullPass = true
        }
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.flushScheduled = false
            self?.flush()
        }
    }

    private func flush() {
        let store = PaneStatusStore.shared
        let panes = pendingPanes
        let full = needsFullPass
        pendingPanes.removeAll()
        needsFullPass = false

        // AppState 在 applicationDidFinishLaunching 里才建；install 早于它也不该崩
        for (_, pane) in AppState.shared?.runningPanes() ?? []
        where full || panes.contains(pane.dragIdentifier) {
            // header 内部会把状态同步给展开中的灵动岛——面板挂在窗口 contentView 上，
            // 从这里够不到，而 header 有「胶囊隐身」这个现成标记能定位它
            pane.header.apply(store.status(for: pane.dragIdentifier))
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
