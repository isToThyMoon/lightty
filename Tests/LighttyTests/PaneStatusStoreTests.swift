import LighttyCore
import XCTest

@testable import lightty

/// `PaneStatusStore` 的收包侧。用例发的是**真报文**——同一个 `PaneStatusDatagram.send`，
/// 从后台线程打到一个真的 Unix domain datagram socket 上。
/// 造假的 ingest 只能证明字典赋值没写错，证明不了这条传输链路。
///
/// **绝不绑真实的 `~/.lightty/run`**：每个用例一个临时路径（构造函数的测试接缝）。
final class PaneStatusStoreTests: XCTestCase {
    private var store: PaneStatusStore!
    private var socketPath: URL!
    private var observer: NSObjectProtocol?
    /// 收到的通知：(pane, 通知时刻 store 里的状态)。主线程独占，不需要锁。
    private var received: [(pane: UUID?, state: PaneActivity?)] = []
    /// attach 会在真实的 ~/.lightty/panes 下建目录（handoff 指针仍走文件），
    /// tearDown 必须收干净，不能给用户目录留垃圾。
    private var attachedPanes: [UUID] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        // socket 路径受 sun_path 104 字节限制，别用 XCTest 那套长临时目录
        socketPath = URL(fileURLWithPath: "/tmp/lightty-t-\(UInt32.random(in: 0...0xFFFF_FFFF)).sock")
        store = PaneStatusStore(socketPath: socketPath)
        XCTAssertTrue(store.start(), "socket 没绑上，后面的用例都没意义")

