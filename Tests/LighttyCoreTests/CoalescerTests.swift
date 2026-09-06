import XCTest

@testable import LighttyCore

/// `Coalescer` 替掉的是仓库里 7 处手写的同一件事。它们的语义有细微差别，
/// 这里把三种模式各自的**区别**钉住——搞混了不会编译错，只会在某个高频路径上
/// 悄悄变成「每次都干」或者「永远不干」。
final class CoalescerTests: XCTestCase {
    /// 泵主 runloop，让排进主队列的活真的跑起来。
    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testNextTickRunsOnceNoMatterHowManyRequests() {
        var runs = 0
        let coalescer = Coalescer(.nextTick) { runs += 1 }
        for _ in 0..<50 { coalescer.schedule() }
        XCTAssertEqual(runs, 0, "排队期间不该已经跑了")
        pump(0.05)
        XCTAssertEqual(runs, 1)
        // 跑完之后闩要松开，下一批还能排。
        coalescer.schedule()
        pump(0.05)
        XCTAssertEqual(runs, 2)
    }

    /// `.after` 是**先到先定时**：排队期间的新请求不会把已排好的那次往后推。
    /// 这正是 `PaneNotifier` 想要的——「三个 agent 前后脚收工」并成一条，
    /// 但不能因为一直有新事件就永远不提醒。
    func testAfterDoesNotPostponeAnAlreadyScheduledRun() {
        var runs = 0
        let coalescer = Coalescer(.after(0.15)) { runs += 1 }
        coalescer.schedule()
        pump(0.10)
        coalescer.schedule()  // 还没到点，这一次应当被丢掉，且不推迟原定时刻
        XCTAssertEqual(runs, 0)
        pump(0.10)            // 距第一次 schedule 已 0.2s > 0.15s
        XCTAssertEqual(runs, 1, "新请求不该把已排好的那次往后推")
    }

    /// `.debounce` 相反：每次请求都取消重排，「安静下来才干活」。
    /// 这是 `WorkspaceStore` 存快照要的——用户还在拖窗口就不要写盘。
    func testDebouncePostponesUntilTheRequestsStop() {
        var runs = 0
        let coalescer = Coalescer(.debounce(0.15)) { runs += 1 }
        for _ in 0..<4 {
            coalescer.schedule()
            pump(0.08)        // 每次都在到点前再来一次
        }
        XCTAssertEqual(runs, 0, "请求还没停，不该干活")
        pump(0.25)
        XCTAssertEqual(runs, 1, "停下来之后只干一次")
    }

    func testScheduleOverridesTheDelayForCallersWhoseDelayVaries() {
        var runs = 0
        let coalescer = Coalescer(.debounce(5)) { runs += 1 }
        coalescer.schedule(delay: 0.05)
        pump(0.20)
        XCTAssertEqual(runs, 1, "传进来的延迟要盖过默认值")
    }

    func testCancelDropsAScheduledRun() {
        var runs = 0
        let coalescer = Coalescer(.after(0.05)) { runs += 1 }
        coalescer.schedule()
        XCTAssertTrue(coalescer.isScheduled)
        coalescer.cancel()
        XCTAssertFalse(coalescer.isScheduled)
        pump(0.15)
        XCTAssertEqual(runs, 0)
        // 取消之后闩也要松开，否则后面永远排不上。
        coalescer.schedule()
        pump(0.15)
        XCTAssertEqual(runs, 1)
    }

    /// 拥有者没了就不该再干活——这些合流器都挂在视图和控制器上。
    func testReleasingTheOwnerDropsThePendingRun() {
        var runs = 0
        var coalescer: Coalescer? = Coalescer(.after(0.05)) { runs += 1 }
        coalescer?.schedule()
        coalescer = nil
        pump(0.15)
        XCTAssertEqual(runs, 0)
    }
}
