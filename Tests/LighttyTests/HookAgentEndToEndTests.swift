import XCTest
import LighttyCore
@testable import lightty

/// 端到端：真实 `lightty-hook` 二进制 + 真实 store socket，验证 agent 判定用的是
/// 父进程链而不是环境变量。复现的是用户报的场景：Codex 的 hook 环境里没有任何
/// CODEX_* 变量、载荷带 Claude 同款 transcript_path，之前一律被认成 claude，
/// 重开 app 时生成 `claude --resume <codex id>`，Codex 会话恢复不了。
final class HookAgentEndToEndTests: XCTestCase {
    private var store: PaneStatusStore!
    private var socketPath: URL!
    private var wrapperDir: URL!

    override func setUpWithError() throws {
        socketPath = URL(fileURLWithPath: "/tmp/lightty-agent-\(getpid()).sock")  // sun_path 104 字节上限，别用 NSTemporaryDirectory
        store = PaneStatusStore(socketPath: socketPath)
        XCTAssertTrue(store.start(), "store 没能绑定 \(socketPath.path)")
        wrapperDir = FileManager.default.temporaryDirectory.appendingPathComponent("lightty-agent-wrappers-\(getpid())")
        try FileManager.default.createDirectory(at: wrapperDir, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: hookBinary.path), "先 swift build 出 lightty-hook：\(hookBinary.path)")
    }

    override func tearDownWithError() throws {
        store?.stop()
        if let socketPath { try? FileManager.default.removeItem(at: socketPath) }
        if let wrapperDir { try? FileManager.default.removeItem(at: wrapperDir) }
    }

    private var hookBinary: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/lightty-hook")
    }

    /// 编一个 fork + `execv(argv[1], argv + 1)` 的小程序，起成指定名字，让 hook 的父进程链上
    /// 出现一个叫这个名字的可执行文件。不能拿 /bin/zsh 复制改名：平台二进制拷出
    /// 系统卷会被直接 SIGKILL。没有 cc 的机器跳过这组用例。
    private func wrapper(named name: String) throws -> URL {
        let url = wrapperDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let source = wrapperDir.appendingPathComponent("exec-wrapper.c")
        // 必须 fork 出子进程再 exec：直接 exec 会用 hook 换掉本进程映像，
        // 父进程链上就不再有这个名字了。真实 agent 也是 spawn 子进程跑 hook。
        try """
        #include <unistd.h>
        #include <sys/wait.h>
        int main(int argc, char **argv) {
            if (argc < 2) return 2;
            pid_t child = fork();
            if (child == 0) { execv(argv[1], argv + 1); _exit(127); }
            int status = 0;
            waitpid(child, &status, 0);
            return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let cc = Process()
        cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        cc.arguments = ["-O0", "-o", url.path, source.path]
        cc.standardOutput = FileHandle.nullDevice
        cc.standardError = FileHandle.nullDevice
        do { try cc.run() } catch { throw XCTSkip("没有 cc，跳过父进程链端到端用例") }
        cc.waitUntilExit()
        guard cc.terminationStatus == 0 else { throw XCTSkip("cc 编译失败，跳过父进程链端到端用例") }
        return url
    }

    /// 经假 `<parent>` 拉起 hook（parent → hook，和 agent 直接 spawn 或经 shell spawn 同构），
    /// 等 store 收到这一 pane 的报文，返回它记下的 agent。
    private func agentReported(parent: String, payload: String, environment: [String: String] = [:]) throws -> String? {
        let pane = UUID()
        store.attach(pane)  // store 只收登记过的 pane；attach 会建运行时目录，detach 负责清
        defer { store.detach(pane) }
        let received = expectation(description: "datagram for \(pane)")
        var didReceive = false
        let observer = NotificationCenter.default.addObserver(forName: .lighttyPaneStatusDidChange, object: nil, queue: .main) { note in
            if PaneStatusStore.paneID(from: note) == pane, !didReceive {
                didReceive = true
                received.fulfill()
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let p = Process()
        p.executableURL = try wrapper(named: parent)
        p.arguments = [hookBinary.path]
        var env = ["LIGHTTY_PANE_ID": pane.uuidString, "LIGHTTY_SOCK": socketPath.path, "PATH": "/usr/bin:/bin"]
        env.merge(environment) { _, new in new }
        p.environment = env
        let stdin = Pipe()
        p.standardInput = stdin
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        stdin.fileHandleForWriting.write(Data(payload.utf8))
        try stdin.fileHandleForWriting.close()
        p.waitUntilExit()
        wait(for: [received], timeout: 5)
        XCTAssertEqual(p.terminationStatus, 0, "hook 应静默退出 0")
        XCTAssertEqual(store.status(for: pane)?.agentProcess?.pid, p.processIdentifier,
                       "The hook must identify its Agent parent, not the hook subprocess")
        if let agentName = store.status(for: pane)?.agent, let agent = SessionAgent(rawValue: agentName) {
            let expectedRoot = SessionConfigurationLocation.resolve(agent: agent, environment: env)
                .root(for: agent, home: FileManager.default.homeDirectoryForCurrentUser).standardizedFileURL.path
            XCTAssertEqual(store.status(for: pane)?.sourceRoot, expectedRoot)
        }
        return store.status(for: pane)?.agent
    }

    func testCodexParentWithoutEnvironmentHintsIsReportedAsCodex() throws {
        let payload = #"{"hook_event_name":"PreToolUse","session_id":"01a07e9f-e508-7940-a848-240e00170c7f","transcript_path":"/Users/u/.codex/sessions/2026/09/07/rollout-2026-09-07T18-26-43-01a07e9f.jsonl","tool_name":"shell","cwd":"/tmp"}"#
        XCTAssertEqual(try agentReported(parent: "codex", payload: payload), "codex")
    }

    func testCodexParentBeatsLeakedClaudeEnvironment() throws {
        let payload = #"{"hook_event_name":"UserPromptSubmit","session_id":"01a07e9f-e508-7940-a848-240e00170c7f","cwd":"/tmp"}"#
        XCTAssertEqual(try agentReported(parent: "codex", payload: payload, environment: ["CLAUDECODE": "1"]), "codex")
    }

    func testClaudeParentIsReportedAsClaude() throws {
        let payload = #"{"hook_event_name":"PreToolUse","session_id":"7d3c1e2a-1111-4222-8333-444455556666","transcript_path":"/Users/u/.claude/projects/-Users-u-p/7d3c1e2a.jsonl","tool_name":"Edit","cwd":"/tmp"}"#
        XCTAssertEqual(try agentReported(parent: "claude", payload: payload), "claude")
    }

}
