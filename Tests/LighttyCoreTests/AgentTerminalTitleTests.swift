import XCTest
@testable import LighttyCore

/// 两家写进终端标题的形状。一张表：每个前缀的含义，以及所有不该认的形状——
/// 认错一个就是让 shell 或 vim 的标题去改 agent 的状态。
final class AgentTerminalTitleTests: XCTestCase {
    func testClaudeTitlesParseOnlyWithTheirPrefix() {
        let shape = SessionAgent.claude.spec.terminalTitle
        let cases: [(title: String, expected: AgentTerminalTitle?)] = [
            ("◐ Shopify 公司介绍", .init(phase: .busy, body: "Shopify 公司介绍")),
            ("◑ Shopify 公司介绍", .init(phase: .busy, body: "Shopify 公司介绍")),
            ("✳ Shopify 公司介绍", .init(phase: .settled, body: "Shopify 公司介绍")),
            // 刚启动、还没有标题时也会写前缀
            ("✳", .init(phase: .settled, body: "")),
            ("  ◐  padded  ", .init(phase: .busy, body: "padded")),
            // 前缀后面必须是空格：这是别的程序碰巧以同一个字符开头
            ("✳foo", nil),
            // Claude 总带前缀，没前缀的标题不是它写的（比如 Ctrl-Z 之后 shell 写的）
            ("florian@mac: ~", nil),
            ("vim src/main.swift", nil),
            ("", nil),
            // Claude Code 的状态圆点 ● 不是标题前缀
            ("● Shopify", nil),
        ]
        for c in cases {
            XCTAssertEqual(AgentTerminalTitle.parse(c.title, shape: shape), c.expected, c.title)
        }
    }

    func testCodexTitlesUseTheSpinnerActionRequiredAndBareShapes() {
        let shape = SessionAgent.codex.spec.terminalTitle
        let cases: [(title: String, expected: AgentTerminalTitle?)] = [
            ("⠋ 回应问候 | florian", .init(phase: .busy, body: "回应问候 | florian")),
            ("⠧ florian", .init(phase: .busy, body: "florian")),
            // 空闲：没有前缀。这种形状证明不了是 Codex 写的（recognizedByPrefix = false）
            ("回应问候 | florian", .init(phase: .settled, body: "回应问候 | florian", recognizedByPrefix: false)),
            // 等用户处理：两种闪烁相位都是同一个状态
            ("[ ! ] Action Required | 回应问候 | florian", .init(phase: .attention, body: "回应问候 | florian")),
            ("[ . ] Action Required | 回应问候 | florian", .init(phase: .attention, body: "回应问候 | florian")),
            ("[ ! ] Action Required", .init(phase: .attention, body: "")),
            // Codex 的形状里「没前缀」就是闲，所以别的程序的标题也会被当成闲——
            // 只在 hook 已登记 agent 且它还活着时才采信，见 PaneStatusStore.noteTerminalTitle
            ("florian@mac: ~", .init(phase: .settled, body: "florian@mac: ~", recognizedByPrefix: false)),
            // 未知符号开头：多半是上游换了旋转字符，认成闲会把正在跑的回合显示成空闲，不认
            ("✦ 回应问候 | florian", nil),
            ("● ⠋ florian", nil),
            ("", nil),
        ]
        for c in cases {
            XCTAssertEqual(AgentTerminalTitle.parse(c.title, shape: shape), c.expected, c.title)
        }
    }
}
