import Foundation
import LighttyCore
import Testing
@testable import lightty

/// 界面上的两个 Agent 枚举（启动选择、hook 安装）都从 `SessionAgent` 取描述，
/// 映射是穷举 switch。这里钉住往返和取值，映错一家就是静默失败，所以要测。
struct AgentDescriptionTests {
    /// 加一家 Agent 是「抄一份 `XxxAgent.swift` 再改」，所以最可能的错是**抄完忘了改**
    /// 某个字段——那不是编译错误，是一家 Agent 拿着另一家的可执行名或事件表。
    ///
    /// 用 `Mirror` 逐字段比而不是手写一张表：新加的字段自动进这条断言，
    /// 不必指望加字段的人记得来这里补一行。
    @Test func everySpecFieldIsFilledInAndDiffersBetweenTheAgents() {
        // 合法为空的字段：claude 的原生选择器就是 `claude --resume`，不带尾巴。
        let mayBeEmpty: Set<String> = ["pickerArguments"]
        let claude = Array(Mirror(reflecting: SessionAgent.claude.spec).children)
        let codex = Array(Mirror(reflecting: SessionAgent.codex.spec).children)
        #expect(claude.count == codex.count)
        #expect(!claude.isEmpty)
        for (left, right) in zip(claude, codex) {
            let field = left.label ?? "?"
            #expect(left.label == right.label)
            let values = [String(describing: left.value), String(describing: right.value)]
            #expect(values[0] != values[1], "\(field)：两家取值一样，多半是抄过去忘了改")
            for value in values where !mayBeEmpty.contains(field) {
                #expect(!["", "[]", "nil"].contains(value), "\(field)：有一家没填")
            }
        }
    }

    @Test func launchChoicesRoundTripThroughTheSessionAgent() {
        for agent in SessionAgent.allCases {
            let launch = LaunchAgent(agent)
            #expect(launch.sessionAgent == agent)
            #expect(launch.program == agent.executableName)
            #expect(launch.title == agent.launchName)
        }
        #expect(LaunchAgent.terminal.sessionAgent == nil)
        #expect(LaunchAgent.terminal.program == "")
        // rawValue 写在用户偏好里，不能因为集中描述而变。
        #expect(LaunchAgent.allCases.map(\.rawValue) == ["claudeCode", "codex", "terminal"])
        #expect(LaunchAgent.allCases.map(\.title) == ["Claude Code", "Codex", L("Terminal only")])
    }

    @Test func hookAgentsRoundTripThroughTheSessionAgent() {
        for agent in SessionAgent.allCases {
            #expect(HookAgent(agent).sessionAgent == agent)
            #expect(HookAgent(agent).executableName == agent.executableName)
        }
        #expect(HookAgent.allCases.map(\.rawValue) == ["claudeCode", "codex"])
    }

    /// hook 侧解析配置目录只走 `SessionConfigurationLocation`；空字符串覆盖按没设处理
    /// （既有行为），会话侧则保留为显式自定义根。
    @Test func hookConfigurationDirectoryUsesTheSharedResolution() {
        let home = URL(fileURLWithPath: "/fixture/home")
        for hook in HookAgent.allCases {
            let agent = hook.sessionAgent
            let variable = agent.configurationVariable
            #expect(hook.configDirectory(environment: [:], home: home).path
                == "/fixture/home/" + agent.standardConfigurationDirectory)
            #expect(hook.configDirectory(environment: [variable: ""], home: home).path
                == "/fixture/home/" + agent.standardConfigurationDirectory)
            #expect(hook.configDirectory(environment: [variable: "/custom/root"], home: home).path == "/custom/root")
            #expect(SessionConfigurationLocation.resolve(agent: agent, environment: [variable: ""]) == .custom(""))
        }
    }
}
