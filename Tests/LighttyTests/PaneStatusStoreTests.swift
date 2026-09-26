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

    private func send(_ state: PaneActivity, to pane: UUID, tool: String? = nil, event: String? = nil, agent: String = "claude") {
        PaneStatusDatagram(
            pane: pane, status: PaneStatus(ts: Date(), state: state, agent: agent, tool: tool, event: event)
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

    /// 状态由 hook 驱动。标题仅补 Claude 中断缺口，不能复活已读提醒或制造新的等待。
    func testTerminalTitleOnlyFillsTheClaudeInterruptGap() throws {
        let busy = AgentTerminalTitle(phase: .busy, body: "t")
        let settled = AgentTerminalTitle(phase: .settled, body: "t")
        let attention = AgentTerminalTitle(phase: .attention, body: "t")
        for agent in ["claude", "codex"] {
            let pane = UUID()
            attach(pane)
            store.noteTerminalTitle(busy, in: pane)
            XCTAssertNil(store.status(for: pane))

            func hook(_ state: PaneActivity, _ event: String) throws {
                let count = received.count
                send(state, to: pane, event: event, agent: agent)
                try waitUntil("hook received") { self.received.count > count }
            }
            try hook(.idle, "SessionStart")
            store.noteTerminalTitle(busy, in: pane)
            XCTAssertEqual(store.status(for: pane)?.state, .idle)
            try hook(.thinking, "UserPromptSubmit")
            store.noteTerminalTitle(.init(phase: .settled, body: "shell", recognizedByPrefix: false), in: pane)
            XCTAssertEqual(store.status(for: pane)?.state, .thinking, "Only an explicit idle prefix can fill the gap")
            store.noteTerminalTitle(settled, in: pane)
            XCTAssertEqual(store.status(for: pane)?.state, agent == "claude" ? .idle : .thinking)
            try hook(.tool, "PreToolUse")
            store.noteTerminalTitle(busy, in: pane)
            XCTAssertEqual(store.status(for: pane)?.state, .tool)
            store.noteTerminalTitle(settled, in: pane)
            XCTAssertEqual(store.status(for: pane)?.state, agent == "claude" ? .idle : .tool)
            // 空闲标题先到，后到的 Stop 仍确认为正常完成；Interrupt 则回空闲。
            try hook(.done, "Stop")
            XCTAssertEqual(store.unreadActivity(for: pane), .done)
            try hook(.idle, "Interrupt")
            XCTAssertNil(store.unreadActivity(for: pane))

            // 重放完成/等待后的标题动画和同态 hook：不能出现第二次提醒边沿。
            for (state, event) in [(PaneActivity.done, "Stop"), (.attention, "PermissionRequest")] {
                try hook(.thinking, "UserPromptSubmit")
                try hook(state, event)
                let before = received.count
                for title in [busy, settled, attention, busy, attention] {
                    store.noteTerminalTitle(title, in: pane)
                    XCTAssertEqual(store.status(for: pane)?.state, state)
                }
                XCTAssertEqual(received.count, before, "Title animation must not publish activity transitions")
                try hook(state, event)
                XCTAssertEqual(store.unreadActivity(for: pane), state)
                store.markRead(pane)
                let readState = store.status(for: pane)
                for title in [busy, attention, settled] { store.noteTerminalTitle(title, in: pane) }
                XCTAssertEqual(store.status(for: pane), readState)
                XCTAssertNil(store.unreadActivity(for: pane))
            }
            // 真正的下一轮仍由 hook 开始并正常产生新的提醒。
            try hook(.thinking, "UserPromptSubmit")
            try hook(.attention, "PermissionRequest")
            XCTAssertEqual(store.unreadActivity(for: pane), .attention)
            try hook(.idle, "SessionEnd")
            for title in [busy, attention, settled] { store.noteTerminalTitle(title, in: pane) }
            XCTAssertEqual(store.status(for: pane)?.state, .idle)
        }
    }

    /// 仅 Codex 的兜底：hook 全失效时，本 pane 的标题与 OSC 9 推状态；hook 在管时一律不动；
    /// hook 报文一到就接管，哪怕它的时间戳比兜底状态早（标题常比 hook 先到）。
    func testCodexTerminalSignalsStandInOnlyWhileNoHookIsInCharge() throws {
        let busy = AgentTerminalTitle(phase: .busy, body: "t")
        let settled = AgentTerminalTitle(phase: .settled, body: "t")
        let attention = AgentTerminalTitle(phase: .attention, body: "t")
        let pane = UUID()
        attach(pane)

        store.noteCodexFallbackTitle(settled, in: pane)
        XCTAssertNil(store.status(for: pane), "起步时的空闲标题什么都不是")
        // 还没提交过输入时的转圈是加载模型、起 MCP：什么都不标
        store.noteCodexFallbackTitle(busy, in: pane)
        store.noteCodexFallbackTitle(settled, in: pane)
        XCTAssertNil(store.status(for: pane))
        // 提交之后的转圈立刻算思考中；转完回到空闲，不能留下「已完成」
        store.noteCodexSubmit(in: pane)
        store.noteCodexFallbackTitle(busy, in: pane)
        XCTAssertEqual(store.status(for: pane)?.agent, "codex")
        store.noteCodexFallbackTitle(settled, in: pane)
        XCTAssertEqual(store.status(for: pane)?.state, .idle)
        XCTAssertNil(store.unreadActivity(for: pane), "标题不判完成")
        store.noteCodexFallbackTitle(attention, in: pane)
        XCTAssertEqual(store.unreadActivity(for: pane), .attention)
        store.noteCodexFallbackTitle(settled, in: pane)
        XCTAssertEqual(store.status(for: pane)?.state, .idle)

        store.noteCodexFallbackNotification("Approval requested: rm -rf build", in: pane)
        XCTAssertEqual(store.unreadActivity(for: pane), .attention)
        store.noteCodexFallbackNotification("好的，已经改完了。", in: pane)
        XCTAssertEqual(store.unreadActivity(for: pane), .done)

        // hook 接管：时间戳早于兜底状态的报文照收
        PaneStatusDatagram(pane: pane, status: PaneStatus(
            ts: Date().addingTimeInterval(-5), state: .thinking, agent: "codex", sessionID: "s",
            event: "UserPromptSubmit")).send(to: socketPath)
        try waitUntil("hook takes over") { self.store.status(for: pane)?.event == "UserPromptSubmit" }
        for title in [settled, attention, busy] { store.noteCodexFallbackTitle(title, in: pane) }
        store.noteCodexFallbackNotification("Agent turn complete", in: pane)
        XCTAssertEqual(store.status(for: pane)?.event, "UserPromptSubmit", "hook 在管时兜底不动")
        XCTAssertEqual(store.status(for: pane)?.state, .thinking)

        // 会话结束后，下一段会话若没有 hook，兜底重新可用
        PaneStatusDatagram(pane: pane, status: PaneStatus(
            ts: Date(), state: .idle, agent: "codex", sessionID: "s", event: "SessionEnd")).send(to: socketPath)
        try waitUntil("session ended") { self.store.status(for: pane)?.event == "SessionEnd" }
        store.noteCodexFallbackTitle(busy, in: pane)
        XCTAssertEqual(store.status(for: pane)?.state, .thinking)
        // Codex 退出后下一个起来前的转圈又是加载，要重新提交才算
        store.forgetCodexSubmit(in: pane)
        store.noteCodexFallbackTitle(settled, in: pane)
        store.noteCodexFallbackTitle(busy, in: pane)
        XCTAssertEqual(store.status(for: pane)?.state, .idle)
        XCTAssertEqual(store.status(for: pane)?.event, PaneStatusStore.fallbackEvent)
    }

    /// pane 有了 Codex 会话路由，hook 那条路就通了：兜底停用，已经推上去的兜底状态清掉。
    /// SessionStart 要等第一条消息，只看「有没有 hook 状态」挡不住启动时的加载转圈。
    func testARoutedPaneIgnoresTerminalSignals() throws {
        let pane = UUID()
        attach(pane)
        store.noteCodexSubmit(in: pane)
        store.noteCodexFallbackTitle(AgentTerminalTitle(phase: .busy, body: "t"), in: pane)
        XCTAssertEqual(store.status(for: pane)?.state, .thinking)
        store.setCodexRouted(true, pane: pane)
        XCTAssertNil(store.status(for: pane))
        store.noteCodexFallbackTitle(AgentTerminalTitle(phase: .busy, body: "t"), in: pane)
        store.noteCodexFallbackNotification("Agent turn complete", in: pane)
        XCTAssertNil(store.status(for: pane))
        store.setCodexRouted(false, pane: pane)
        store.noteCodexFallbackNotification("Agent turn complete", in: pane)
        XCTAssertEqual(store.unreadActivity(for: pane), .done)
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
