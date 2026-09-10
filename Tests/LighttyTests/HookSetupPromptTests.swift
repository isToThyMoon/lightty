import XCTest

@testable import lightty

/// 「启动时要不要提醒装/更新插件」这一条判断。
///
/// 它错过一次：原来对 `.installed` 一律不提醒，注释写着「无事可做」——那句话在
/// 插件只有 hooks 的时候成立，加了交接技能之后不成立了。两家 CLI 都是**安装时
/// 拷贝**插件，旧缓存里没有 `skills/` 目录，而调用名不认识时两家都**静默失败**：
/// 用户什么都看不到，只会发现按钮退回了往终端里贴一整段文字。
final class HookSetupPromptTests: XCTestCase {
    private func report(_ agent: HookAgent, state: HookInstaller.State,
                        needsUpdate: Bool = false, version: String = "0.1.0+aaaa",
                        agentPresent: Bool = true) -> HookInstaller.Report {
        HookInstaller.Report(
            agent: agent, isAgentPresent: agentPresent, executablePath: agentPresent ? "/usr/bin/x" : nil,
            state: state, needsUpdate: needsUpdate, version: version)
    }

    private func shouldPresent(_ reports: [HookInstaller.Report],
                               setupDismissed: Bool = false,
                               dismissedUpdate: [HookAgent: String] = [:]) -> Bool {
        HookSetupOverlay.shouldPresent(
            reports: reports, setupDismissed: setupDismissed,
            dismissedUpdateVersion: { dismissedUpdate[$0] })
    }

    /// 这条守的就是回归本身：装好了、但装进去的是旧内容，必须提醒。
    func testStaleInstallIsWorthInterrupting() {
        XCTAssertTrue(shouldPresent([
            report(.claudeCode, state: .installed, needsUpdate: true),
            report(.codex, state: .agentMissing, agentPresent: false),
        ]))
    }

    /// 装好了且是当前内容——没有任何事要做，不该打断。
    func testFreshInstallIsQuiet() {
        XCTAssertFalse(shouldPresent([
            report(.claudeCode, state: .installed, needsUpdate: false),
            report(.codex, state: .installed, needsUpdate: false),
        ]))
    }

    /// 「暂不」只压住当时那个版本。插件内容再变就是一件新事，该再问一次——
    /// 否则用户会在一年前的一次点击上永远失去提醒。
    func testDismissingAnUpdateOnlySilencesThatVersion() {
        let stale = report(.claudeCode, state: .installed, needsUpdate: true, version: "0.1.0+bbbb")
        XCTAssertFalse(shouldPresent([stale], dismissedUpdate: [.claudeCode: "0.1.0+bbbb"]),
            "同一个版本说过暂不，就别再问")
        XCTAssertTrue(shouldPresent([stale], dismissedUpdate: [.claudeCode: "0.1.0+aaaa"]),
            "内容变了是新的一件事，要重新问")
    }

    /// 更新提醒不受「没装那一支」的永久标记影响：那个标记是一次性自我介绍看过了，
    /// 不是「我不想再收到任何插件相关的提示」。
    func testTheOneOffSetupDismissalDoesNotSilenceUpdates() {
        XCTAssertTrue(shouldPresent(
            [report(.claudeCode, state: .installed, needsUpdate: true)], setupDismissed: true))
        XCTAssertFalse(shouldPresent(
            [report(.claudeCode, state: .notInstalled)], setupDismissed: true))
    }

    /// 没装这家 agent 的人看到这个只会困惑——CLI 不在就不提。
    func testMissingAgentIsNeverWorthAsking() {
        XCTAssertFalse(shouldPresent([
            report(.codex, state: .notInstalled, agentPresent: false),
        ]))
    }

    /// 配置读不懂时我们本来也不写（铁律是绝不覆盖），提醒了也没有能点的按钮。
    func testUnreadableConfigIsNotWorthAsking() {
        XCTAssertFalse(shouldPresent([
            report(.claudeCode, state: .unreadable(reason: "bad json"), needsUpdate: true),
        ]))
    }
}
