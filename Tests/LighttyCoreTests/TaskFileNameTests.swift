import XCTest
@testable import LighttyCore

final class TaskFileNameTests: XCTestCase {

    func testRemovesSlashAndColon() {
        XCTAssertEqual(TaskFileName.sanitize("a/b:c"), "abc")
    }

    func testCollapsesWhitespaceAndTrims() {
        XCTAssertEqual(TaskFileName.sanitize("  a \t b\u{3000} c  "), "a b c")
    }

    func testSpecExample() {
        XCTAssertEqual(TaskFileName.sanitize("修 a/b: 会话  管理"), "修 ab 会话 管理")
    }

    func testEmptyResultFallsBackToTask() {
        XCTAssertEqual(TaskFileName.sanitize(""), "task")
        XCTAssertEqual(TaskFileName.sanitize(" /: "), "task")
    }

    func testCJKPreserved() {
        XCTAssertEqual(TaskFileName.sanitize("修会话管理方案"), "修会话管理方案")
    }
}
