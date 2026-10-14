import XCTest
import Testing
import LighttyCore
@testable import lightty

/// Codex 共享后台进程的会话 → pane：选 pane 的规则，以及旁听连接的 WebSocket 帧。
final class CodexSessionRouterTests: XCTestCase {
    private func client(_ pane: UUID, pid: Int32, started: UInt64, arguments: [String] = ["codex"],
                        cwd: String? = "/work") -> CodexSessionRouter.Client {
        .init(pane: pane, process: AgentProcessIdentity(pid: pid, startedSeconds: started, startedMicroseconds: 0),
              arguments: arguments, workingDirectory: cwd)
    }

    private let thread = "01a0d992-037e-7f10-8aaa-9452ab2e0c3c"

    /// 续接（`codex resume <ID>`）：参数里带着会话 ID 的那个，别的条件都不看。
    func testTheClientNamingTheThreadWins() {
        let a = UUID(), b = UUID()
        let chosen = CodexSessionRouter.choose(
            threadID: thread, cwd: "/work", createdAt: nil, announced: false,
            clients: [client(a, pid: 10, started: 100), client(b, pid: 11, started: 100, arguments: ["codex", "resume", thread])])
        XCTAssertEqual(chosen?.pane, b)
    }

    /// 刚宣布的会话，目录里只有一个界面：就是它。目录写法不同（尾斜杠）也算一致；
    /// 同一界面里 `/new` 出来的新会话也是这样对上的，不管界面启动了多久。
    func testAnAnnouncedThreadGoesToTheOnlyClientInItsDirectory() {
        let a = UUID(), b = UUID()
        let chosen = CodexSessionRouter.choose(
            threadID: thread, cwd: "/work/", createdAt: Date(timeIntervalSince1970: 90_000), announced: true,
            clients: [client(a, pid: 10, started: 100, cwd: "/elsewhere"), client(b, pid: 11, started: 100)])
        XCTAssertEqual(chosen?.pane, b)
        XCTAssertNil(CodexSessionRouter.choose(threadID: thread, cwd: "/nowhere", createdAt: nil, announced: true,
                                               clients: [client(a, pid: 10, started: 100)]))
    }

    /// 连上时补查到的会话可能是残留：界面早已退出，会话还挂在后台进程里，目录和新开的界面
    /// 一样（实测遇到过）。没有 `thread/started`，只凭目录不配；创建时间贴着界面启动才配。
    func testALingeringThreadIsNotMatchedByDirectoryAlone() {
        let a = UUID()
        let fresh = client(a, pid: 10, started: 1_000)
        XCTAssertNil(CodexSessionRouter.choose(threadID: thread, cwd: "/work", createdAt: nil, announced: false,
                                               clients: [fresh]))
        XCTAssertNil(CodexSessionRouter.choose(threadID: thread, cwd: "/work",
                                               createdAt: Date(timeIntervalSince1970: 400), announced: false,
                                               clients: [fresh]))
        XCTAssertEqual(CodexSessionRouter.choose(threadID: thread, cwd: "/work",
                                                 createdAt: Date(timeIntervalSince1970: 1_001), announced: false,
                                                 clients: [fresh])?.pane, a)
    }

    /// 同一目录好几个界面：按创建时间取最近的，但必须明显更近，否则宁可不选。
    func testSeveralClientsInOneDirectory() {
        let old = client(UUID(), pid: 10, started: 1_000)
        let fresh = client(UUID(), pid: 11, started: 1_100)
        XCTAssertNil(CodexSessionRouter.choose(threadID: thread, cwd: "/work", createdAt: nil, announced: true,
                                               clients: [old, fresh]))
        XCTAssertEqual(CodexSessionRouter.choose(threadID: thread, cwd: "/work",
                                                 createdAt: Date(timeIntervalSince1970: 1_101), announced: true,
                                                 clients: [old, fresh])?.pane, fresh.pane)
        // 两个都在一秒内启动：分不清，不选
        let twin = client(UUID(), pid: 12, started: 1_100)
        XCTAssertNil(CodexSessionRouter.choose(threadID: thread, cwd: "/work",
                                               createdAt: Date(timeIntervalSince1970: 1_101), announced: true,
                                               clients: [fresh, twin]))
        // 离得太远（不是这次启动建的会话）：不选
        XCTAssertNil(CodexSessionRouter.choose(threadID: thread, cwd: "/work",
                                               createdAt: Date(timeIntervalSince1970: 5_000), announced: true,
                                               clients: [old, fresh]))
    }

