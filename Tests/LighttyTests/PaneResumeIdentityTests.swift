import XCTest
import LighttyCore
@testable import lightty

/// snapshot() 写进快照的 agent 身份判定（纯函数）。核心场景：恢复续接 agent 的 pane
/// 在 hook 尚未发来实时状态（resume 后未交互）时，仍要保住续接身份，否则下次重启丢会话。
final class PaneResumeIdentityTests: XCTestCase {
    private func resolve(status: PaneStatus?, exited: Bool = false,
                         agent: String? = nil, sid: String? = nil, cwd: String? = nil) -> (agent: String?, sessionID: String?, agentCWD: String?, alive: Bool) {
        PaneView.resolveAgentIdentity(status: status, processExited: exited,
                                      resumedAgent: agent, resumedSessionID: sid, resumedAgentCWD: cwd)
    }

    func testFallbackKeepsResumeIdentityWhenNoLiveStatus() {
        let r = resolve(status: nil, exited: false, agent: "codex", sid: "01a07f1e", cwd: "/p")
        XCTAssertEqual(r.agent, "codex")
        XCTAssertEqual(r.sessionID, "01a07f1e")
        XCTAssertEqual(r.agentCWD, "/p")
        XCTAssertTrue(r.alive, "resume 后未交互也应视为会话仍在，供下次续接")
    }

    func testExitedProcessDropsResumeIdentity() {
        let r = resolve(status: nil, exited: true, agent: "codex", sid: "x")
        XCTAssertNil(r.agent, "进程已退出不应续接一个已结束的会话")
        XCTAssertFalse(r.alive)
    }

    func testFreshPaneHasNoIdentity() {
        let r = resolve(status: nil, exited: false)
        XCTAssertNil(r.agent); XCTAssertNil(r.sessionID); XCTAssertFalse(r.alive)
    }

    func testLiveStatusWinsOverFallback() {
        let status = PaneStatus(ts: Date(), state: .thinking, agent: "codex",
                                sessionID: "live-id", cwd: "/live", event: "UserPromptSubmit")
        let r = resolve(status: status, exited: false, agent: "codex", sid: "stale-id", cwd: "/stale")
        XCTAssertEqual(r.sessionID, "live-id", "实时状态优先于兜底身份")
        XCTAssertEqual(r.agentCWD, "/live")
        XCTAssertTrue(r.alive)
    }

    func testSessionEndMarksNotAlive() {
        let status = PaneStatus(ts: Date(), state: .idle, agent: "codex",
                                sessionID: "id", cwd: nil, event: "SessionEnd")
        let r = resolve(status: status, exited: false, agent: "codex", sid: "id")
        XCTAssertFalse(r.alive, "SessionEnd = 用户退出，不再续接")
    }
}
