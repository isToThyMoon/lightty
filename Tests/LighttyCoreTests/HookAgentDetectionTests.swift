import XCTest
@testable import LighttyCore

/// `HookAgentDetection.agent(...)` 只是**兼容退路**：hook 命令行里带了 `--agent` 就用不上它，
/// 只有用户装的还是旧版插件时才走到这里。这一组用例照旧全留——退路失灵是静默的
/// （agent 字段留空或认错家），没人会去看。
///
/// 按父进程链上的可执行路径猜哪一家那一段已经删了（随安装方式变），
/// 找 agent 进程与判断子会话见 `AgentProcessStructureTests`。
final class HookAgentDetectionTests: XCTestCase {
    private func agent(transcript: String? = nil, env: [String: String] = [:]) -> String? {
        HookAgentDetection.agent(transcriptPath: transcript, environment: env)
    }

    func testCodexPayloadWithoutEnvironmentHintsIsCodex() {
        // 实测：Codex 不给 hook 设 CODEX_HOME / CODEX_SANDBOX，但载荷带 Claude 同款 transcript_path。
        XCTAssertEqual(agent(transcript: "/Users/u/.codex/sessions/2026/09/07/rollout-x.jsonl"), "codex")
        XCTAssertEqual(agent(transcript: "/custom/codex-home/sessions/rollout-x.jsonl"), "codex",
                       "自定义 CODEX_HOME 下没有 .codex 段，靠 rollout- 文件名认")
        // 上层 Claude 会话里启动 codex：CLAUDECODE 泄漏进来了，但载荷形状更可靠。
        XCTAssertEqual(agent(transcript: "/Users/u/.codex/sessions/rollout-1.jsonl",
                             env: ["CLAUDECODE": "1"]), "codex")
    }

    func testClaudeIsDetectedFromItsTranscriptShape() {
        XCTAssertEqual(agent(transcript: "/Users/u/.claude/projects/-Users-u-p/1234.jsonl"), "claude")
        XCTAssertEqual(agent(transcript: "/somewhere/else/1.jsonl"), "claude",
                       "认不出路径形状时，带 transcript_path 仍按旧约定视为 claude")
    }

    func testEnvironmentIsOnlyAFallback() {
        XCTAssertEqual(agent(env: ["CODEX_HOME": "/x"]), "codex")
        XCTAssertEqual(agent(env: ["CLAUDE_CODE_ENTRYPOINT": "cli"]), "claude")
        XCTAssertNil(agent(), "没有任何证据就留空")
    }
}
