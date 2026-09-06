import XCTest
@testable import lightty
@testable import LighttyCore

/// 「更新交接文档」敲进终端的那段文字。
///
/// 两条路各有各的失败方式，都不会报错，所以只能靠测试守住：
/// 装了插件却敲错调用写法 → 两家 CLI 都静默无视；没装插件却敲了调用 → 同样静默。
final class AgentCommandHandoffTests: XCTestCase {
    private let path = "/Users/me/.lightty/tasks/重构启动浮层.md"

    private func input(_ agent: SessionAgent, installed: Bool) -> String? {
        AgentCommand.handoff(agent: agent, path: path, skillInstalled: installed).shellInput
    }

    /// 两家的调用写法不同，这是实测出来的：Claude Code 用 `/`，Codex 用 `$`，
    /// 且都按插件名加前缀。写反了不会报错，只会什么都不发生。
    func testEachCLIGetsItsOwnInvocationSyntax() {
        XCTAssertEqual(input(.claude, installed: true), "/lightty:handoff \(path)")
        XCTAssertEqual(input(.codex, installed: true), "$lightty:handoff \(path)")
    }

    /// 前缀必须跟着插件名走，不是写死的字符串——插件改名了这条会跟着变。
    func testInvocationUsesThePluginName() throws {
        let claude = try XCTUnwrap(input(.claude, installed: true))
        XCTAssertEqual(claude, "/\(HookMarketplace.pluginName):\(HandoffProtocol.skillName) \(path)")
    }

    /// 没装插件就不能敲调用（静默失败），改敲自带全部契约的整段指令。
    func testWithoutThePluginItTypesTheWholeInstruction() throws {
        let text = try XCTUnwrap(input(.codex, installed: false))
        XCTAssertFalse(text.hasPrefix("$"), "没装插件还敲调用，等于什么都没做")
        XCTAssertTrue(text.contains(path), "写回地址是这段文字里唯一不可推导的事实")
        // 机械契约三条必须都在：这条路不经过注入，也不经过技能。
        XCTAssertTrue(text.contains("Rewrite only the body after the closing"))
        XCTAssertTrue(text.contains("Refresh `updated`"))
        XCTAssertTrue(text.contains("named with a leading dot"))
        XCTAssertTrue(text.contains("Lead with `## Next steps`"))
    }

    /// 这一支是敲给已经跑起来的 TUI，不是敲给 shell。粘进去的回车不提交，
    /// 提交由 `PaneView.updateHandoff()` 另外按一次回车键完成——所以文本自己
    /// 绝不能带行尾换行，否则那次回车会落在空行上。
    func testNeitherPathEndsWithANewline() throws {
        for installed in [true, false] {
            for agent in SessionAgent.allCases {
                let text = try XCTUnwrap(input(agent, installed: installed))
                XCTAssertFalse(text.hasSuffix("\n"),
                               "\(agent) installed=\(installed) 带了行尾换行")
            }
        }
    }

    /// 整段指令与技能正文同源：写作规矩逐字相同，否则同一件事会有两种说法。
    func testTheDirectInstructionSharesItsWritingRulesWithTheSkill() throws {
        let text = try XCTUnwrap(input(.claude, installed: false))
        XCTAssertTrue(text.contains(HandoffProtocol.writingRules))
        XCTAssertTrue(HandoffProtocol.skillDocument.contains(HandoffProtocol.writingRules))
    }
}
