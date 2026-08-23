import XCTest
@testable import LighttyCore

final class TaskFolderWatcherTests: XCTestCase {

    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lightty-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// 轮询等待条件成立，避免固定 sleep 的脆弱
    func wait(upTo seconds: TimeInterval, for condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func testDebouncedSingleCallbackForBurst() throws {
        let counter = Counter()
        let watcher = try TaskFolderWatcher(directory: dir, debounce: 0.15) { counter.increment() }
        defer { watcher.cancel() }
        // 短时间内多次变更 → 防抖合并为一次回调
        for i in 0..<5 {
            try Data("x".utf8).write(to: dir.appendingPathComponent("f\(i).md"))
        }
        wait(upTo: 2) { counter.value >= 1 }
        // 再等一个防抖窗口，确认没有多余回调
        wait(upTo: 0.5) { false }
        XCTAssertEqual(counter.value, 1)
    }

    func testFiresAgainForLaterChange() throws {
        let counter = Counter()
        let watcher = try TaskFolderWatcher(directory: dir, debounce: 0.05) { counter.increment() }
        defer { watcher.cancel() }
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.md"))
        wait(upTo: 2) { counter.value >= 1 }
        XCTAssertEqual(counter.value, 1)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("a.md"))
        wait(upTo: 2) { counter.value >= 2 }
        XCTAssertEqual(counter.value, 2)
    }

    func testInitFailsOnMissingDirectory() {
        let missing = dir.appendingPathComponent("不存在")
        XCTAssertThrowsError(try TaskFolderWatcher(directory: missing, debounce: 0.05) {})
    }
}

/// 线程安全计数器（回调在 watcher 内部队列触发）
final class Counter {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func increment() { lock.lock(); n += 1; lock.unlock() }
}