    /// 后台进程自己建的会话不上任何 pane：实测生成标题时建了一个同目录的临时会话，
    /// 配上去会把真正会话的记录挤掉，回合的 Stop 跟着丢了。
    func testOnlyUserThreadsBelongToATerminal() {
        XCTAssertTrue(CodexSessionRouter.isShownInATerminal(["id": "a", "threadSource": "user", "ephemeral": false]))
        XCTAssertTrue(CodexSessionRouter.isShownInATerminal(["id": "a"]), "旧版本没有来源字段")
        XCTAssertFalse(CodexSessionRouter.isShownInATerminal(["id": "a", "threadSource": "thread_title", "ephemeral": true]))
        XCTAssertFalse(CodexSessionRouter.isShownInATerminal(["id": "a", "threadSource": "user", "ephemeral": true]))
        XCTAssertFalse(CodexSessionRouter.isShownInATerminal(["id": "a", "threadSource": "subagent"]))
        XCTAssertFalse(CodexSessionRouter.isShownInATerminal(["id": "a", "parentThreadId": "b"]))
        XCTAssertTrue(CodexSessionRouter.isShownInATerminal(["id": "a", "parentThreadId": NSNull()]))
    }

    // MARK: - WebSocket 帧

    /// 客户端发的帧带掩码；服务端的解码器照样认得（掩码按规范异或回来）。
    func testMaskedFramesRoundTripAtEveryLengthEncoding() throws {
        for size in [5, 125, 126, 70_000] {
            let payload = Data((0..<size).map { UInt8($0 % 251) })
            var decoder = WebSocketFrames.Decoder()
            decoder.append(WebSocketFrames.encodeText(payload))
            XCTAssertEqual(try decoder.next(), .text(payload), "\(size)")
            XCTAssertNil(try decoder.next())
        }
    }

