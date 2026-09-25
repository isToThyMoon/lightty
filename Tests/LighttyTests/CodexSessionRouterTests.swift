import XCTest
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
