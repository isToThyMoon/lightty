import XCTest
import LighttyCore
@testable import lightty

/// 压测：N 个 pane **并发**用真实的 `lightty-hook` 二进制往真实的 store socket 打报文。
///
/// 回答的是「50 个 pane 同时发会不会把 socket 打爆」这个问题，所以发送方必须是
/// 真进程（含 spawn 成本），接收方必须是真 store（含 datagram 解码 + 回主线程分发）。
///
/// 默认跳过：它要起上千个进程，不该拖慢日常回归。要跑时：
/// `LIGHTTY_LOAD_TEST=1 swift test --filter PaneStatusLoadTests`
final class PaneStatusLoadTests: XCTestCase {
    private var store: PaneStatusStore!
    private var socketPath: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LIGHTTY_LOAD_TEST"] != nil,
            "压测默认跳过；LIGHTTY_LOAD_TEST=1 打开")
        // NSTemporaryDirectory 在这台机器上是 /var/folders/…/T/，光目录就 49 字节，
        // 再拼 socket 名会超 sun_path 的 104 上限——用 /tmp
        socketPath = URL(fileURLWithPath: "/tmp/lightty-load-\(getpid()).sock")
        store = PaneStatusStore(socketPath: socketPath)
        XCTAssertTrue(store.start(), "store 没能绑定 \(socketPath.path)")
    }

    override func tearDownWithError() throws {
        // setUp 被 XCTSkip 跳过时这两个都没赋值，tearDown 照样会跑
        store?.stop()
        if let socketPath { try? FileManager.default.removeItem(at: socketPath) }
    }

    private var hookBinary: URL {
        // Tests/LighttyTests/本文件 → 仓库根 → .build/debug/lightty-hook
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/lightty-hook")
    }

    /// 用真 hook 二进制发一发（阻塞到进程退出）
    private func fire(pane: UUID, event: String) throws {
        let p = Process()
        p.executableURL = hookBinary
        p.environment = [
            "LIGHTTY_PANE_ID": pane.uuidString,
            "LIGHTTY_SOCK": socketPath.path,
            "PATH": "/usr/bin:/bin",
        ]
        let stdin = Pipe()
        p.standardInput = stdin
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        stdin.fileHandleForWriting.write(
            Data(#"{"hook_event_name":"\#(event)","tool_name":"Edit"}"#.utf8))
        try stdin.fileHandleForWriting.close()
        p.waitUntilExit()
    }

    func testFiftyPanesConcurrentlyHammerOneSocket() throws {
        let panes = 50, perPane = 20, total = panes * perPane
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: hookBinary.path),
            "先 swift build 出 lightty-hook：\(hookBinary.path)")

        // 收方计数：store 在主线程 post，expectation 的 wait 会泵 runloop
        let received = expectation(description: "received")
        received.expectedFulfillmentCount = total
        var perPaneCount: [UUID: Int] = [:]
        let observer = NotificationCenter.default.addObserver(
            forName: .lighttyPaneStatusDidChange, object: nil, queue: .main
        ) { note in
            // attach/markAllRead 这类无 pane 的全量通知不算报文，只数带 pane 的定向通知
            guard let id = PaneStatusStore.paneID(from: note) else { return }
            perPaneCount[id, default: 0] += 1
            received.fulfill()
        }
        // 不能放进 defer：defer 后进先出，detach 那个 defer 会先跑、发 50 次定向通知，
        // 打到已经满额的 expectation 上就是 API violation。wait 完立刻显式摘掉。

        // 空转基线：绑定后不发东西，看接收端 CPU 是否为零
        var r0 = rusage(); getrusage(RUSAGE_SELF, &r0)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0))
        var r1 = rusage(); getrusage(RUSAGE_SELF, &r1)
        let idleCPU = cpuSeconds(r1) - cpuSeconds(r0)

        // 50 个 pane 各自在自己的并发队列上顺序发 20 发——模拟 50 个 agent 同时在跑。
        // 真实 pane 在 PaneView.init 里一定会 attach，store 也只认已 attach 的 pane，
        // 不 attach 就是在测一个现实中不存在的场景。
        let ids = (0..<panes).map { _ in UUID() }
        ids.forEach { store.attach($0) }
        defer { ids.forEach { store.detach($0) } }
        let group = DispatchGroup()
        let wall0 = Date()
        for id in ids {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                for _ in 0..<perPane { try? self.fire(pane: id, event: "PreToolUse") }
                group.leave()
            }
        }
        group.wait()
        let sendWall = Date().timeIntervalSince(wall0)

        wait(for: [received], timeout: 30)
        NotificationCenter.default.removeObserver(observer)
        var r2 = rusage(); getrusage(RUSAGE_SELF, &r2)
        // 注意：这个进程既是接收方也是 spawn 1000 个子进程的发起方，
        // 下面的 CPU 数含 spawn 开销，是接收成本的**上界**。
        let busyCPU = cpuSeconds(r2) - cpuSeconds(r1)

        let got = perPaneCount.values.reduce(0, +)
        print("""

            ===== 压测结果 =====
            \(panes) 个 pane 并发 × \(perPane) 发 = \(total) 条真 hook 调用
            发送耗时 \(String(format: "%.2f", sendWall))s → \(Int(Double(total) / sendWall)) 条/秒（含进程 spawn）
            接收: \(got)/\(total)，每个 pane 都收满: \(perPaneCount.values.allSatisfy { $0 == perPane })
            空转 1s 接收端 CPU: \(String(format: "%.1f", idleCPU * 1000)) ms
            压测期间本进程 CPU: \(String(format: "%.0f", busyCPU * 1000)) ms（含 spawn，上界）
            ====================

            """)
        XCTAssertEqual(got, total, "有报文丢失")
        XCTAssertTrue(perPaneCount.values.allSatisfy { $0 == perPane }, "某些 pane 没收满")
        XCTAssertLessThan(idleCPU, 0.01, "空转时接收端不该有 CPU 消耗")
    }

    private func cpuSeconds(_ r: rusage) -> Double {
        Double(r.ru_utime.tv_sec) + Double(r.ru_utime.tv_usec) / 1e6
            + Double(r.ru_stime.tv_sec) + Double(r.ru_stime.tv_usec) / 1e6
    }
}
