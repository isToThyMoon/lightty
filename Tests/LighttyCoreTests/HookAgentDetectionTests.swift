import XCTest
@testable import LighttyCore

final class HookAgentDetectionTests: XCTestCase {
    private func agent(paths: [String] = [], transcript: String? = nil, env: [String: String] = [:]) -> String? {
        HookAgentDetection.agent(ancestorExecutablePaths: paths, transcriptPath: transcript, environment: env)
    }

    func testCodexPayloadWithoutEnvironmentHintsIsCodex() {
        // 实测：Codex 不给 hook 设 CODEX_HOME / CODEX_SANDBOX，但载荷带 Claude 同款 transcript_path。
        XCTAssertEqual(agent(paths: ["/bin/zsh", "/Users/u/.codex/packages/standalone/current/bin/codex", "/bin/zsh"],
                             transcript: "/Users/u/.codex/sessions/2026/09/07/rollout-x.jsonl"), "codex")
        XCTAssertEqual(agent(transcript: "/Users/u/.codex/sessions/2026/09/07/rollout-x.jsonl"), "codex")
        XCTAssertEqual(agent(transcript: "/custom/codex-home/sessions/rollout-x.jsonl"), "codex",
                       "自定义 CODEX_HOME 下没有 .codex 段，靠 rollout- 文件名认")
    }

    func testClaudeIsDetectedDespiteVersionedBinaryName() {
        // claude 经 symlink 解析后可执行名是版本号，靠路径里的 claude 段认。
        XCTAssertEqual(agent(paths: ["/bin/zsh", "/Users/u/.local/share/claude/versions/2.1.263", "/bin/zsh"],
                             transcript: nil), "claude")
        XCTAssertEqual(agent(paths: ["/bin/sh", "/opt/homebrew/bin/claude"]), "claude")
        XCTAssertEqual(agent(transcript: "/Users/u/.claude/projects/-Users-u-p/1234.jsonl"), "claude")
        XCTAssertEqual(agent(transcript: "/somewhere/else/1.jsonl"), "claude",
                       "认不出路径形状时，带 transcript_path 仍按旧约定视为 claude")
    }

    func testAncestorChainBeatsLeakedEnvironment() {
        // 上层 Claude 会话里启动 codex：环境有 CLAUDECODE，但父进程链里 codex 更近。
        XCTAssertEqual(agent(paths: ["/bin/zsh", "/Users/u/.codex/packages/x/bin/codex", "/bin/zsh", "/Users/u/.local/share/claude/versions/2.1.263"],
                             transcript: "/Users/u/.codex/sessions/rollout-1.jsonl",
                             env: ["CLAUDECODE": "1"]), "codex")
        // 反过来 codex 里跑 claude：最近的祖先优先。
        XCTAssertEqual(agent(paths: ["/bin/sh", "/Users/u/.local/share/claude/versions/2.1.263", "/bin/sh", "/Users/u/.codex/packages/x/bin/codex"]), "claude")
    }

    func testEnvironmentIsOnlyAFallback() {
        XCTAssertEqual(agent(env: ["CODEX_HOME": "/x"]), "codex")
        XCTAssertEqual(agent(env: ["CLAUDE_CODE_ENTRYPOINT": "cli"]), "claude")
        XCTAssertNil(agent(), "没有任何证据就留空")
        XCTAssertNil(agent(paths: ["/bin/zsh", "/Applications/lightty.app/Contents/MacOS/lightty", "/sbin/launchd"]))
    }
}
