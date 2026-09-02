import Foundation
import LighttyCore

extension Notification.Name {
    /// pane 活动状态变化（收到一发 hook 报文，或本地标记已读）。
    ///
    /// 刻意**不复用** `lighttyTasksDidChange`：后者会让侧栏把每一行拆掉重建，
    /// 而状态更新是高频的（一次工具调用就有 PreToolUse + PostToolUse 两发），
    /// 走那条路必然闪。观察者收到本通知后做行内原地更新。
    ///
    /// **`object` 是变化的 pane UUID（`NSUUID`），可能为 nil。**
    /// 与 `lighttyTasksDidChange` 的「不带 payload」不同：状态是**定向**的，
    /// 一发报文只影响一个 pane，广播式的「谁变了自己查」会让 N 个 pane 的场景
    /// 退化成每发报文 N 次全量遍历。`nil` 表示「多个/全部 pane 变了」
    /// （`markAllRead`），观察者应走全量分支。
    /// 用 `PaneStatusStore.paneID(from:)` 取值，别自己 cast。
    ///
    /// 注意：以 `object: nil` 注册的观察者会收到**所有** post，无论 object 是什么
    /// （NotificationCenter 的 object 是过滤器，不是匹配条件）——现有观察者不受影响。
    static let lighttyPaneStatusDidChange = Notification.Name("lighttyPaneStatusDidChange")
}

/// pane 活动状态的唯一读方：绑一个 Unix domain datagram socket，
/// 把 hook 发来的报文变成主线程上的一次通知。
///
/// **为什么是 socket 而不是文件**（取代了早先的 `~/.lightty/panes/<uuid>/status.json`）：
/// 状态是用完即弃的，没有持久化需求；而「一个文件当可变槽位」意味着写方每发一次
/// 就覆盖上一次，主线程忙的时候中间态整批消失——实测 83% 主线程负载下 200 发只到
/// 47 发。datagram socket 的内核接收队列本身就是一个队列，同样负载下 200/200。
/// 顺带没了：watcher、防抖、seq 去重、原子写、以及三者之间的时序坑。
///
/// 数据流仍是单向的（见 docs/specs/pane-status.md §3）：hook 只发，本 store 只收。
/// `markRead` 只改内存不回发——「用户看没看」是 lightty 侧的知识，hook 无从知晓（§4.3）。
///
/// **线程约定：本类型只在主线程使用**（含只读属性）。
/// 收包在私有队列上，入口处统一 `DispatchQueue.main.async` 汇流回主线程，
/// 而不是给 store 加锁：消费者全是 AppKit 视图，加锁也仍要为了刷 UI 回主线程，
/// 等于白付一次锁开销，还多出一类「读到的值在回到主线程前就过期了」的时序 bug。
final class PaneStatusStore {
    static let shared = PaneStatusStore()

    /// 本实例绑定的 socket 路径。默认 `~/.lightty/run/<自己的 pid>.sock`——
    /// **多实例天然不冲突**：路径里带 pid，各绑各的，没有 EADDRINUSE 探测、
    /// 也不会有第二个实例 unlink 掉第一个而把它的 pane 全部孤儿化。
    /// 每个 pane 的 shell 在 spawn 时就从 `LIGHTTY_SOCK` 拿到自己实例的路径。
    let socketPath: URL

    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    /// 收包队列。专用串行队列而不是全局并发队列：报文的到达顺序就是状态的
    /// 先后顺序（datagram 无 framing、内核队列 FIFO），解码与转发必须保持这个顺序。
    private let receiveQueue = DispatchQueue(label: "com.lightty.pane-status.receive")

    /// 挂着的 pane（值仅作存在性标记）。detach 之后在途的报文要能被认出来丢掉。
    private var attached: Set<UUID> = []
    private var statuses: [UUID: PaneStatus] = [:]
    /// 坏报文只记一次日志：畸形报文往往是成批的（版本不匹配的旧 hook），刷屏没有意义。
    private var loggedMalformed = false

    /// `socketPath` 是测试接缝：用例必须绑到临时路径，绝不能碰真实的 `~/.lightty/run`。
    init(socketPath: URL = PaneRuntimeDirectory.socketPath()) {
        self.socketPath = socketPath
    }

    // MARK: - 传输层生命周期

