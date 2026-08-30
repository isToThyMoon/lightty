import XCTest

@testable import LighttyCore

/// `PaneStatusDatagram` 的线格式是 **跨可执行文件契约**：lightty-hook 发、主 app 收。
/// 两侧现在共用同一个类型，所以这里锁的是**格式本身**——哪天有人「顺手」改了字段名
/// 或版本闸门，旧的 hook 二进制（用户装在 agent 配置里的那个）就会静默失联。
final class PaneStatusTests: XCTestCase {
    /// lightty-hook 实际发出的字节（2026-09-01 从真实二进制的 sendto 抓取）。
    /// 不要"顺手"改成 encoder 的输出——那样两侧一起漂移时测试仍然绿，就白设了。
    private let goldenWireFormat = """
        {"agent":"claude","cwd":"\\/tmp","pane":"6C6F4B2E-9E31-4E2F-9D45-3A1C2B7E5F80",\
        "session_id":"abc-123","state":"done","ts":"2026-09-01T12:45:18Z","v":1}
        """

    func testDecodesHookWireFormat() throws {
        let datagram = try PaneStatusDatagram.decode(Data(goldenWireFormat.utf8))

        // pane 是路由字段：收方按它分发，认不出就等于报文丢了
        XCTAssertEqual(datagram.pane, UUID(uuidString: "6C6F4B2E-9E31-4E2F-9D45-3A1C2B7E5F80"))

        let status = datagram.status
        XCTAssertEqual(status.v, PaneStatus.currentVersion)
        XCTAssertEqual(status.state, .done)
        XCTAssertEqual(status.agent, "claude")
        // session_id → sessionID 的映射是最容易在重构里被 CodingKeys 改坏的一处
        XCTAssertEqual(status.sessionID, "abc-123")
        XCTAssertEqual(status.cwd, "/tmp")
        XCTAssertNil(status.tool)
        XCTAssertNil(status.detail)
        XCTAssertEqual(status.ts.timeIntervalSince1970, 1_788_266_718, accuracy: 1)
    }

    func testRoundTripsThroughOwnCodec() throws {
        let original = PaneStatusDatagram(
            pane: UUID(),
            status: PaneStatus(
                ts: Date(timeIntervalSince1970: 1_788_266_718), state: .tool,
                agent: "codex", sessionID: "s", tool: "Edit",
                detail: "Sources/lightty/PaneView.swift", cwd: "/repo"))

        let decoded = try PaneStatusDatagram.decode(original.encode())
        XCTAssertEqual(decoded, original)
    }

