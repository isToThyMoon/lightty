import XCTest
import LighttyCore
@testable import lightty

/// 端到端：用真实的 `lightty-hook` 二进制验证 handoff 注入的时机与去重。
///
/// 场景就是用户报的那个：先开 agent（SessionStart 时没绑任务），再绑任务，
/// 下一次提问必须补注；之后同会话重复提问不能再注；换任务/改名要重注。
///
/// 目录走真实的 `~/.lightty/panes/<随机 uuid>`（`homeDirectoryForCurrentUser`
/// 不认 `HOME` 覆盖），owner.pid 写本进程，tearDown 销毁——与 PaneStatusStoreTests 同约定。
final class HookHandoffTests: XCTestCase {
    private var paneID: UUID!
    private var taskDir: URL!

    override func setUpWithError() throws {
        paneID = UUID()
        try PaneRuntimeDirectory.create(paneID: paneID.uuidString)
        taskDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lightty-handoff-\(paneID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: hookBinary.path),
            "先 swift build 出 lightty-hook：\(hookBinary.path)")
    }

    override func tearDownWithError() throws {
        PaneRuntimeDirectory.destroy(paneID: paneID.uuidString)
        try? FileManager.default.removeItem(at: taskDir)
    }

    private var hookBinary: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/lightty-hook")
    }

    // MARK: - 工具

    private func writeTask(name: String, body: String) throws -> URL {
        let url = taskDir.appendingPathComponent("\(name).md")
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func bind(_ url: URL?) throws {
        let pointer = PaneRuntimeDirectory.taskPointerFile(for: paneID.uuidString)
        guard let url else {
            try? FileManager.default.removeItem(at: pointer)
            try? FileManager.default.removeItem(
                at: PaneRuntimeDirectory.handoffMarkerFile(for: paneID.uuidString))
            return
        }
        try PaneRuntimeDirectory.atomicWrite(Data((url.path + "\n").utf8), to: pointer)
    }

    /// 跑一发 hook，返回它注入的 additionalContext（没输出 → nil）。
    private func fire(_ event: String, session: String) throws -> String? {
        let p = Process()
        p.executableURL = hookBinary
        p.environment = [
            "LIGHTTY_PANE_ID": paneID.uuidString,
            // 不存在的 socket：sendto 立即 ENOENT，hook 照样往下走
            "LIGHTTY_SOCK": "/tmp/lightty-handoff-test-nonexistent.sock",
            "PATH": "/usr/bin:/bin",
        ]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        try p.run()
        stdin.fileHandleForWriting.write(
            Data(#"{"hook_event_name":"\#(event)","session_id":"\#(session)"}"#.utf8))
        try stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "hook 永远 exit 0")
        guard !out.isEmpty else { return nil }
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: out) as? [String: Any], "输出不是 JSON")
        let specific = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["hookEventName"] as? String, event)
        return specific["additionalContext"] as? String
    }

    // MARK: - 用例

    func testSessionStartInjectsWhenBound() throws {
        let task = try writeTask(name: "alpha", body: "# alpha\n\nNext steps: do A")
        try bind(task)
        let ctx = try XCTUnwrap(try fire("SessionStart", session: "s1"))
        XCTAssertTrue(ctx.contains("do A"))
        XCTAssertTrue(ctx.contains(task.path), "要告诉 agent 回写的绝对路径")
        // 同会话紧接着提问：开场已经注过，不重注
        XCTAssertNil(try fire("UserPromptSubmit", session: "s1"))
    }

    func testLateBindingIsInjectedOnNextPrompt() throws {
        // 先开 agent：此时没绑，开场不注
        XCTAssertNil(try fire("SessionStart", session: "s1"))
        XCTAssertNil(try fire("UserPromptSubmit", session: "s1"))

        // 再绑任务（bind / 新建 task 走的是同一条 syncTaskPointer）
        let task = try writeTask(name: "beta", body: "# beta\n\nNext steps: do B")
        try bind(task)
        let ctx = try XCTUnwrap(try fire("UserPromptSubmit", session: "s1"), "绑定后下一次提问必须补注")
        XCTAssertTrue(ctx.contains("do B"))
        XCTAssertTrue(ctx.contains("has just been bound"), "晚绑定的开场白要说明这是新绑的")

        // 之后同会话重复提问：只注一次
        XCTAssertNil(try fire("UserPromptSubmit", session: "s1"))
        XCTAssertNil(try fire("UserPromptSubmit", session: "s1"))
    }

    func testRebindAndRenameReinject() throws {
        let a = try writeTask(name: "a", body: "task A")
        try bind(a)
        XCTAssertNotNil(try fire("UserPromptSubmit", session: "s1"))

        // 换绑另一个任务 → 重注
        let b = try writeTask(name: "b", body: "task B")
        try bind(b)
        let ctxB = try XCTUnwrap(try fire("UserPromptSubmit", session: "s1"))
        XCTAssertTrue(ctxB.contains("task B"))

        // 改名（路径变）→ 重注，agent 需要新的回写地址
        let renamed = taskDir.appendingPathComponent("b-renamed.md")
        try FileManager.default.moveItem(at: b, to: renamed)
        try bind(renamed)
        let ctxR = try XCTUnwrap(try fire("UserPromptSubmit", session: "s1"))
        XCTAssertTrue(ctxR.contains(renamed.path))
        XCTAssertNil(try fire("UserPromptSubmit", session: "s1"))
    }

    func testNewSessionReinjectsSamePath() throws {
        let task = try writeTask(name: "gamma", body: "task G")
        try bind(task)
        XCTAssertNotNil(try fire("SessionStart", session: "s1"))
        // 用户退出 agent 再开一个：新会话开场必须再注，不受上次标记影响
        XCTAssertNotNil(try fire("SessionStart", session: "s2"))
        XCTAssertNil(try fire("UserPromptSubmit", session: "s2"))
    }

    func testUnbindThenRebindSameTaskReinjects() throws {
        let task = try writeTask(name: "delta", body: "task D")
        try bind(task)
        XCTAssertNotNil(try fire("UserPromptSubmit", session: "s1"))
        // 解绑：lightty 会连去重标记一起删（这里模拟 syncTaskPointer 的行为）
        try bind(nil)
        XCTAssertNil(try fire("UserPromptSubmit", session: "s1"), "没绑就不注")
        try bind(task)
        XCTAssertNotNil(try fire("UserPromptSubmit", session: "s1"), "绑回同一任务要重注")
    }

    func testOtherEventsNeverInject() throws {
        let task = try writeTask(name: "eps", body: "task E")
        try bind(task)
        for event in ["PreToolUse", "PostToolUse", "Stop", "SessionEnd"] {
            XCTAssertNil(try fire(event, session: "s1"), "\(event) 不该有输出")
        }
    }
}
