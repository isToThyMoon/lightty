import XCTest

@testable import LighttyCore

/// 交接协议是「一处真值、四处取用」。这里钉的不是文案好不好，是那个结构：
/// 四处取用的写作规矩必须逐字相同，两版注入必须只在开头不同，路径必须出现在
/// agent 真的会读到的地方。这些性质坏掉都不会编译错——只会让某一处悄悄跟
/// 另外两处说得不一样。
final class HandoffProtocolTests: XCTestCase {
    private let path = "/Users/me/.lightty/tasks/修会话管理.md"
    private let body = "---\nname: 修会话管理\nupdated: 2026-09-09T00:00:00Z\n---\n## Next steps\n- 接着写\n"

    /// 「To update it:」往后两版必须一个字都不差。两版的差别是有意的，但只该在
    /// 开头那两段——写作规矩在中途绑定那版里被改一个字，就等于同一个 agent
    /// 在一段会话里收到过两套规矩。
    func testTheTwoInjectionsDifferOnlyInTheirOpening() {
        let start = HandoffProtocol.injection(path: path, body: body, lateBinding: false)
        let late = HandoffProtocol.injection(path: path, body: body, lateBinding: true)

        guard let startTail = start.range(of: "When asked to update it:"),
            let lateTail = late.range(of: "When asked to update it:")
        else { return XCTFail("两版注入都该有「When asked to update it:」这一段") }

        XCTAssertEqual(String(start[startTail.lowerBound...]), String(late[lateTail.lowerBound...]),
            "开头之后的部分必须逐字相同")
        XCTAssertNotEqual(String(start[..<startTail.lowerBound]), String(late[..<lateTail.lowerBound]),
            "开头必须不同：中途绑定要交代优先级和取代关系，开场不需要")
    }

    /// 中途绑定那版要说清两件开场版不必说的事。这两句是 2026-09-09 补的，
    /// 缺了就会出现「跟用户当前那句话抢优先级」和「同一份文档两个版本并存」。
    func testTheLateBindingOpeningCarriesPriorityAndSupersession() {
        let late = HandoffProtocol.injection(path: path, body: body, lateBinding: true)
        XCTAssertTrue(late.contains("Handle the user's current request first"),
            "中途绑定时用户刚说过话，得交代谁在前")
        XCTAssertTrue(late.contains("replaces any earlier copy"),
            "改名会换路径，同一份文档的两个版本会先后进同一段上下文")

        let start = HandoffProtocol.injection(path: path, body: body, lateBinding: false)
        XCTAssertFalse(start.contains("Handle the user's current request first"),
            "开场时上下文是空的，没有要让路的请求")
    }

    /// 路径要出现两次：一次说明这份文档是谁，一次告诉它往哪写。
    /// 只留一处曾经被当成「去重」砍掉过——路径是整段文本里唯一不可推导的事实，
    /// 省那几个词不划算。
    func testThePathAppearsBothAsIdentityAndAsWriteTarget() {
        for lateBinding in [false, true] {
            let text = HandoffProtocol.injection(path: path, body: body, lateBinding: lateBinding)
            XCTAssertTrue(text.contains("kept at `\(path)`"), "开头要说明这份文档存在哪儿")
            XCTAssertTrue(text.contains("mv it over `\(path)`"), "写回目标要给绝对路径")
        }
    }

    /// 注入的是任务文件全文，含 frontmatter：「只重写 frontmatter 结束的 `---`
    /// 之后」这条指令得让 agent 对着实物看。截掉 frontmatter 会让它引用一个
    /// 看不见的东西。
    func testTheDocumentIsInjectedWholeIncludingFrontmatter() {
        let text = HandoffProtocol.injection(path: path, body: body, lateBinding: false)
        guard let begin = text.range(of: "----- BEGIN HANDOFF DOCUMENT -----\n"),
            let end = text.range(of: "\n----- END HANDOFF DOCUMENT -----")
        else { return XCTFail("缺少文档分隔标记") }
        XCTAssertEqual(String(text[begin.upperBound..<end.lowerBound]), body,
            "标记之间必须是任务文件原文，一个字节都不改")
    }

