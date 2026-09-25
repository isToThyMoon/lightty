import XCTest
import LighttyCore
@testable import lightty

/// 端到端：真实 `lightty-hook` 二进制 + 真实 store socket。两件事——
///
/// - **哪一家**：命令行里的 `--agent` 是主路径（hooks 文件由我们自己生成，名字写死在里面），
///   没给时才退回载荷里 `transcript_path` 的形状。退路复现的是用户报的场景：Codex 的 hook
///   环境里没有任何 CODEX_* 变量、载荷带 Claude 同款 transcript_path，之前一律被认成 claude，
///   重开 app 时生成 `claude --resume <codex id>`，Codex 会话恢复不了。
/// - **哪个进程、是不是子会话**：只看终端作业结构，不认进程名。`HookLauncher` 用
///   `script -q /dev/null` 造真 pty，把 hook 摆到四种位置上跑真实二进制。
final class HookAgentEndToEndTests: XCTestCase {
    private var store: PaneStatusStore!
    private var socketPath: URL!
    private var scratch: URL!
    private var launcher: HookLauncher!

    override func setUpWithError() throws {
        // sun_path 104 字节上限，别用 NSTemporaryDirectory
        let socketDirectory = URL(fileURLWithPath: "/tmp/lightty-agent-\(getpid())")
        try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: true)
        socketPath = socketDirectory.appendingPathComponent("\(getpid()).sock")
        store = PaneStatusStore(socketPath: socketPath)
        XCTAssertTrue(store.start(), "store 没能绑定 \(socketPath.path)")
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("lightty-agent-\(getpid())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let hook = HookLauncher.builtHookBinary()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: hook.path), "先 swift build 出 lightty-hook：\(hook.path)")
        launcher = HookLauncher(scratch: scratch, hook: hook)
    }

