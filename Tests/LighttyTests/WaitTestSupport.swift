import Foundation
import Testing
import XCTest

/// 测试里等异步结果的唯一写法。
///
/// 超时一律结束当前测试，而不是记一条失败后接着往下跑：后面的代码往往默认条件已经
/// 成立，直接按行号取表格行、取 `[0]`，越界是运行时 trap，会让整个测试进程崩掉，
/// 连累后面所有测试。条件一成立立刻返回，超时放宽只影响失败时多等多久。
enum WaitTimeout: Error, CustomStringConvertible {
    case expired(String)
    var description: String {
        switch self { case .expired(let what): "timed out waiting for \(what)" }
    }
}

/// XCTest：用官方的 `XCTestExpectation` + `XCTWaiter` 等待。等待期间主 runloop 在转，
/// 主队列上的回调照常落地；条件在主线程上轮询。
func waitUntil(
    _ description: String, timeout: TimeInterval = 10,
    file: StaticString = #filePath, line: UInt = #line,
    _ condition: @escaping () -> Bool
) throws {
    let expectation = XCTestExpectation(description: description)
    func poll() {
        if condition() {
            // 再让主队列转一拍：状态变化引起的 `Coalescer(.nextTick)` 刷新已经排在队列里，
            // 让它先落地，调用方拿到的才是刷新后的视图（比如表格行）。
            DispatchQueue.main.async { expectation.fulfill() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { poll() }
        }
    }
    poll()
    guard XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed else {
        XCTFail("timed out waiting for \(description)", file: file, line: line)
        throw WaitTimeout.expired(description)
    }
}

/// XCTest：等主队列里**此刻已排队**的块执行完——`Coalescer(.nextTick)` 合流出的刷新、
/// `DispatchQueue.main.async` 投到下一拍的命令、控制器 init 里排的首帧块。主队列先到先执行，
/// 标记块排在它们后面。只覆盖一跳：一跳里再排出的下一跳要再排空一次；`asyncAfter` 的定时块不算。
func drainMainQueue(file: StaticString = #filePath, line: UInt = #line) throws {
    try waitUntil("queued main-queue work", file: file, line: line) { true }
}

/// Swift Testing：异步轮询，超时经 `#require` 记录并结束测试。
@MainActor
func awaitUntil(
    _ comment: Comment, timeout: Duration = .seconds(10),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition(), clock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(condition(), comment, sourceLocation: sourceLocation)
    // 同上：让已排队的下一拍刷新先落地。
    await awaitMainQueue()
}

/// `drainMainQueue` 的挂起版：等此刻已排在主队列里的块执行完。`hops` 是要排空几跳——
/// 一跳里再排出的下一跳（会话库通知合流一拍、收到通知的列表再合流一拍）要多等一跳。
@MainActor
func awaitMainQueue(hops: Int = 1) async {
    for _ in 0..<hops {
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }
}

/// XCTest 的 async 测试用。测试体本身就是主队列上的一个块，`XCTWaiter` 嵌套转事件循环时
/// 主队列里排着的块（合流刷新、下一拍命令）不会执行，只能挂起轮询。和 Swift Testing 那个
/// 同名会让字符串字面量撞上重载，所以另起名字；失败按 XCTest 记录。
@MainActor
func awaitUntilXCTest(
    _ description: String, timeout: TimeInterval = 10,
    file: StaticString = #filePath, line: UInt = #line,
    _ condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    guard condition() else {
        XCTFail("timed out waiting for \(description)", file: file, line: line)
        throw WaitTimeout.expired(description)
    }
    await awaitMainQueue()
}