    /// 单一真值的回归防线：写作规矩在四处取用里必须逐字出现。任何一处被就地
    /// 改写（哪怕只是「顺手润色一下」），这条就红。
    func testEveryConsumerCarriesTheWritingRulesVerbatim() {
        let consumers: [(String, String)] = [
            ("开场注入", HandoffProtocol.injection(path: path, body: body, lateBinding: false)),
            ("中途绑定注入", HandoffProtocol.injection(path: path, body: body, lateBinding: true)),
            ("SKILL.md", HandoffProtocol.skillDocument),
            ("没装插件时的整段指令", HandoffProtocol.directInstruction(path: path)),
        ]
        for (name, text) in consumers {
            XCTAssertTrue(text.contains(HandoffProtocol.writingRules), "\(name) 里的写作规矩被改写了")
        }
    }

    /// 机械契约同理。技能那份拿不到路径，说的是「the target」，所以按目标分两组比。
    func testEveryConsumerCarriesTheUpdateRulesVerbatim() {
        let withPath = HandoffProtocol.updateRules(target: "`\(path)`")
        for lateBinding in [false, true] {
            XCTAssertTrue(HandoffProtocol.injection(path: path, body: body, lateBinding: lateBinding)
                .contains(withPath), "注入里的机械契约被改写了")
        }
        XCTAssertTrue(HandoffProtocol.directInstruction(path: path).contains(withPath),
            "整段指令里的机械契约被改写了")
        XCTAssertTrue(HandoffProtocol.skillDocument.contains(HandoffProtocol.updateRules(target: "the target")),
            "SKILL.md 里的机械契约被改写了")
    }

    /// 临时文件必须以点开头。任务扫描按 `!hasPrefix(".") && hasSuffix(".md")` 收文件，
    /// 少了这条约束，agent 起名 `tmp.md` 就会凭空多出一个任务；写到一半失败还会
    /// 永久留在侧栏里。
    func testTheTempFileRuleForbidsAScannableName() {
        XCTAssertTrue(HandoffProtocol.updateRules(target: "x").contains("named with a leading dot"),
            "临时文件不带前导点会被任务扫描当成新任务")
    }