    override func tearDownWithError() throws {
        launcher?.reclaimSpawnedProcesses()
        store?.stop()
        if let socketPath { try? FileManager.default.removeItem(at: socketPath.deletingLastPathComponent()) }
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func hookEnvironment(pane: UUID, extra: [String: String] = [:]) -> [String: String] {
        var env = ["LIGHTTY_PANE_ID": pane.uuidString, "LIGHTTY_SOCK": socketPath.path, "PATH": "/usr/bin:/bin"]
        env.merge(extra) { _, new in new }
        return env
    }

    /// 起一发 hook，等 store 收到这一 pane 的报文，返回它记下的状态与前台作业组长的 pid。
    ///
    /// `route` 给了就先替这段会话写一条路由记录（指向这个 pane），hook 继承的环境则指向
    /// 另一个不相干的 pane——正是 Codex 共享后台进程里的形状：环境属于别的终端，只有记录可信。
    private func statusReported(
        shape: HookLauncher.Shape = .foreground, payload: String, arguments: [String] = [],
        environment: [String: String] = [:], route: (session: String, client: AgentProcessIdentity?)? = nil
    ) throws -> (status: PaneStatus?, leaderPID: pid_t?) {
        let pane = UUID()
        store.attach(pane)  // store 只收登记过的 pane；attach 会建运行时目录，detach 负责清
        defer { store.detach(pane) }
        if let route {
            try AgentSessionRoute(pane: pane, socket: socketPath.path, client: route.client)
                .write(sessionID: route.session)
        }
        defer { if let route { AgentSessionRoute.remove(sessionID: route.session) } }
        let env = hookEnvironment(pane: route == nil ? pane : UUID(), extra: environment)
        let run = try launcher.run(shape, payload: payload, arguments: arguments, environment: env)
        try waitUntil("datagram for \(pane)") { [store] in store?.status(for: pane) != nil }
        if shape == .detached {  // 孤儿进程不在 launcher 手里，得自己等它走干净
            try waitUntil("orphan shell exits") { kill(run.hookParent, 0) != 0 }
        }
        let status = store.status(for: pane)
        if let agentName = status?.agent, let agent = SessionAgent(rawValue: agentName) {
            let expectedRoot = SessionConfigurationLocation.resolve(agent: agent, environment: env)
                .root(for: agent, home: FileManager.default.homeDirectoryForCurrentUser).standardizedFileURL.path
            XCTAssertEqual(status?.sourceRoot, expectedRoot)
        }
        return (status, run.leader)
    }

    private let claudePayload = #"{"hook_event_name":"PreToolUse","session_id":"7d3c1e2a-1111-4222-8333-444455556666","transcript_path":"/Users/u/.claude/projects/-Users-u-p/7d3c1e2a.jsonl","tool_name":"Edit","cwd":"/tmp"}"#
    private let codexPayload = #"{"hook_event_name":"PreToolUse","session_id":"01a07e9f-e508-7940-a848-240e00170c7f","transcript_path":"/Users/u/.codex/sessions/2026/09/07/rollout-2026-09-07T18-26-43-01a07e9f.jsonl","tool_name":"shell","cwd":"/tmp"}"#

    /// 命令行里的 `--agent` 是主路径，压过载荷与环境；没给（旧版插件）才退回 `transcript_path`。
    func testDeclaredAgentWinsAndTheTranscriptPathIsOnlyTheFallback() throws {
        struct Case {
            let name: String
            let environment: [String: String]
            let payload: String
            let arguments: [String]
            let expected: String
        }
        let cases: [Case] = [
            // 载荷与环境都指向 claude，`--agent codex` 仍然说了算：hooks 文件是我们写的，
            // 里面那个名字比任何推断都确定。
            Case(name: "declared codex beats a claude payload and environment",
                 environment: ["CLAUDECODE": "1"], payload: claudePayload,
                 arguments: ["--agent", "codex"], expected: "codex"),
            // 反过来同理，免得「声明优先」只是碰巧在一个方向上成立
            Case(name: "declared claude beats a codex payload and environment",
                 environment: ["CODEX_HOME": "/x"], payload: codexPayload,
                 arguments: ["--agent", "claude"], expected: "claude"),
            // 旧版插件装着的用户：没有 `--agent`，退回 `transcript_path` 的形状。这正是
            // 用户报的场景——Codex 的 hook 环境里一个 CODEX_* 都没有。
            Case(name: "no --agent falls back to the transcript path shape",
                 environment: [:], payload: codexPayload, arguments: [], expected: "codex"),
        ]
        for c in cases {
            let reported = try statusReported(
                payload: c.payload, arguments: c.arguments, environment: c.environment)
            XCTAssertEqual(reported.status?.agent, c.expected, c.name)
        }
    }

    /// 记下的 agent 进程是终端的**前台作业组长**，不是转瞬即逝的 hook、也不是中间那层 shell——
    /// 记错了退出监视就盯着一个早已退出的 pid，会话被当成已结束。
    /// `.wrapped` 那条是 npm 版 codex（node 包装脚本再起原生 codex）：组长是外层包装进程，
    /// 监视它退出与监视里面那个等价。
    func testAgentProcessIsTheForegroundJobLeader() throws {
        for shape in [HookLauncher.Shape.foreground, .wrapped] {
            let reported = try statusReported(
                shape: shape,
                payload: #"{"hook_event_name":"UserPromptSubmit","session_id":"7d3c1e2a-1111-4222-8333-444455556666","cwd":"/tmp"}"#,
                arguments: ["--agent", "claude"])
            XCTAssertEqual(reported.status?.agentProcess?.pid, reported.leaderPID, "\(shape)")
        }
    }

    /// 用户在 Claude Code 里按 Esc 中断了正在跑的工具：`Stop` 不触发，只来一发带 `is_interrupt`
    /// 的 `PostToolUseFailure`，要过真 hook 二进制落成 idle；普通工具失败回合还在继续。
    /// 用无终端形状：pty 里的组长跑完即退，退出监视会把状态改写成 SessionEnd，看不到原样。
    func testInterruptedToolFailureArrivesAsIdle() throws {
        let interrupted = try statusReported(
            shape: .detached,
            payload: #"{"hook_event_name":"PostToolUseFailure","session_id":"s","tool_name":"Bash","error":"interrupted","is_interrupt":true,"cwd":"/tmp"}"#,
            arguments: ["--agent", "claude"])
        XCTAssertEqual(interrupted.status?.state, .idle)
        XCTAssertEqual(interrupted.status?.event, "PostToolUseFailure")
        let failed = try statusReported(
            shape: .detached,
            payload: #"{"hook_event_name":"PostToolUseFailure","session_id":"s","tool_name":"Bash","error":"exit 1","cwd":"/tmp"}"#,
            arguments: ["--agent", "claude"])
        XCTAssertEqual(failed.status?.state, .thinking)
    }

    /// 没有 pty（hook 跑在没有控制终端的环境里）：照发报文，只是没有进程身份。
    /// 宁可多报一发状态，也不能把事件当成子会话丢掉。这是 Claude 的规则，Codex 见下面两条。
    func testWithoutAnyTerminalTheStatusStillArrivesWithoutAProcessIdentity() throws {
        let reported = try statusReported(
            shape: .detached,
            payload: #"{"hook_event_name":"Stop","session_id":"7d3c1e2a-1111-4222-8333-444455556666","cwd":"/tmp"}"#,
            arguments: ["--agent", "claude"])
        XCTAssertEqual(reported.status?.state, .done)
        XCTAssertNil(reported.status?.agentProcess)
    }

    /// Codex 的 hook 不在任何终端里：0.157 被系统收养的共享后台进程就是这个形状，
    /// 继承来的 pane 属于当初拉起后台进程的那个终端，和这段会话无关。没有路由记录就不发，
    /// 否则状态（连同子会话、工具里 `codex exec` 的 SessionStart）会落进那个不相干的 pane。
    func testCodexOutsideAnyTerminalWithoutARouteStaysSilent() throws {
        let pane = UUID()
        store.attach(pane)
        defer { store.detach(pane) }
        let run = try launcher.run(
            .detached, payload: #"{"hook_event_name":"Stop","session_id":"unrouted","cwd":"/tmp"}"#,
            arguments: ["--agent", "codex"], environment: hookEnvironment(pane: pane))
        try waitUntil("orphan shell exits") { kill(run.hookParent, 0) != 0 }
        // hook 退出前就发完了；真发了的话，这段时间足够它到达
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNil(store.status(for: pane))
    }

    /// 同样不在终端里，但 lightty 为这段 Codex 会话写了路由记录：状态送到记录里的 pane，
    /// agent 进程报成记录里的界面进程——而不是继承环境里那个 pane。
    func testRoutedCodexSessionReachesItsPaneFromOutsideAnyTerminal() throws {
        let session = UUID().uuidString
        let client = try XCTUnwrap(AgentProcessIdentity.read(getpid()))
        let reported = try statusReported(
            shape: .detached,
            payload: #"{"hook_event_name":"UserPromptSubmit","session_id":"\#(session)","cwd":"/tmp"}"#,
            arguments: ["--agent", "codex"], route: (session, client))
        XCTAssertEqual(reported.status?.state, .thinking)
        XCTAssertEqual(reported.status?.sessionID, session)
        XCTAssertEqual(reported.status?.agentProcess, client)
    }

    /// 路由记录只给 Codex 用。Claude 的会话哪怕碰上同名记录也照旧按继承的环境走。
    func testClaudeIgnoresSessionRoutes() throws {
        let pane = UUID(), elsewhere = UUID()
        store.attach(pane)
        defer { store.detach(pane) }
        let session = UUID().uuidString
        try AgentSessionRoute(pane: elsewhere, socket: socketPath.path, client: nil).write(sessionID: session)
        defer { AgentSessionRoute.remove(sessionID: session) }
        try launcher.run(payload: #"{"hook_event_name":"UserPromptSubmit","session_id":"\#(session)","cwd":"/tmp"}"#,
                         arguments: ["--agent", "claude"], environment: hookEnvironment(pane: pane))
        try waitUntil("datagram for the inherited pane") { [store] in store?.status(for: pane) != nil }
        XCTAssertEqual(store.status(for: pane)?.sessionID, session)
    }

    /// 主会话工具里拉起的子会话（组长 → 脱离终端的工具 shell → hook）不发状态，
    /// 否则它的 SessionStart / SessionEnd 会顶掉主会话的状态和会话绑定。
    func testSessionLaunchedInsideAnotherSessionStaysSilent() throws {
        let pane = UUID()
        store.attach(pane)
        defer { store.detach(pane) }
        var received: [PaneStatus] = []
        let observer = NotificationCenter.default.addObserver(forName: .lighttyPaneStatusDidChange, object: nil, queue: .main) { [store] note in
            guard PaneStatusStore.paneID(from: note) == pane, let status = store?.status(for: pane) else { return }
            // 同一发报文之后还会因 agent 进程退出再通知一次，只记会话变化
            guard received.last?.sessionID != status.sessionID else { return }
            received.append(status)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let env = hookEnvironment(pane: pane)
        // 报文按发送顺序到达：子会话若发了，一定排在主会话那发前面
        try launcher.run(.nested, payload: #"{"hook_event_name":"SessionStart","session_id":"child","cwd":"/tmp"}"#,
                         arguments: ["--agent", "claude"], environment: env)
        try launcher.run(payload: #"{"hook_event_name":"UserPromptSubmit","session_id":"main","cwd":"/tmp"}"#,
                         arguments: ["--agent", "claude"], environment: env)
        try waitUntil("main session datagram") { received.contains { $0.sessionID == "main" } }
        XCTAssertEqual(received.map(\.sessionID), ["main"])
    }
}