    /// 绑 socket 并开始收包。启动时（AppDelegate）调一次，幂等。
    /// 返回是否处于可收状态——失败只是这个实例没有状态显示，不该连累启动。
    @discardableResult
    func start() -> Bool {
        assertMain()
        guard fd < 0 else { return true }

        // 上一个实例崩溃后留下的 socket 文件会让 sendto 收到 ECONNREFUSED；
        // 功能上无害（发方忽略一切错误），但没人收拾就越积越多
        PaneRuntimeDirectory.sweepStaleSockets()

        do {
            try FileManager.default.createDirectory(
                at: PaneRuntimeDirectory.runDirectory, withIntermediateDirectories: true)
            fd = try Self.bind(to: socketPath)
        } catch {
            NSLog("pane status socket bind failed (\(socketPath.path)): \(error)")
            fd = -1
            return false
        }

        // 选 DispatchSource 而不是「后台队列里死循环 recvfrom」：
        // 阻塞式循环的线程在 stop() 时无法干净地叫醒——close(fd) 时它正卡在
        // recvfrom 里，行为未定义，只能靠自发一发唤醒包这种把戏。
        // read source 的 cancelHandler 保证「取消完成后」才关 fd，没有竞态，
        // 而且空闲时不占住一个线程。
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: receiveQueue)
        // fd 用值捕获：drain 跑在收包队列上，而 stop() 在主线程把 self.fd 置回 -1，
        // 从闭包里读 self.fd 就是一个跨线程的数据竞争。cancelHandler 保证
        // 「取消完成之后」才 close，所以处理器里这个值一定还有效。
        let boundFD = fd
        readSource.setEventHandler { [weak self] in self?.drain(boundFD) }
        readSource.setCancelHandler { close(boundFD) }
        source = readSource
        readSource.resume()
        return true
    }

    /// 停收并删掉自己的 socket 文件。
    func stop() {
        assertMain()
        source?.cancel()  // cancelHandler 负责 close(fd)
        source = nil
        fd = -1
        try? FileManager.default.removeItem(at: socketPath)
    }

    /// 建一个非阻塞的 SOCK_DGRAM socket 并 bind 到 path。
    private static func bind(to url: URL) throws -> Int32 {
        let path = url.path
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw PaneStatusWireError.socketPathTooLong(path)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        // bind 遇到已存在的路径会 EADDRINUSE，哪怕那是个死进程留下的文件
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw PaneStatusWireError.sendFailed(errno: errno) }

        // 非阻塞：事件处理器里要一直 recvfrom 到 EAGAIN 为止（一次可读事件可能
        // 对应队列里的多发报文），阻塞 socket 会在最后一发之后把整个队列挂住。
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)

        // 1 MiB 接收缓冲。目标规模是 50 个 pane / 20 个并发 agent：报文本体
        // 200–500B，但内核按 mbuf cluster 记账，每发实际占约 2KB，所以 1 MiB
        // ≈ 500 发排队余量。20 个 agent 各积压 25 个事件（约等于每个 agent 十来次
        // 工具调用）才填满——那已经是主线程卡死好几秒的场景。默认的 8KB 只够 4 发，
        // 一次 UI 掉帧就开始丢。设不上（超 kern.ipc.maxsockbuf）不算错误：
        // 缓冲小一点只是极端情况下丢几发状态，不值得让启动失败。
        var receiveBuffer: Int32 = 1 << 20
        _ = setsockopt(
            fd, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size))

        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw PaneStatusWireError.sendFailed(errno: code)
        }
        return fd
    }

    // MARK: - 收包

    /// 在 `receiveQueue` 上把内核队列排空。
    ///
    /// 每发报文单独往主线程投一次，**不在这里合流**：PaneNotifier 是靠状态**迁移**
    /// 判断「这个 pane 刚跑完」的，把同一 pane 的连续几发压成最后一发会把中间的
    /// `done` 吃掉，提醒就没了。合流该在 UI 层做，PaneStatusPresenter 已按 runloop
    /// tick 合过一次。
    private func drain(_ fd: Int32) {
        // 上限取报文上限的两倍：超限报文会被截断成坏 JSON 而丢弃，正是想要的行为
        var buffer = [UInt8](repeating: 0, count: PaneStatusDatagram.maxBytes * 2)
        while true {
            let received = buffer.withUnsafeMutableBytes { raw in
                recvfrom(fd, raw.baseAddress, raw.count, 0, nil, nil)
            }
            if received < 0 {
                // EINTR 是信号打断，队列里的报文还在，重试即可
                if errno == EINTR { continue }
                // EAGAIN/EWOULDBLOCK：队列空了，等下一次可读事件
                return
            }
            guard received > 0 else { continue }
            let data = Data(buffer[0..<received])
            guard let datagram = try? PaneStatusDatagram.decode(data) else {
                DispatchQueue.main.async { [weak self] in self?.noteMalformed() }
                continue
            }
            DispatchQueue.main.async { [weak self] in
                self?.ingest(datagram)
            }
        }
    }

    private func noteMalformed() {
        assertMain()
        guard !loggedMalformed else { return }
        loggedMalformed = true
        NSLog("pane status: dropped a malformed datagram (further ones stay silent)")
    }

    private func ingest(_ datagram: PaneStatusDatagram) {
        assertMain()
        // detach 之后可能还有在途报文，别把已经清掉的状态复活
        guard attached.contains(datagram.pane) else { return }
        statuses[datagram.pane] = datagram.status
        postChange(datagram.pane)
    }

    // MARK: - pane 生命周期

    /// 登记 pane，并建它的运行时目录 + owner.pid。pane 创建时调用，幂等。
    ///
    /// 目录与状态传输已经无关了——它只剩 handoff 指针（`task` 文件）这一个用途，
    /// 但那是持久的、跨重启的，仍然归文件管。owner.pid 是它的 GC 依据。
    func attach(_ paneID: UUID) {
        assertMain()
        guard attached.insert(paneID).inserted else { return }
        do {
            try PaneRuntimeDirectory.create(paneID: paneID.uuidString)
        } catch {
            // 建不了目录只是这个 pane 没法做 handoff 注入，状态照收
            NSLog("pane runtime dir create failed (\(paneID.uuidString)): \(error)")
        }
    }

    /// 注销 pane：删目录 + 清状态。pane 关闭时调用。
    func detach(_ paneID: UUID) {
        assertMain()
        attached.remove(paneID)
        let hadStatus = statuses.removeValue(forKey: paneID) != nil
        PaneRuntimeDirectory.destroy(paneID: paneID.uuidString)
        if hadStatus { postChange(paneID) }
    }

    /// 启动时清理死进程残留（按 owner.pid 判活）。
    ///
    /// 必须有这一步：`PaneView.dragIdentifier` 每次启动重新生成、全库无恢复机制，
    /// 崩溃或强杀后留下的目录再也不会有人来认领。
    func sweepStale() {
        PaneRuntimeDirectory.sweepStale()
    }

    // MARK: - 查询

    func status(for paneID: UUID) -> PaneStatus? {
        assertMain()
        return statuses[paneID]
    }

    /// 未读 = 处于粘滞的 `done` 态的 pane 数。
    var unreadCount: Int {
        assertMain()
        return statuses.values.reduce(into: 0) { $0 += ($1.state == .done ? 1 : 0) }
    }

    /// 菜单栏图标用的聚合态。
    ///
    /// 优先级 `attention` > `done` > `tool` > `thinking` > `idle`，
    /// 按「要用户做点什么」从强到弱排：`attention` 是卡住了、非人不可；
    /// `done` 是有结果等着看；`tool`/`thinking` 只表示还活着（`tool` 信息更具体，
    /// 排在前面）；都没有才是 `idle`。
    var aggregate: PaneActivity {
        assertMain()
        for state in [PaneActivity.attention, .done, .tool, .thinking]
        where statuses.values.contains(where: { $0.state == state }) {
            return state
        }
        return .idle
    }

    // MARK: - 已读

    /// `done` → `idle`，**只改内存**：hook 是纯发方，没有反向通道，
    /// 而且下一发 hook 报文本来就会盖掉它。
    func markRead(_ paneID: UUID) {
        assertMain()
        guard let current = statuses[paneID], current.state == .done else { return }
        statuses[paneID] = Self.markedRead(current)
        postChange(paneID)
    }

    func markAllRead() {
        assertMain()
        var changed = false
        for (paneID, status) in statuses where status.state == .done {
            statuses[paneID] = Self.markedRead(status)
            changed = true
        }
        // 多个 pane 一起变 → object 为 nil，观察者走全量分支
        if changed { postChange(nil) }
    }

    private static func markedRead(_ status: PaneStatus) -> PaneStatus {
        PaneStatus(
            v: status.v,
            ts: status.ts,
            state: .idle,
            agent: status.agent,
            sessionID: status.sessionID,
            tool: status.tool,
            detail: status.detail,
            cwd: status.cwd
        )
    }

    // MARK: - 通知

    /// 从通知里取变化的 pane。nil = 全量（多个 pane 变了，或发方没说）。
    ///
    /// `UUID` 是 struct，装不进 `Notification.object`（`Any?` 里只能放对象），
    /// 所以线上是 `NSUUID`；两种 cast 都试是为了让 post 方怎么写都不会踩空。
    static func paneID(from notification: Notification) -> UUID? {
        if let uuid = notification.object as? UUID { return uuid }
        if let boxed = notification.object as? NSUUID { return boxed as UUID }
        return nil
    }

    private func postChange(_ paneID: UUID?) {
        NotificationCenter.default.post(
            name: .lighttyPaneStatusDidChange, object: paneID.map { $0 as NSUUID })
    }

    private func assertMain(_ function: StaticString = #function) {
        assert(Thread.isMainThread, "PaneStatusStore.\(function) 只能在主线程调用")
    }
}
