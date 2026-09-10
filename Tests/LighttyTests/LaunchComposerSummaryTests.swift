import XCTest
@testable import lightty

/// 任务气泡摘要：只认 Next steps 一节，未命中时回退正文开头。
/// 回归背景之一：agent 写的节头不在协议集合里时，有内容的文档显示「暂无摘要」。
/// 回归背景之二：曾经也认 Current state / Blockers，而摘要是「拼起来再截 14 行」，
/// 于是开头的当前状态会把下一步挤出上限——真实任务文件几乎都是这个形状。
final class LaunchComposerSummaryTests: XCTestCase {
    func testKnownSectionsAreExtracted() {
        let body = """
        开场白不该出现
        ## Next steps
        1. 开 MR
        ## 别的节
        不该出现
        """
        let summary = LaunchComposer.summarize(body)
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
        let summary = LaunchComposer.summarize(body)
        XCTAssertTrue(summary.contains("双线落地"))
    }

    /// 真实任务文件的形状：开头是当前状态，下一步在靠后的位置。
    /// 摘要必须只出下一步——这一节是接手的人读的第一句话。
    func testCurrentStateBeforeNextStepsDoesNotCrowdItOut() {
        let body = """
        ## Current state（截至 2026-09-04）
        - 第一阶段已落地
        - 第二阶段评审通过
        - 埋点已上报
        - 灰度 10%
        - 数据看板已接
        - 文档已归档
        - 依赖方已同步
        - 回滚预案已写
        - 压测通过
        - 安全评估通过
        - 合规已过
        - 上线窗口已约

        ## Next steps
        1. 扩量到 50%
        """
        let summary = LaunchComposer.summarize(body)
        XCTAssertTrue(summary.contains("扩量到 50%"))
        XCTAssertFalse(summary.contains("第一阶段已落地"),
                       "当前状态那一节不该进摘要，否则 14 行上限会把下一步挤掉")
    }

    /// 2026-08-30 协议迁英文前写下的任务文件还在用中文节头。
    func testLegacyChineseNextStepsHeadingStillParses() {
        let body = """
        ## 当前状态
        不该出现
        ## 下一步
        1. 补测试
        """
        let summary = LaunchComposer.summarize(body)
        XCTAssertTrue(summary.contains("补测试"))
        XCTAssertFalse(summary.contains("不该出现"))
    }

    func testEmptyBodyShowsPlaceholder() {
        XCTAssertEqual(LaunchComposer.summarize("\n\n"), L("No handoff summary yet"))
    }

    /// 节头后面带日期补充是用户既有文件里的真实写法，所以匹配用 `hasPrefix` 而不是
    /// `==`。收窄到单个节头之后这条没有别的候选兜底，改成等号比较会让摘要整段消失。
    func testHeadingWithABracketedSuffixStillMatches() {
        let body = """
        ## Current state
        不该出现
        ## Next steps（2026-09-04）
        1. 把埋点补齐
        """
        let summary = LaunchComposer.summarize(body)
        XCTAssertTrue(summary.contains("把埋点补齐"), "带括号补充的节头必须还认得出")
        XCTAssertFalse(summary.contains("不该出现"))
    }

    /// 大小写写岔了不该让摘要整段掉进兜底。收窄前有 6 个候选还能互相兜，现在是单点。
    func testHeadingMatchIsCaseInsensitive() {
        let summary = LaunchComposer.summarize("## Next Steps\n1. 写完这条")
        XCTAssertTrue(summary.contains("写完这条"))
    }

    /// 认出了节头、节里却什么都没有——产出的不是空串，是那行标题本身。
    /// 不挡的话气泡里只会显示「## Next steps」五个字，比显示正文开头还差。
    func testAnEmptyNextStepsSectionFallsBackToTheBodyHead() {
        let body = """
        ## Current state
        比价弹窗埋点已经补齐
        ## Next steps

        ## Suggested commands & skills
        - swift test
        """
        let summary = LaunchComposer.summarize(body)
        XCTAssertNotEqual(summary, "## Next steps", "空节不该变成只有一行标题的摘要")
        XCTAssertTrue(summary.contains("比价弹窗埋点已经补齐"), "该退回显示正文开头")
    }
}
