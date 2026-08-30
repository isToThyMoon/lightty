import XCTest
@testable import lightty

/// 任务气泡摘要：协议节头优先，未命中时回退正文开头。
/// 回归背景：agent 写的节头不在协议集合里时，有内容的文档显示「暂无摘要」。
final class RestoreFlowSummaryTests: XCTestCase {
    func testKnownSectionsAreExtracted() {
        let body = """
        开场白不该出现
        ## Next steps
        1. 开 MR
        ## 别的节
        不该出现
        """
        let summary = RestoreFlow.summarize(body)
        XCTAssertTrue(summary.contains("开 MR"))
        XCTAssertFalse(summary.contains("开场白"))
        XCTAssertFalse(summary.contains("不该出现"))
    }

    func testFallsBackToBodyHeadWhenNoKnownSections() {
        let body = """
        项目已完成第一阶段，双线落地。

        ## 实现记录
        - 新增组件若干
        """
        let summary = RestoreFlow.summarize(body)
        XCTAssertTrue(summary.contains("双线落地"))
    }

    func testEmptyBodyShowsPlaceholder() {
        XCTAssertEqual(RestoreFlow.summarize("\n\n"), L("No handoff summary yet"))
    }
}