    /// SKILL.md 的 frontmatter 必须每个键单行。折行的 YAML 标量虽然合法，但两家
    /// CLI 的 frontmatter 解析器是不是都按 YAML 折行没验过；单行零成本。
    func testTheSkillFrontmatterKeepsEveryKeyOnOneLine() {
        let lines = HandoffProtocol.skillDocument.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") else {
            return XCTFail("SKILL.md 必须以 frontmatter 开头")
        }
        for line in lines[1..<close] {
            XCTAssertFalse(line.hasPrefix(" ") || line.hasPrefix("\t"),
                "「\(line)」是折行的续行，description 必须写成一行")
            XCTAssertTrue(line.contains(": "), "frontmatter 每行都是 `键: 值`")
        }
    }

    /// 两家调起技能的写法不一样，实测得来：Claude Code 用 `/`，Codex 用 `$`，
    /// 都按插件名加前缀。写错不报错、什么都不会发生，所以这条只能靠测试守。
    func testEachAgentGetsItsOwnInvocationSigil() {
        XCTAssertEqual(
            HandoffProtocol.skillInvocation(agent: .claude, plugin: "lightty", path: "/t/a.md"),
            "/lightty:handoff /t/a.md")
        XCTAssertEqual(
            HandoffProtocol.skillInvocation(agent: .codex, plugin: "lightty", path: "/t/a.md"),
            "$lightty:handoff /t/a.md")
    }

    /// 路径必须跟着调用一起发。技能正文说「路径在绑定时给过你」，而那个路径只活在
    /// 开场那次注入里——长会话压缩掉它之后，不带路径的调用就什么都写不成，而且
    /// 恰好死在技能路本该最有优势的场景。调用方手里有路径，不发是白丢。
    func testTheInvocationCarriesThePath() {
        let path = "/Users/me/.lightty/tasks/重构启动浮层.md"
        for agent in [SessionAgent.claude, .codex] {
            XCTAssertTrue(
                HandoffProtocol.skillInvocation(agent: agent, plugin: "lightty", path: path)
                    .hasSuffix(" \(path)"),
                "\(agent) 的调用串没带上路径")
        }
    }

    /// `path: nil` 是给人看的裸写法——设置页展示它，用户手敲不必背一长串路径。
    /// 多一个尾随空格都不行：那是要被复制粘贴进终端的。
    func testTheBareInvocationCarriesNoPath() {
        for agent in [SessionAgent.claude, .codex] {
            let bare = HandoffProtocol.skillInvocation(agent: agent, plugin: "lightty", path: nil)
            XCTAssertTrue(bare.hasSuffix(":\(HandoffProtocol.skillName)"), "裸写法后面不该跟东西")
            XCTAssertEqual(bare, bare.trimmingCharacters(in: .whitespaces))
        }
    }

    /// 技能可能在没有注入过的会话里被自然语言调起，那时调用串上也没有路径参数。
    /// 正文必须给出一条不靠猜的恢复途径，否则这条路只能停下来。
    func testTheSkillTellsHowToRecoverThePathWithoutAnArgument() {
        XCTAssertTrue(HandoffProtocol.skillDocument.contains("$LIGHTTY_PANE_ID"),
            "技能正文没告诉 agent 去哪儿找回路径")
    }

    /// 文本一律用正面陈述：禁令会把被禁的行为拽进上下文，反而更容易发生。
    /// 这条守的是「后来有人顺手加一句 don't …」——评审抓到过一次，只能靠测试挡。
    func testNoConsumerSteersByProhibition() {
        let banned = ["do not ", "don't ", "never ", "rather than guessing"]
        for (name, text) in HandoffProtocolTests.consumers {
            for phrase in banned {
                XCTAssertFalse(text.lowercased().contains(phrase),
                    "\(name) 里出现了禁令式表述「\(phrase)」")
            }
        }
    }

    /// 只有两个约定节头进提示词，其余三个降级成建议、只出现在「自带全部契约」
    /// 的那两支里。注入里偷偷塞回节头模式，就等于把刚拆掉的五节模式装回去。
    func testTheInjectionCarriesOnlyTheTwoAnchors() {
        let injected = HandoffProtocol.injection(path: "/t/a.md", body: "", lateBinding: false)
        XCTAssertTrue(injected.contains("## Next steps"))
        XCTAssertTrue(injected.contains("## Suggested commands & skills"))
        for demoted in ["## Current state", "## Key decisions & constraints", "## Blockers & risks"] {
            XCTAssertFalse(injected.contains(demoted), "注入里不该出现降级节头 \(demoted)")
        }
    }

    /// `description` 是 YAML 纯量：值里再出现一个 `: ` 就是非法的，而两家 CLI 对
    /// 认不出的技能都是静默失败——不报错，只是这个技能不存在。
    func testTheSkillDescriptionStaysALegalPlainScalar() {
        let line = HandoffProtocol.skillDocument
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.hasPrefix("description: ") }
        let value = try? XCTUnwrap(line).dropFirst("description: ".count)
        XCTAssertNotNil(value)
        XCTAssertFalse(value?.contains(": ") ?? true, "description 的值里有冒号加空格，YAML 读不了")
    }

    /// 取用点清单漏一项，正是这个文件本身要防的漂移。四支都在，才算真的一处真值。
    private static let consumers: [(String, String)] = [
        ("开场注入", HandoffProtocol.injection(path: "/t/a.md", body: "b", lateBinding: false)),
        ("中途绑定注入", HandoffProtocol.injection(path: "/t/a.md", body: "b", lateBinding: true)),
        ("SKILL.md", HandoffProtocol.skillDocument),
        ("整段指令", HandoffProtocol.directInstruction(path: "/t/a.md")),
    ]
}
