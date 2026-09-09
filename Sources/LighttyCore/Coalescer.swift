import Foundation

/// 把一段时间内的多次请求合成一次执行。
///
/// 仓库里原本有 8 份手写的同一件事——布尔闩加 `asyncAfter`，五种延迟散落在各处，
/// 而**最需要它的第一侧栏偏偏没有**：`SessionsSidebarContent` 把 `reload` 直接接在
/// 会话库通知上，而一次 `library.refresh()` 至少发五条（`SessionLibrary.publish()`
/// 在开始时发一条，之后每个 provider 每页完成再发一条）。
///
/// 三种合流方式，对应那 8 处实际用到的语义：
///
/// - `.nextTick`：合并到下一个 runloop tick。
/// - `.after(d)`：合并到 d 秒之后。**新请求不会推迟已排好的那次**——先到先定时。
/// - `.debounce(d)`：每次请求都把上一次取消重排，「安静下来才干活」。
///
/// 三者的区别只在「什么时候干」，都保证**排队期间的多次请求只执行一次**。
///
/// **单线程使用**：状态没有加锁，调用方必须始终在同一个队列上调用（默认是主线程）。
/// 这与它替代的那 8 处手写代码是同一个约定。
public final class Coalescer {
    public enum Mode {
        case nextTick
        case after(TimeInterval)
        case debounce(TimeInterval)
    }

    private let mode: Mode
    private let queue: DispatchQueue
    private let perform: () -> Void
    private var pending: DispatchWorkItem?
    /// `.nextTick` / `.after` 的先到先定时闩。`.debounce` 不用它。
    private var latched = false

    /// 要干的活在这里给定，而不是每次 `schedule()` 传一遍——否则排队期间传了两个
    /// 不同的闭包时，「哪个会执行」就成了调用方必须记住的规则。
    public init(_ mode: Mode, on queue: DispatchQueue = .main, perform: @escaping () -> Void) {
        self.mode = mode
        self.queue = queue
        self.perform = perform
    }

    /// `delay` 只对 `.after` / `.debounce` 有意义，用于那些每次调用延迟不同的调用方。
    public func schedule(delay: TimeInterval? = nil) {
        switch mode {
        case .nextTick, .after:
            guard !latched else { return }
            latched = true
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.latched = false
                self.pending = nil
                self.perform()
            }
            pending = item
            if case .after(let interval) = mode {
                queue.asyncAfter(deadline: .now() + (delay ?? interval), execute: item)
            } else {
                queue.async(execute: item)
            }
        case .debounce(let interval):
            pending?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pending = nil
                self.perform()
            }
            pending = item
            queue.asyncAfter(deadline: .now() + (delay ?? interval), execute: item)
        }
    }

    /// 取消已排队但还没执行的那次。已经在执行的不受影响。
    public func cancel() {
        pending?.cancel()
        pending = nil
        latched = false
    }

    public var isScheduled: Bool { pending != nil }

    deinit { pending?.cancel() }
}
