import Foundation
import LighttyCore
import Testing
@testable import lightty

/// 界面上的两个 Agent 枚举（启动选择、hook 安装）都从 `SessionAgent` 取描述，
/// 映射是穷举 switch。这里钉住往返和取值，映错一家就是静默失败，所以要测。
struct AgentDescriptionTests {
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
