import XCTest
@testable import LighttyCore

/// 续接与原生选择器共用一份启动环境。这里把两种计划敲给 shell 的整行钉成原文：
/// 抽出共用类型前后逐字一致，改拼法时必须有意识地改这里。
final class AgentLaunchContextTests: XCTestCase {
    private func session(_ agent: SessionAgent, root: String, cwd: String? = "/repo") -> AgentSession {
        AgentSession(key: .init(agent: agent, sourceRoot: root, nativeID: "abc-123"),
                     title: "", workingDirectory: cwd, updatedAt: nil)
    }

    func testResumeShellInputIsVerbatim() throws {
        let cases: [(SessionAgent, String, String, SessionConfigurationLocation, [String], String)] = [
            (.codex, "/cfg/codex", "/bin/codex", .standard, [],
             "/usr/bin/env -u 'CODEX_HOME' '/bin/codex' 'resume' 'abc-123'\n"),
            (.codex, "/cfg/codex", "/opt/it's/codex", .custom("/cfg/codex"), ["--yolo"],
             "/usr/bin/env 'CODEX_HOME=/cfg/codex' '/opt/it'\\''s/codex' 'resume' '--yolo' 'abc-123'\n"),
            (.claude, "/cfg/claude", "/bin/claude", .standard, ["--permission-mode", "bypassPermissions"],
             "/usr/bin/env -u 'CLAUDE_CONFIG_DIR' '/bin/claude' '--permission-mode' 'bypassPermissions' '--resume' 'abc-123'\n"),
            (.claude, "/cfg/claude", "/bin/claude", .custom("/cfg/claude/"), ["--x=a b"],
             "/usr/bin/env 'CLAUDE_CONFIG_DIR=/cfg/claude/' '/bin/claude' '--x=a b' '--resume' 'abc-123'\n"),
        ]
        for (agent, root, executable, configuration, arguments, expected) in cases {
            let plan = try SessionResumePlan(session: session(agent, root: root), executable: executable,
                                             configuration: configuration, launchArguments: arguments)
            XCTAssertEqual(plan.shellInput, expected)
        }
    }

    func testPickerShellInputIsVerbatim() throws {
        let cases: [(SessionAgent, String, String, SessionConfigurationLocation, [String], String)] = [
            (.codex, "/cfg/codex", "/bin/codex", .standard, [],
             "/usr/bin/env -u 'CODEX_HOME' '/bin/codex' 'resume' '--all'\n"),
            (.codex, "/cfg/codex/", "/opt/it's/codex", .custom("/cfg/codex"), ["--yolo"],
             "/usr/bin/env 'CODEX_HOME=/cfg/codex' '/opt/it'\\''s/codex' 'resume' '--yolo' '--all'\n"),
            (.claude, "/cfg/claude", "/bin/claude", .standard, ["--permission-mode", "bypassPermissions"],
             "/usr/bin/env -u 'CLAUDE_CONFIG_DIR' '/bin/claude' '--permission-mode' 'bypassPermissions' '--resume'\n"),
            (.claude, "/cfg/claude", "/bin/claude", .custom("/cfg/claude/"), ["--x=a b"],
             "/usr/bin/env 'CLAUDE_CONFIG_DIR=/cfg/claude/' '/bin/claude' '--x=a b' '--resume'\n"),
        ]
        for (agent, root, executable, configuration, arguments, expected) in cases {
            let plan = try SessionPickerPlan(agent: agent, sourceRoot: root, executable: executable,
                                             configuration: configuration, workingDirectory: "/home/me",
                                             launchArguments: arguments)
            XCTAssertEqual(plan.shellInput, expected)
        }
    }

    /// 来源目录在两种计划里都按标准化后的路径比对自定义来源：续接的会话身份构造时已标准化，
    /// 选择器由计划自己标准化。尾部斜杠不影响结果。
    func testSourceRootIsComparedStandardized() throws {
        XCTAssertNoThrow(try SessionResumePlan(session: session(.codex, root: "/cfg/codex/"),
                                                   executable: "/bin/codex", configuration: .custom("/cfg/codex"),
                                                   launchArguments: []))
        XCTAssertNoThrow(try SessionPickerPlan(agent: .codex, sourceRoot: "/cfg/codex/", executable: "/bin/codex",
                                               configuration: .custom("/cfg/codex"), workingDirectory: "/repo",
                                               launchArguments: []))
    }