    /// 信封是**扁平**的：`pane` 与状态字段同级，不是嵌套对象。
    /// 嵌套化会让所有已装的 hook 二进制发出的报文全部被丢弃。
    func testEnvelopeIsFlatOnTheWire() throws {
        let data = try PaneStatusDatagram(
            pane: UUID(uuidString: "6C6F4B2E-9E31-4E2F-9D45-3A1C2B7E5F80")!,
            status: PaneStatus(ts: Date(timeIntervalSince1970: 0), state: .idle)
        ).encode()

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["pane"] as? String, "6C6F4B2E-9E31-4E2F-9D45-3A1C2B7E5F80")
        XCTAssertEqual(object["state"] as? String, "idle")
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertNil(object["status"], "载荷不该被包成子对象")
    }

    /// `seq` 已随文件传输一起退役：datagram 的到达顺序就是发送顺序，
    /// 而旧的 read-modify-write 在 agent 并行发起工具调用时本身就是乱序的来源。
    func testSeqIsGoneFromTheWire() throws {
        let data = try PaneStatusDatagram(
            pane: UUID(), status: PaneStatus(ts: Date(), state: .thinking)
        ).encode()
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("seq"), "线格式里不该再出现 seq：\(json)")
    }

    func testEveryActivityRawValueSurvivesTheWire() throws {
        // 状态名是 hook 侧硬编码的字符串，改 enum case 名会静默断链
        for activity in [PaneActivity.idle, .thinking, .tool, .attention, .done] {
            let json = """
                {"v":1,"pane":"6C6F4B2E-9E31-4E2F-9D45-3A1C2B7E5F80",\
                "ts":"2026-09-01T12:45:18Z","state":"\(activity.rawValue)"}
                """
            XCTAssertEqual(try PaneStatusDatagram.decode(Data(json.utf8)).status.state, activity)
        }
    }

    func testHookEventsMapToActivities() {
        XCTAssertEqual(PaneActivity(hookEventName: "SessionStart"), .idle)
        XCTAssertEqual(PaneActivity(hookEventName: "SessionEnd"), .idle)
        XCTAssertEqual(PaneActivity(hookEventName: "Interrupt"), .idle)
        XCTAssertEqual(PaneActivity(hookEventName: "UserPromptSubmit"), .thinking)
        XCTAssertEqual(PaneActivity(hookEventName: "PostToolUse"), .thinking)
        XCTAssertEqual(PaneActivity(hookEventName: "PreToolUse"), .tool)
        XCTAssertEqual(PaneActivity(hookEventName: "Notification"), .attention)
        XCTAssertEqual(PaneActivity(hookEventName: "PermissionRequest"), .attention)
        XCTAssertEqual(PaneActivity(hookEventName: "Stop"), .done)
        XCTAssertNil(PaneActivity(hookEventName: "FutureEvent"))
    }

    func testRejectsUnknownSchemaVersion() throws {
        let future = """
            {"v":999,"pane":"6C6F4B2E-9E31-4E2F-9D45-3A1C2B7E5F80",\
            "ts":"2026-09-01T12:45:18Z","state":"done"}
            """
        // 未来版本必须整发丢弃而不是半解析——旧 app 遇到新 hook 时的兼容线
        XCTAssertThrowsError(try PaneStatusDatagram.decode(Data(future.utf8))) { error in
            XCTAssertEqual(error as? PaneStatusWireError, .unsupportedVersion(999))
        }
    }

    func testRejectsGarbageAndMissingRouting() {
        XCTAssertThrowsError(try PaneStatusDatagram.decode(Data("not json at all".utf8)))
        // 没有 pane 就无从分发，整发丢弃
        let unrouted = #"{"v":1,"ts":"2026-09-01T12:45:18Z","state":"done"}"#
        XCTAssertThrowsError(try PaneStatusDatagram.decode(Data(unrouted.utf8)))
    }

    // MARK: - socket 路径

    func testSocketPathShapeFitsSunPath() {
        let url = PaneRuntimeDirectory.socketPath(for: 12345)
        XCTAssertEqual(url.lastPathComponent, "12345.sock")
        XCTAssertEqual(
            url.deletingLastPathComponent().standardizedFileURL,
            PaneRuntimeDirectory.runDirectory.standardizedFileURL)

        // sockaddr_un.sun_path 是 104 字节定长数组，装不下就只能不发。
        // 真实 pid 最多 7 位，这里用最坏情况量一次。
        let worst = PaneRuntimeDirectory.socketPath(for: 9_999_999).path
        XCTAssertLessThan(worst.utf8.count, 104, "socket 路径超过 sun_path 上限：\(worst)")
    }

    func testSweepStaleSocketsKeepsLiveOwnerAndRemovesDeadOne() throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: PaneRuntimeDirectory.runDirectory, withIntermediateDirectories: true)

        // 用当前测试进程冒充「活着的实例」；999999 是几乎不可能存在的 pid
        let live = PaneRuntimeDirectory.socketPath()
        let dead = PaneRuntimeDirectory.socketPath(for: 999_999)
        // 不是 <pid>.sock 形状的东西不归我们管，必须留着
        let foreign = PaneRuntimeDirectory.runDirectory.appendingPathComponent("notes.sock")
        for url in [live, dead, foreign] { fm.createFile(atPath: url.path, contents: Data()) }
        defer { for url in [dead, foreign] { try? fm.removeItem(at: url) } }

        PaneRuntimeDirectory.sweepStaleSockets()

        XCTAssertTrue(fm.fileExists(atPath: live.path))
        XCTAssertFalse(fm.fileExists(atPath: dead.path))
        XCTAssertTrue(fm.fileExists(atPath: foreign.path))
        try? fm.removeItem(at: live)
    }

    // MARK: - 发送

    /// hook 跑在用户 agent 的关键路径上：没有 listener 时**必须立刻失败**，
    /// 不能挂住。这是整个方案能被接受的前提，不是一句可以退化的性能优化。
    func testSendToNobodyFailsImmediatelyWithENOENT() throws {
        // 用 /tmp 而不是 NSTemporaryDirectory()：后者在 macOS 上是
        // /var/folders/…/T/，光目录就 49 字节，拼上文件名会直接撞 sun_path 上限
        let path = "/tmp/lightty-absent-\(UInt32.random(in: 0...0xFFFF_FFFF)).sock"
        let datagram = PaneStatusDatagram(
            pane: UUID(), status: PaneStatus(ts: Date(), state: .done))

        let started = Date()
        let result = datagram.send(to: URL(fileURLWithPath: path))
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(try? result.get(), nil)
        if case .failure(.sendFailed(let code)) = result {
            XCTAssertEqual(code, ENOENT)
        } else {
            XCTFail("期望 ENOENT，实际 \(result)")
        }
        XCTAssertLessThan(elapsed, 0.05, "没有 listener 时 sendto 阻塞了 \(elapsed)s")
    }

    func testSendRefusesPathsLongerThanSunPath() {
        let tooLong = "/tmp/" + String(repeating: "x", count: 120) + ".sock"
        let result = PaneStatusDatagram(pane: UUID(), status: PaneStatus(ts: Date(), state: .idle))
            .send(to: URL(fileURLWithPath: tooLong))
        guard case .failure(.socketPathTooLong) = result else {
            return XCTFail("超长路径必须在 sendto 之前被挡掉，实际 \(result)")
        }
    }

    // MARK: - pane 运行时目录（handoff 指针仍走文件）

    func testSweepStaleKeepsLiveOwnerAndRemovesDeadOne() throws {
        let live = "test-live-\(UUID().uuidString)"
        let dead = "test-dead-\(UUID().uuidString)"
        try PaneRuntimeDirectory.create(paneID: live)
        try PaneRuntimeDirectory.create(paneID: dead)
        defer {
            PaneRuntimeDirectory.destroy(paneID: live)
            PaneRuntimeDirectory.destroy(paneID: dead)
        }
        // 用一个几乎不可能存在的 pid 冒充已死进程
        try PaneRuntimeDirectory.atomicWrite(
            Data("999999\n".utf8), to: PaneRuntimeDirectory.ownerPIDFile(for: dead))

        PaneRuntimeDirectory.sweepStale()

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: PaneRuntimeDirectory.directory(for: live).path))
        XCTAssertFalse(fm.fileExists(atPath: PaneRuntimeDirectory.directory(for: dead).path))
    }

    func testAtomicWriteLeavesNoTempFileBehind() throws {
        let paneID = "test-\(UUID().uuidString)"
        try PaneRuntimeDirectory.create(paneID: paneID)
        defer { PaneRuntimeDirectory.destroy(paneID: paneID) }

        try PaneRuntimeDirectory.atomicWrite(
            Data("/tmp/task.md\n".utf8), to: PaneRuntimeDirectory.taskPointerFile(for: paneID))
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: PaneRuntimeDirectory.directory(for: paneID).path)
        // 残留的 .tmp 会被 hook 当成指针文件之外的噪音，也是 rename 没成的信号
        XCTAssertEqual(Set(entries), ["owner.pid", "task"])
    }
}
