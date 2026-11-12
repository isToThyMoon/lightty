import Foundation
import Network

/// 等网络可用。开机时 shell 已经起来、网卡还没连上，重启续接的 Agent 会因为请求失败退出；
/// 续接失败后的自动重试经这里等到有网再发。
///
/// 系统报「有网」只说明有路由，DNS 与登录态可能还要一会儿，所以到了之后再缓一下。
/// 一直没网就一直不调，不设超时：没网时重试一定失败，不如不试。
final class NetworkReadiness {
    static let shared = NetworkReadiness()

    static let settleDelay: TimeInterval = 5

    private let monitor = NWPathMonitor()
    private var online = false
    private var waiting: [() -> Void] = []

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.update(online: path.status == .satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "lightty.network-readiness"))
    }

    /// 有网（并缓过 `settleDelay`）后在主线程调一次。
    func whenOnline(_ block: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        waiting.append(block)
        if online { flush() }
    }

    private func update(online: Bool) {
        self.online = online
        if online { flush() }
    }

    private func flush() {
        guard !waiting.isEmpty else { return }
        let blocks = waiting
        waiting = []
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) {
            blocks.forEach { $0() }
        }
    }
}
