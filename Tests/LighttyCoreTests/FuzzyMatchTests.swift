import XCTest
@testable import LighttyCore

final class FuzzyMatchTests: XCTestCase {

    func testSubsequenceMatches() {
        XCTAssertNotNil(FuzzyMatch.score(pattern: "tsk", in: "task"))
        XCTAssertNotNil(FuzzyMatch.score(pattern: "会管", in: "会话管理"))
    }

    func testCaseInsensitive() {
        XCTAssertNotNil(FuzzyMatch.score(pattern: "ABC", in: "abc"))
        XCTAssertNotNil(FuzzyMatch.score(pattern: "abc", in: "AxBxC"))
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(FuzzyMatch.score(pattern: "xyz", in: "task"))
        XCTAssertNil(FuzzyMatch.score(pattern: "taskk", in: "task"))
        XCTAssertNil(FuzzyMatch.score(pattern: "ba", in: "ab"))
    }

    func testEmptyPatternMatchesEverything() {
        XCTAssertNotNil(FuzzyMatch.score(pattern: "", in: "anything"))
        XCTAssertNotNil(FuzzyMatch.score(pattern: "", in: ""))
    }

    func testConsecutiveHitsScoreHigher() {
        let dense = FuzzyMatch.score(pattern: "abc", in: "abcxxx")!
        let sparse = FuzzyMatch.score(pattern: "abc", in: "axbxcx")!
        XCTAssertGreaterThan(dense, sparse)
    }

    func testEarlierHitsScoreHigher() {
        let early = FuzzyMatch.score(pattern: "ab", in: "abxx")!
        let late = FuzzyMatch.score(pattern: "ab", in: "xxab")!
        XCTAssertGreaterThan(early, late)
    }

    func testSortingByScore() {
        // 面板排序用法：分数降序
        let candidates = ["会话管理", "任务：会话恢复", "无关任务"]
        let ranked = candidates
            .compactMap { name in FuzzyMatch.score(pattern: "会话", in: name).map { (name, $0) } }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
        XCTAssertEqual(ranked, ["会话管理", "任务：会话恢复"])
    }
}