    /// 半帧先到：等下一块；分片拼回整条；ping 交出去回 pong；二进制帧跳过不卡住后面的帧。
    func testServerFramesArrivingInPiecesAndFragments() throws {
        func frame(_ first: UInt8, _ body: String) -> Data {
            Data([first, UInt8(body.utf8.count)]) + Data(body.utf8)
        }
        var decoder = WebSocketFrames.Decoder()
        let whole = frame(0x81, #"{"a":1}"#)
        decoder.append(whole.prefix(3))
        XCTAssertNil(try decoder.next())
        decoder.append(whole.dropFirst(3))
        XCTAssertEqual(try decoder.next(), .text(Data(#"{"a":1}"#.utf8)))

        decoder.append(frame(0x82, "bin") + frame(0x01, #"{"b":"#) + frame(0x89, "hi") + frame(0x80, "2}"))
        XCTAssertEqual(try decoder.next(), .ping(Data("hi".utf8)))
        XCTAssertEqual(try decoder.next(), .text(Data(#"{"b":2}"#.utf8)))
        decoder.append(Data([0x88, 0]))
        XCTAssertEqual(try decoder.next(), .close)
    }
}

/// 旁听连接的替身。`dead` 模拟后台进程已经换过：`proxy` 读不到结尾、不退出，
/// 直到下一次往里写才报错退出（上游 `stdio-to-uds` 的 `try_join!`）。
private final class FakeDaemonConnection: CodexDaemonConnection {
    var onNotification: ((String, [String: Any]) -> Void)?
    var onClose: (() -> Void)?
    var dead = false
    private(set) var requests: [String] = []
    var threads: [String: [String: Any]] = [:]
    private var closed = false
    private let loaded: () -> [String]

    init(loaded: @escaping () -> [String]) { self.loaded = loaded }

    func request(_ method: String, params: [String: Any], completion: @escaping ([String: Any]?) -> Void) {
        requests.append(method)
        guard !dead else { completion(nil); close(); return }
        let result: [String: Any]?
        switch method {
        case "initialize": result = [:]
        case "thread/loaded/list": result = ["data": loaded()]
        case "thread/read": result = (params["threadId"] as? String).flatMap { threads[$0] }.map { ["thread": $0] }
        default: result = nil
        }
        DispatchQueue.main.async { completion(result) }
    }

    func notify(_ method: String) {}

    func close() {
        guard !closed else { return }
        closed = true
        DispatchQueue.main.async { [onClose] in onClose?() }
    }
}

@MainActor
struct CodexDaemonReconnectTests {
    @Test(arguments: [false, true]) func restoredSessionReceivesDaemonActivityBeforeAnyHook(snapshot: Bool) async throws {
        let f = try SessionModelFixture()
        defer { f.close() }
        let record = f.record("restored-thread"), pane = f.pane()
        try await f.load([record])
        f.library.associate(.restoring(f.association(record)), with: pane)
        let connection = FakeDaemonConnection(loaded: { snapshot ? [record.key.nativeID] : [] })
        connection.threads[record.key.nativeID] = ["id": record.key.nativeID, "status": ["type": "active"]]
        let router = CodexSessionRouter(library: f.library, socketPath: "/nonexistent.sock",
            runDirectory: f.root.appendingPathComponent("run")) { _ in connection }
        router.start()
        defer { router.stop() }
        try await f.wait { connection.requests.contains("thread/loaded/list") }
        if snapshot {
            try await f.wait { connection.requests.contains("thread/read") }
            await awaitMainQueue(hops: 2)
        } else {
            connection.onNotification?("thread/status/changed", ["threadId": record.key.nativeID,
                "status": ["type": "active"]])
        }
        #expect(f.library.paneState(for: pane)?.status?.state == .thinking)
        #expect(f.library.paneState(for: pane)?.acceptsInput == false)
        // 回合中等用户（批准、回答提问——后者没有 hook）：等你；用户处理完回到思考中。
        for flag in ["waitingOnApproval", "waitingOnUserInput"] {
            connection.onNotification?("thread/status/changed", ["threadId": record.key.nativeID,
                "status": ["type": "active", "activeFlags": [flag]]])
            #expect(f.library.paneState(for: pane)?.status?.state == .attention, "\(flag)")
            connection.onNotification?("thread/status/changed", ["threadId": record.key.nativeID,
                "status": ["type": "active", "activeFlags": []]])
            #expect(f.library.paneState(for: pane)?.status?.state == .thinking, "\(flag)")
        }
        connection.onNotification?("turn/completed", ["threadId": record.key.nativeID,
            "turn": ["id": "restored-turn", "status": "completed"]])
        #expect(f.library.paneState(for: pane)?.status?.state == .done)
    }

    @Test func daemonCompletionUnlocksInputWhenStopHookIsMissing() async throws {
        let f = try SessionModelFixture()
        defer { f.close() }
        let record = f.record("completed-thread"), pane = f.pane()
        try await f.load([record])
        try await f.status(.thinking, event: "UserPromptSubmit", pane: pane, record: record)
        let connection = FakeDaemonConnection(loaded: { [] })
        let router = CodexSessionRouter(library: f.library, socketPath: "/nonexistent.sock",
            runDirectory: f.root.appendingPathComponent("run")) { _ in connection }
        router.start()
        defer { router.stop() }
        try await f.wait { connection.requests.contains("thread/loaded/list") }
        #expect(f.library.paneState(for: pane)?.acceptsInput == false)
        connection.onNotification?("turn/completed", ["threadId": record.key.nativeID,
            "turn": ["id": "turn-1", "status": "completed"]])
        #expect(f.library.paneState(for: pane)?.status?.state == .done)
        #expect(f.library.paneState(for: pane)?.acceptsInput == true)
        connection.onNotification?("thread/status/changed", ["threadId": record.key.nativeID,
            "status": ["type": "idle"]])
        #expect(f.library.paneState(for: pane)?.status?.state == .done,
            "The idle notification must not consume the completion reminder")
        f.library.markRead(pane)
        connection.onNotification?("turn/completed", ["threadId": record.key.nativeID,
            "turn": ["id": "turn-1", "status": "completed"]])
        #expect(f.library.paneState(for: pane)?.status?.state == .idle,
            "Duplicate completion must not recreate a read reminder")

        // A late tool hook must not lock rename again. A second pane provides a
        // socket queue barrier, so the assertion is after the hook was consumed.
        let other = f.pane(), otherRecord = f.record("other-thread")
        for event in ["PostToolUse", "Stop"] {
            let state: PaneActivity = event == "Stop" ? .done : .thinking
            _ = PaneStatusDatagram(pane: pane, status: PaneStatus(ts: Date(), state: state,
                agent: "codex", sessionID: record.key.nativeID, event: event))
                .send(to: f.statuses.socketPath)
            try await f.status(.thinking, event: event, pane: other, record: otherRecord)
            #expect(f.library.paneState(for: pane)?.status?.state == .idle)
        }
        // Idle snapshots repair a missed completion without inventing a reminder.
        try await f.status(.thinking, event: "UserPromptSubmit", pane: pane, record: record)
        connection.onNotification?("thread/status/changed", ["threadId": "unknown-thread",
            "status": ["type": "idle"]])
        #expect(f.library.paneState(for: pane)?.acceptsInput == false)
        connection.onNotification?("thread/status/changed", ["threadId": record.key.nativeID,
            "status": ["type": "idle"]])
        #expect(f.library.paneState(for: pane)?.acceptsInput == true)

        // Hook completion first, followed by daemon completion: still one reminder.
        try await f.status(.thinking, event: "UserPromptSubmit", pane: pane, record: record)
        try await f.status(.done, event: "Stop", pane: pane, record: record)
        f.library.markRead(pane)
        connection.onNotification?("turn/completed", ["threadId": record.key.nativeID,
            "turn": ["id": "turn-3", "status": "completed"]])
        #expect(f.library.paneState(for: pane)?.status?.state == .idle)
        for outcome in ["interrupted", "failed"] {
            try await f.status(.thinking, event: "UserPromptSubmit", pane: pane, record: record)
            connection.onNotification?("turn/completed", ["threadId": record.key.nativeID,
                "turn": ["id": outcome, "status": outcome]])
            #expect(f.library.paneState(for: pane)?.acceptsInput == true)
            #expect(f.library.paneState(for: pane)?.status?.state == (outcome == "failed" ? .attention : .idle))
        }
    }

    /// Codex 升级会让后台进程重启，旁听连接却不会自己断（见 `CodexDaemonChannel`）。回归：
    /// 0.158 升级后连接一直挂着，之后新开的会话一条广播都收不到，标题回不到 pane 上。
    /// 平时不探；有新的 Codex 界面起来时往里写一次，死连接就此暴露，马上重连并补查。
    @Test func aNewCodexPaneExposesADeadConnectionAndReconnects() async throws {
        let f = try SessionModelFixture()
        defer { f.close() }
        let record = f.record("thread-after-restart")
        try await f.load([record])
        let runDirectory = f.root.appendingPathComponent("run")
        var connections: [FakeDaemonConnection] = []
        let router = CodexSessionRouter(library: f.library, socketPath: "/nonexistent.sock",
                                        runDirectory: runDirectory) { _ in
            let connection = FakeDaemonConnection(loaded: { [record.key.nativeID] })
            connections.append(connection)
            return connection
        }
        router.start()
        defer { router.stop() }
        try await f.wait { connections.first?.requests.contains("thread/loaded/list") == true }
        let first = try #require(connections.first)
        let requestsWhileIdle = first.requests.count
        await awaitMainQueue(hops: 3)
        #expect(first.requests.count == requestsWhileIdle, "没有新迹象时不往连接里写")

        first.dead = true
        f.library.associate(.attached(f.association(record)), with: f.pane())
        try await f.wait { connections.count == 2 && connections[1].requests.contains("thread/loaded/list") }
        #expect(first.requests.last == "thread/loaded/list", "死连接是被这一次补查写出来的")
    }
}
