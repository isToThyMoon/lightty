import AppKit
import LighttyCore
import XCTest

@testable import lightty

/// Agent 是一轮结束**之后**才把标题写进自己目录的，而 lightty 在 `.done` 之后固定
/// 等 1.5 秒拉一次库。赶不上那一次，标题就永远停在「终端 N」——在此之后没有任何
/// 东西会再拉一次。
///
/// 实测输过（2026-09-10，用户机器上同一批起的三段 codex 会话）：向 codex 的
/// app-server 查这三条，`name` 分别是「打个招呼」「问候用户」「回复问候」——**三条
/// 都有标题**，可是第三段的 pane 标题停在「终端 9」。同一批里还看得出更隐蔽的一种
/// 输法：第二段当时显示的是 `preview`（你好）而不是 `name`（问候用户），说明拉库
/// 那一刻 agent 只写了预览、还没写正式名字。
final class SessionTitleLandingTests: XCTestCase {
    private let home = FileManager.default.homeDirectoryForCurrentUser

    private func makeKey(_ agent: SessionAgent = .codex) -> AgentSessionKey {
        AgentSessionKey(agent: agent,
                        sourceRoot: SessionConfigurationLocation.standard.root(for: agent, home: home).path,
                        nativeID: "landing-fixture")
    }

    @MainActor
    private func makePane(key: AgentSessionKey) -> PaneView {
        _ = NSApplication.shared
        if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }
        let pane = PaneView()
        pane.assignWindowNumber(9)
        pane.associateSession(
            PaneSessionAssociation(key: key, configuration: .standard, workingDirectory: home.path))
        return pane
    }

    /// 「标题落没落地」是整条重试的输入。空标题必须报 false——报 true 就等于说
    /// 「成了」，重试永远不会发生，这正是原来那个 bug 的形状。
    @MainActor
    func testAnEmptyRecordTitleCountsAsNotLanded() {
        let key = makeKey()
        let pane = makePane(key: key)
        let blank = [AgentSession(key: key, title: "", workingDirectory: home.path, updatedAt: nil)]
        XCTAssertFalse(pane.refreshSessionTitle(records: blank), "空标题不算落地")
        XCTAssertEqual(pane.header.title, L("Terminal %d", 9), "没落地时标题回到 pane 名")

        let named = [AgentSession(key: key, title: "回复问候", workingDirectory: home.path, updatedAt: nil)]
        XCTAssertTrue(pane.refreshSessionTitle(records: named), "拿到标题就算落地")
        XCTAssertEqual(pane.header.title, "回复问候")
    }

    /// 只有空白字符也不算落地——`refreshSessionTitle` 会把它 trim 成空串。
    @MainActor
    func testAWhitespaceOnlyTitleCountsAsNotLanded() {
        let key = makeKey()
        let pane = makePane(key: key)
        let blank = [AgentSession(key: key, title: "   ", workingDirectory: home.path, updatedAt: nil)]
        XCTAssertFalse(pane.refreshSessionTitle(records: blank))
    }

    /// 库里压根没有这条记录（会话刚起、目录还没落盘）同样不算落地。
    @MainActor
    func testAMissingRecordCountsAsNotLanded() {
        let pane = makePane(key: makeKey())
        XCTAssertFalse(pane.refreshSessionTitle(records: []))
    }

    /// 没有会话的 pane 报 false，但**不该**因此触发重试——标题本来就该是 pane 名。
    /// 这两件事分开：`refreshSessionTitle` 只说落没落地，要不要重试由下面那条决定。
    @MainActor
    func testAPaneWithoutASessionAlsoReportsNotLanded() {
        _ = NSApplication.shared
        if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }
        let pane = PaneView()
        pane.assignWindowNumber(3)
        XCTAssertFalse(pane.refreshSessionTitle(records: []))
        XCTAssertNil(pane.displayedSessionKey)
    }

    // MARK: - 重试本身

    /// 没落地、还有次数 → 再拉一次，次数减一。
    func testNotLandedSchedulesAnotherPull() {
        let next = PaneStatusPresenter.nextTitleWait(landed: false, hasSession: true, attemptsLeft: 5)
        XCTAssertTrue(next.refresh)
        XCTAssertEqual(next.remaining, 4)
    }

    /// 落地了就收手，不留残条。
    func testLandedStopsRetrying() {
        let next = PaneStatusPresenter.nextTitleWait(landed: true, hasSession: true, attemptsLeft: 5)
        XCTAssertFalse(next.refresh)
        XCTAssertNil(next.remaining)
    }

    /// 没有会话不重试：那不是没赶上。
    func testNoSessionNeverRetries() {
        let next = PaneStatusPresenter.nextTitleWait(landed: false, hasSession: false, attemptsLeft: 5)
        XCTAssertFalse(next.refresh)
        XCTAssertNil(next.remaining)
    }

    /// **终止性**。这是这条重试最要紧的性质：`.done` 是粘滞态，而库自己的变更通知
    /// 也会走回同一段代码，少了上限就是永动机。这里把整条循环跑到底，断言它恰好
    /// 拉 `titleAttempts` 次就停，而不是靠读代码相信它会停。
    func testRetryingAlwaysTerminates() {
        var remaining: Int? = PaneStatusPresenter.titleAttempts
        var pulls = 0
        for _ in 0..<1_000 {
            let next = PaneStatusPresenter.nextTitleWait(
                landed: false, hasSession: true, attemptsLeft: remaining)
            remaining = next.remaining
            guard next.refresh else { break }
            pulls += 1
        }
        XCTAssertEqual(pulls, PaneStatusPresenter.titleAttempts, "重试次数必须正好是上限")
        XCTAssertNil(remaining, "用完之后不留残条")
    }
}
