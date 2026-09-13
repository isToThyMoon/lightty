import Foundation
import LighttyCore
import Testing
@testable import lightty

/// 工具进程的启动参数只在 `AgentHelperProcess` 里拼。这里只断言构造出来的值，不起进程。
struct AgentHelperProcessTests {
    private let helper = URL(fileURLWithPath: "/fixture/helper")

    @Test func nodeRuntimeFollowsTheBuildArchitecture() {
        #if arch(arm64)
        #expect(AgentHelperProcess.nodeRuntime(in: helper).path == "/fixture/helper/runtime-arm64/node")
        #else
        #expect(AgentHelperProcess.nodeRuntime(in: helper).path == "/fixture/helper/runtime-x64/node")
        #endif
    }

    /// SDK helper 不继承 app 环境：pane 路由、用户 PATH、别的配置根都进不来。
    @Test func sdkScriptRunsWithOnlyTheSourceConfigurationRoot() {
        let source = SessionCatalogSource(agent: .claude, root: URL(fileURLWithPath: "/fixture/.claude"),
                                          executable: "/bin/claude", configuration: .standard)
        let process = AgentHelperProcess.sdkScript("rename-session.mjs", arguments: ["id", "名字 带空格"],
                                                   helperDirectory: helper, source: source)
        #expect(process.executable == AgentHelperProcess.nodeRuntime(in: helper))
        #expect(process.arguments == ["/fixture/helper/rename-session.mjs", "id", "名字 带空格"])
        #expect(process.directory == helper)
        #expect(process.environment == ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
                                        "CLAUDE_CONFIG_DIR": "/fixture/.claude"])
    }

    /// CLI 继承用户环境，但去掉 pane 的 hook 路由、PATH 换成查找目录、配置根显式指向来源。
    @Test func agentCLIDropsPaneRoutingAndPinsPathAndRoot() {
        let inherited = ["HOME": "/Users/fixture", "PATH": "/usr/bin", "LIGHTTY_PANE_ID": "pane",
                         "LIGHTTY_SOCK": "/tmp/sock", "CODEX_HOME": "/elsewhere", "OPENAI_API_KEY": "kept"]
        for agent in SessionAgent.allCases {
            let process = AgentHelperProcess.agentCLI(agent, executable: "/opt/bin/\(agent.executableName)",
                root: "/fixture/root", arguments: ["delete", "--force", "id"],
                directory: URL(fileURLWithPath: "/fixture/root"),
                inherited: inherited, searchPath: ["/opt/bin", "/usr/bin"])
            #expect(process.executable.path == "/opt/bin/\(agent.executableName)")
            #expect(process.arguments == ["delete", "--force", "id"])
            #expect(!process.environment.keys.contains { $0.hasPrefix("LIGHTTY_") })
            #expect(process.environment["PATH"] == "/opt/bin:/usr/bin")
            #expect(process.environment[agent.configurationVariable] == "/fixture/root")
            #expect(process.environment["HOME"] == "/Users/fixture")
            #expect(process.environment["OPENAI_API_KEY"] == "kept")
        }
    }
}