    /// 两种计划只是给同一份启动环境接上不同的尾部：续接接会话身份，选择器接各家的列表参数。
    func testBothPlansComposeTheSameContext() throws {
        for agent in SessionAgent.allCases {
            let context = try AgentLaunchContext(agent: agent, sourceRoot: "/cfg/", configuration: .custom("/cfg"),
                                                 executable: "/bin/x", workingDirectory: "/repo",
                                                 launchArguments: ["--flag"])
            XCTAssertEqual(context.sourceRoot, "/cfg")
            XCTAssertEqual(context.environment, [agent.configurationVariable: "/cfg"])
            XCTAssertEqual(context.unsetEnvironment, [])
            let resume = try SessionResumePlan(session: session(agent, root: "/cfg"), executable: "/bin/x",
                                               configuration: .custom("/cfg"), launchArguments: ["--flag"])
            let picker = try SessionPickerPlan(agent: agent, sourceRoot: "/cfg/", executable: "/bin/x",
                                               configuration: .custom("/cfg"), workingDirectory: "/repo",
                                               launchArguments: ["--flag"])
            XCTAssertEqual(resume.context, context)
            XCTAssertEqual(picker.context, context)
            XCTAssertEqual(resume.nativeID, "abc-123")
            XCTAssertEqual(resume.shellInput, context.shellInput(tail: ["abc-123"]))
            XCTAssertEqual(picker.shellInput, context.shellInput(tail: agent == .codex ? ["--all"] : []))
        }
    }

    func testContextRejectsUntrustedValues() {
        let cases: [(String, String, SessionConfigurationLocation, String, [String], InvalidLaunchPlan)] = [
            ("/cfg", "bin/x", .standard, "/repo", [], .invalidValue),
            ("/cfg", "/bin/x", .standard, "repo", [], .missingDirectory),
            ("/cfg", "/bin/x", .standard, "/repo\n", [], .invalidValue),
            ("/cfg", "/bin/\u{7}x", .standard, "/repo", [], .invalidValue),
            ("/cfg", "/bin/x", .custom("/elsewhere"), "/repo", [], .invalidValue),
            ("/cfg", "/bin/x", .custom("cfg"), "/repo", [], .invalidValue),
            ("/cfg", "/bin/x", .standard, "/repo", [""], .invalidValue),
            ("/cfg", "/bin/x", .standard, "/repo", ["--a\nb"], .invalidValue),
        ]
        for (root, executable, configuration, cwd, arguments, expected) in cases {
            XCTAssertThrowsError(try AgentLaunchContext(agent: .claude, sourceRoot: root, configuration: configuration,
                                                        executable: executable, workingDirectory: cwd,
                                                        launchArguments: arguments)) { error in
                XCTAssertEqual(error as? InvalidLaunchPlan, expected)
            }
        }
    }

    /// 续接的目录：显式覆盖优先，否则取会话记录的目录；两者都没有、或不是绝对路径，拒绝。
    func testResumeDirectoryFallsBackToTheSessionRecord() throws {
        XCTAssertThrowsError(try SessionResumePlan(session: session(.claude, root: "/cfg", cwd: nil),
                                                   executable: "/bin/claude", configuration: .standard,
                                                   launchArguments: []))
        XCTAssertThrowsError(try SessionResumePlan(session: session(.claude, root: "/cfg"),
                                                   executable: "/bin/claude", configuration: .standard,
                                                   workingDirectory: "relative", launchArguments: []))
        XCTAssertNoThrow(try SessionResumePlan(session: session(.claude, root: "/cfg", cwd: nil),
                                               executable: "/bin/claude", configuration: .standard,
                                               workingDirectory: "/override", launchArguments: []))
    }
}
