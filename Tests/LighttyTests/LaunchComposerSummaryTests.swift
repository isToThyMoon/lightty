import XCTest
@testable import lightty

/// 任务气泡摘要：只认 Next steps 一节，未命中时回退正文开头。
/// 回归背景之一：agent 写的节头不在协议集合里时，有内容的文档显示「暂无摘要」。
/// 回归背景之二：曾经也认 Current state / Blockers，而摘要是「拼起来再截 14 行」，
/// 于是开头的当前状态会把下一步挤出上限——真实任务文件几乎都是这个形状。
final class LaunchComposerSummaryTests: XCTestCase {
    /// 同一个 `summarize(_:)`，只差输入：正文 → 必含 / 必不含 / 恰好等于。
    func testSummaryTakesNextStepsOrFallsBackToTheBodyHead() {
        struct Case {
            let name: String
            let body: String
            var contains: [String] = []
            var excludes: [String] = []
            var equals: String? = nil
        }
        let cases: [Case] = [
            // 只认 Next steps 一节：开场白和别的节都不进摘要。
            Case(name: "known section is extracted",
                 body: """
                 开场白不该出现
                 ## Next steps
                 1. 开 MR
                 ## 别的节
                 不该出现
                 """,
                 contains: ["开 MR"], excludes: ["开场白", "不该出现"]),
            // agent 写的节头不在协议集合里时，有内容的文档曾显示「暂无摘要」——要回退正文开头。
            Case(name: "falls back to body head when no known sections",
                 body: """
                 项目已完成第一阶段，双线落地。

                 ## 实现记录
                 - 新增组件若干
                 """,
                 contains: ["双线落地"]),
            // 真实任务文件的形状：开头是当前状态，下一步在靠后的位置。摘要必须只出下一步——
            // 这一节是接手的人读的第一句话。曾经也认 Current state / Blockers 且「拼起来再截
            // 14 行」，于是开头的当前状态会把下一步挤出上限。
            Case(name: "current state before next steps does not crowd it out",
                 body: """
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
                 """,
                 contains: ["扩量到 50%"], excludes: ["第一阶段已落地"]),
            // 2026-08-30 协议迁英文前写下的任务文件还在用中文节头。
            Case(name: "legacy Chinese next steps heading still parses",
                 body: """
                 ## 当前状态
                 不该出现
                 ## 下一步
                 1. 补测试
                 """,
                 contains: ["补测试"], excludes: ["不该出现"]),
            // 空正文显示占位文案。
            Case(name: "empty body shows placeholder", body: "\n\n", equals: L("No handoff summary yet")),
            // 节头后面带日期补充是用户既有文件里的真实写法，所以匹配用 `hasPrefix` 而不是
            // `==`。收窄到单个节头之后这条没有别的候选兜底，改成等号比较会让摘要整段消失。
            Case(name: "heading with a bracketed suffix still matches",
                 body: """
                 ## Current state
                 不该出现
                 ## Next steps（2026-09-04）
                 1. 把埋点补齐
                 """,
                 contains: ["把埋点补齐"], excludes: ["不该出现"]),
            // 大小写写岔了不该让摘要整段掉进兜底。收窄前有 6 个候选还能互相兜，现在是单点。
            Case(name: "heading match is case insensitive",
                 body: "## Next Steps\n1. 写完这条", contains: ["写完这条"]),
            // 认出了节头、节里却什么都没有——产出的不是空串，是那行标题本身。
            // 不挡的话气泡里只会显示「## Next steps」五个字，比显示正文开头还差；该退回正文开头。
            Case(name: "an empty next steps section falls back to the body head",
                 body: """
                 ## Current state
                 比价弹窗埋点已经补齐
                 ## Next steps

                 ## Suggested commands & skills
                 - swift test
                 """,
                 contains: ["比价弹窗埋点已经补齐"]),
        ]
        for c in cases {
            let summary = LaunchComposer.summarize(c.body)
            for text in c.contains {
                XCTAssertTrue(summary.contains(text), "\(c.name)：摘要里缺「\(text)」：\(summary)")
            }
            for text in c.excludes {
                XCTAssertFalse(summary.contains(text), "\(c.name)：摘要里不该有「\(text)」：\(summary)")
            }
            if let equals = c.equals {
                XCTAssertEqual(summary, equals, c.name)
            }
        }
    }
}