        observer = NotificationCenter.default.addObserver(
            forName: .lighttyPaneStatusDidChange, object: nil, queue: nil
        ) { [weak self] note in
            guard let self else { return }
            let pane = PaneStatusStore.paneID(from: note)
            self.received.append((pane, pane.flatMap { self.store.status(for: $0)?.state }))
        }
    }

    override func tearDownWithError() throws {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        for pane in attachedPanes { store.detach(pane) }
        attachedPanes.removeAll()
        store.stop()
        store = nil
        received.removeAll()
        try super.tearDownWithError()
    }

    // MARK: - 工具

    private func attach(_ pane: UUID) {
        store.attach(pane)
        attachedPanes.append(pane)
    }

    private func send(_ state: PaneActivity, to pane: UUID, tool: String? = nil, event: String? = nil) {
        PaneStatusDatagram(
            pane: pane, status: PaneStatus(ts: Date(), state: state, agent: "claude", tool: tool, event: event)
        ).send(to: socketPath)
    }

    // MARK: - 用例

    /// 顺序就是契约：datagram 到达顺序 == 发送顺序，所以 `seq` 才敢删掉。
    func testDeliversDatagramsInSendOrder() throws {
        let pane = UUID()
        attach(pane)

        for state in [PaneActivity.thinking, .tool, .thinking, .done] { send(state, to: pane) }

        try waitUntil("四发都到") { self.received.count >= 4 }
        XCTAssertEqual(received.map(\.state), [.thinking, .tool, .thinking, .done])
        XCTAssertEqual(store.status(for: pane)?.state, .done)
    }

    /// 忙/闲这条边由 agent 写进终端标题的状态推（`AgentTerminalTitle`）：Claude Code 按 Esc 中断时
    /// 不发任何 hook，只有标题前缀从 ◐ 变回 ✳。一条用例走完整个场景：hook 登记之前标题不算数；
    /// 忙把空闲顶成思考中；闲把思考中收回空闲（中断）；正常结束 Stop → done 之后闲不动 done；
    /// 下一轮忙顶掉 done；等待你处理不受闲影响；工具中比思考中具体，忙不降级；Codex 的
    /// `Action Required` 点亮等待你处理、已读后不重复点亮；SessionEnd 之后标题一律忽略
    /// （同一个 pane 之后跑的可能是别的程序）。
    func testTerminalTitleDrivesTheBusyIdleEdge() throws {
        let pane = UUID()
        attach(pane)
        let busy = AgentTerminalTitle(phase: .busy, body: "t"), settled = AgentTerminalTitle(phase: .settled, body: "t")
        let attention = AgentTerminalTitle(phase: .attention, body: "t")

        store.noteTerminalTitle(busy, in: pane)
        XCTAssertNil(store.status(for: pane), "hook 还没登记 agent，标题不算数")

        send(.idle, to: pane, event: "SessionStart")
        try waitUntil("session start") { self.store.status(for: pane) != nil }
        store.noteTerminalTitle(busy, in: pane)
        XCTAssertEqual(store.status(for: pane)?.state, .thinking)
        XCTAssertEqual(store.status(for: pane)?.event, "SessionStart", "只换 state，其余字段保留")
        XCTAssertEqual(received.last?.state, .thinking, "要发通知，侧栏才会刷新")

        store.noteTerminalTitle(settled, in: pane)
        XCTAssertEqual(store.status(for: pane)?.state, .idle, "按 Esc：思考中收回空闲")

        store.noteTerminalTitle(busy, in: pane)
        send(.done, to: pane, event: "Stop")
        try waitUntil("done") { self.store.status(for: pane)?.state == .done }
        store.noteTerminalTitle(settled, in: pane)
        XCTAssertEqual(store.status(for: pane)?.state, .done, "正常结束：✳ 不能吃掉未读的完成")
        store.noteTerminalTitle(busy, in: pane)
        XCTAssertEqual(store.status(for: pane)?.state, .thinking, "下一轮开始，done 让位")

        send(.attention, to: pane, event: "Notification")
        try waitUntil("attention") { self.store.status(for: pane)?.state == .attention }
        store.noteTerminalTitle(settled, in: pane)
        XCTAssertEqual(store.status(for: pane)?.state, .attention, "对话框开着时前缀也是 ✳，不能当成空闲")
        store.noteTerminalTitle(busy, in: pane)
        XCTAssertEqual(store.status(for: pane)?.state, .thinking, "用户答了对话框，回合继续")

        send(.tool, to: pane, event: "PreToolUse")
        try waitUntil("tool") { self.store.status(for: pane)?.state == .tool }
        store.noteTerminalTitle(busy, in: pane)
        XCTAssertEqual(store.status(for: pane)?.state, .tool, "工具中更具体，不降级")

        // Codex 的 `Action Required`：进行中变成等待你处理；用户读过之后闪烁的下一相位不能再点亮
        store.noteTerminalTitle(attention, in: pane)
        XCTAssertEqual(store.status(for: pane)?.state, .attention)
        XCTAssertEqual(store.unreadActivity(for: pane), .attention)
        store.markRead(pane)
        store.noteTerminalTitle(attention, in: pane)
        XCTAssertNil(store.unreadActivity(for: pane), "同一个请求的闪烁相位不是新请求")
        store.noteTerminalTitle(busy, in: pane)
        XCTAssertEqual(store.status(for: pane)?.state, .thinking, "用户答完，回合继续")

        send(.idle, to: pane, event: "SessionEnd")
        try waitUntil("session end") { self.store.status(for: pane)?.event == "SessionEnd" }
        store.noteTerminalTitle(busy, in: pane)
        XCTAssertEqual(store.status(for: pane)?.state, .idle, "agent 退出后标题归别的程序")
    }

    /// 分发是**定向**的：通知必须说清是哪个 pane 变了，否则呈现层只能全量重扫。
    func testNotificationCarriesTheChangedPaneID() throws {
        let a = UUID()
        let b = UUID()
        attach(a)
        attach(b)

        send(.tool, to: a)
        try waitUntil("a 到了") { self.received.count >= 1 }
        send(.done, to: b)
        try waitUntil("b 到了") { self.received.count >= 2 }

        XCTAssertEqual(received.map(\.pane), [a, b])
        XCTAssertEqual(store.status(for: a)?.state, .tool)
        XCTAssertEqual(store.status(for: b)?.state, .done)
    }

    /// 这条是换传输层的**理由**本身：文件当可变槽位时主线程一忙就整批丢，
    /// 内核接收队列不会。200 发是 20 个并发 agent 的一轮突发量级。
    func testBurstOfTwoHundredDatagramsAllArrive() throws {
        let pane = UUID()
        attach(pane)

        let sender = DispatchQueue(label: "test.sender")
        sender.async {
            for _ in 0..<200 {
                PaneStatusDatagram(pane: pane, status: PaneStatus(ts: Date(), state: .tool))
                    .send(to: self.socketPath)
            }
        }

        try waitUntil("200 发全到", timeout: 10) { self.received.count >= 200 }
        XCTAssertEqual(received.count, 200)
        XCTAssertTrue(received.allSatisfy { $0.pane == pane })
    }

    /// 未 attach 的 pane 的报文要丢：detach 之后还有在途报文，不能把状态复活。
    func testDetachDropsStateAndIgnoresInFlightDatagrams() throws {
        let pane = UUID()
        attach(pane)
        send(.done, to: pane)
        try waitUntil("先收到一发") { self.store.status(for: pane) != nil }

        store.detach(pane)
        XCTAssertNil(store.status(for: pane))

        send(.tool, to: pane)
        // 没有「什么都没发生」的事件可等，只能给足时间再确认状态没被复活
        let settled = XCTestExpectation(description: "在途报文被丢弃")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        _ = XCTWaiter().wait(for: [settled], timeout: 2)
        XCTAssertNil(store.status(for: pane))
    }

    func testMalformedDatagramIsDroppedWithoutBreakingTheStream() throws {
        let pane = UUID()
        attach(pane)

        // 三发垃圾：坏 JSON、未知版本、超长（会被收方缓冲截断成坏 JSON）
        PaneStatusDatagram.send(Data("not json at all".utf8), to: socketPath.path)
        PaneStatusDatagram.send(
            Data(#"{"v":999,"pane":"\#(pane.uuidString)","ts":"2026-09-01T12:45:18Z","state":"done"}"#
                .utf8), to: socketPath.path)
        PaneStatusDatagram.send(
            Data(String(repeating: "x", count: PaneStatusDatagram.maxBytes * 3).utf8),
            to: socketPath.path)

        // 链路必须还活着：好报文照收
        send(.done, to: pane)
        try waitUntil("坏报文之后好报文仍然到达") { self.received.count >= 1 }
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(store.status(for: pane)?.state, .done)
    }

    /// `markAllRead` 一次改多个 pane，通知不带 pane（object 为 nil），呈现层走全量分支。
    func testMarkAllReadPostsAFullPassNotification() throws {
        let a = UUID()
        let b = UUID()
        attach(a)
        attach(b)
        send(.done, to: a)
        send(.done, to: b)
        try waitUntil("两发都到") { self.received.count >= 2 }

        XCTAssertEqual(store.unreadCount, 2)
        XCTAssertEqual(store.aggregate, .done)

        received.removeAll()
        store.markAllRead()
        XCTAssertEqual(received.count, 1)
        XCTAssertNil(received.first?.pane)
        XCTAssertEqual(store.unreadCount, 0)
        XCTAssertEqual(store.aggregate, .idle)
    }

    /// Reading acknowledges the reminder without claiming that the Agent has resumed.
    func testMarkReadPreservesAttention() throws {
        let pane = UUID()
        attach(pane)
        send(.attention, to: pane)
        try waitUntil("attention 到达") { self.received.count >= 1 }
        XCTAssertEqual(store.aggregate, .attention)

        store.markRead(pane)
        XCTAssertEqual(store.status(for: pane)?.state, .attention)
        XCTAssertEqual(store.aggregate, .attention)
        XCTAssertNil(store.unreadActivity(for: pane))
        let count = received.count
        store.markRead(pane)
        XCTAssertEqual(received.count, count, "Repeated reads do not publish another change")
    }

    func testStopUnlinksTheSocketFile() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath.path))
        store.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath.path))
        // 幂等：tearDown 还会再调一次
    }
}
