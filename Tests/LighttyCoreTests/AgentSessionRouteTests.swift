import XCTest

@testable import LighttyCore

/// 会话路由记录：lightty 写、hook 读，是跨可执行文件的约定；
/// 以及路由用到的进程事实读取。
final class AgentSessionRouteTests: XCTestCase {
    private var run: URL!

    override func setUpWithError() throws {
        run = FileManager.default.temporaryDirectory.appendingPathComponent("route-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: run)
    }

    func testRecordRoundTripsAndCanBeRemoved() throws {
        let client = try XCTUnwrap(AgentProcessIdentity.read(getpid()))
        let route = AgentSessionRoute(pane: UUID(), socket: "/tmp/x.sock", client: client)
        try route.write(sessionID: "01a0d992-037e-7f10-8aaa-9452ab2e0c3c", in: run)
        XCTAssertEqual(AgentSessionRoute.read(sessionID: "01a0d992-037e-7f10-8aaa-9452ab2e0c3c", in: run), route)
        AgentSessionRoute.remove(sessionID: "01a0d992-037e-7f10-8aaa-9452ab2e0c3c", in: run)
        XCTAssertNil(AgentSessionRoute.read(sessionID: "01a0d992-037e-7f10-8aaa-9452ab2e0c3c", in: run))
    }

    /// 会话 ID 来自 agent 载荷，拼进路径前必须挡住路径穿越和不像 ID 的值。
    func testSessionIDsThatAreNotPlainIdentifiersHaveNoFile() {
        for bad in ["", "../panes/x", "a/b", ".", "..", "id with space", String(repeating: "a", count: 129), "会话"] {
            XCTAssertNil(AgentSessionRoute.file(for: bad, in: run), bad)
        }
        XCTAssertNotNil(AgentSessionRoute.file(for: "7d3c1e2a-1111-4222-8333-444455556666", in: run))
        XCTAssertNotNil(AgentSessionRoute.file(for: "interrupt_a", in: run))
    }

    /// 写记录的 lightty 或界面进程不在了，记录就作废：hook 不再照它发，清理时删掉。
    func testRecordsFromExitedProcessesAreStale() throws {
        // 活到读完身份再退出：`/usr/bin/true` 可能在读之前就没了
        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/bin/sleep")
        finished.arguments = ["0.2"]
        try finished.run()
        let exited = try XCTUnwrap(AgentProcessIdentity.read(finished.processIdentifier))
        finished.waitUntilExit()

        try AgentSessionRoute(pane: UUID(), socket: "/tmp/x.sock", client: exited).write(sessionID: "gone-client", in: run)
        try AgentSessionRoute(pane: UUID(), socket: "/tmp/x.sock", owner: finished.processIdentifier, client: nil)
            .write(sessionID: "gone-owner", in: run)
        try AgentSessionRoute(pane: UUID(), socket: "/tmp/x.sock", client: nil).write(sessionID: "alive", in: run)
        XCTAssertNil(AgentSessionRoute.read(sessionID: "gone-client", in: run))
        XCTAssertNil(AgentSessionRoute.read(sessionID: "gone-owner", in: run))

        AgentSessionRoute.sweepStale(in: run)
        let left = try FileManager.default.contentsOfDirectory(atPath: AgentSessionRoute.directory(in: run).path)
        XCTAssertEqual(left, ["alive"])
    }

    // MARK: - 进程事实

    /// `KERN_PROCARGS2`：argc、可执行路径、NUL 填充、参数、环境变量，空串结束。
    func testProcargsLayoutIsParsedIntoArgumentsAndEnvironment() throws {
        var bytes = withUnsafeBytes(of: Int32(3)) { Array($0) }
        bytes += Array("/usr/local/bin/codex".utf8) + [0, 0, 0, 0]
        for part in ["codex", "resume", "01a0d992", "LIGHTTY_PANE_ID=ABC", "PATH=/usr/bin:/bin", "EMPTY=", ""] {
            bytes += Array(part.utf8) + [0]
        }
        let launch = try XCTUnwrap(ProcessInspector.parseProcargs(bytes))
        XCTAssertEqual(launch.arguments, ["codex", "resume", "01a0d992"])
        XCTAssertEqual(launch.environment, ["LIGHTTY_PANE_ID": "ABC", "PATH": "/usr/bin:/bin", "EMPTY": ""])
        XCTAssertNil(ProcessInspector.parseProcargs([1, 0]))
    }

    /// 真读自己：参数、环境变量、工作目录都拿得到，而且和本进程看到的一致。
    func testReadsTheCurrentProcess() throws {
        let launch = try XCTUnwrap(ProcessInspector.launch(getpid()))
        XCTAssertEqual(launch.arguments.first, CommandLine.arguments.first)
        XCTAssertEqual(launch.environment["PATH"], ProcessInfo.processInfo.environment["PATH"])
        let cwd = try XCTUnwrap(ProcessInspector.workingDirectory(getpid()))
        XCTAssertEqual(URL(fileURLWithPath: cwd).standardizedFileURL.path,
                       URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.path)
        XCTAssertEqual(ProcessInspector.jobFacts(getpid())?.identity, AgentProcessIdentity.read(getpid()))
        XCTAssertTrue(ProcessInspector.allPIDs().contains(getpid()))
    }
}
