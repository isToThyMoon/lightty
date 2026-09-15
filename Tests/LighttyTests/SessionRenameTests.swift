import Foundation
import LighttyCore
import Testing
import XCTest
@testable import lightty

/// 对着真的 codex 跑，用的是一个临时的、合成的配置根，绝不碰用户自己的会话。
final class CodexSessionRenameIntegrationTests: XCTestCase {
    func testInstalledCodexRenamesASyntheticSessionThroughTheOfficialInterface() throws {
        guard let executable = HookInstaller.locateExecutable("codex") else { throw XCTSkip("Codex CLI not installed") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rename-test-\(UUID())")
        let directory = root.appendingPathComponent("sessions/2026/09/07")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        let stamp = "2026-09-07T00:00:00.000Z"
        let lines: [[String: Any]] = [
            ["timestamp": stamp, "type": "session_meta", "payload": [
                "id": id, "timestamp": stamp, "cwd": root.path,
                "originator": "lightty-test", "cli_version": "0.153.4",
                "source": "cli", "model_provider": "openai",
            ]],
            ["timestamp": stamp, "type": "event_msg", "payload": [
                "type": "user_message", "message": "Synthetic test", "images": [],
            ]],
        ]
        let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n") + "\n"
        try text.write(to: directory.appendingPathComponent("rollout-2026-09-07T00-00-00-\(id).jsonl"),
                       atomically: true, encoding: .utf8)
        let source = SessionCatalogSource(agent: .codex, root: root, executable: executable,
                                          configuration: .custom(root.path))
        let key = AgentSessionKey(agent: .codex, sourceRoot: root.path, nativeID: id)
        try SessionRename.rename(key, to: "改过的名字", provider: CodexSessionProvider(source: source))
        let records = try CodexSessionProvider(source: source).sessions(archived: false, cancelled: { false })
        XCTAssertEqual(records.first(where: { $0.key.nativeID == id })?.title, "改过的名字")
    }

    /// 同样对着真的官方开发包跑，配置根是临时目录。
    func testBundledHelperRenamesASyntheticClaudeSessionThroughTheOfficialSDK() throws {
        // 与 ClaudeSessionCatalogTests 同一套定位：测试进程的 argv[0] 是 Xcode 的
        // xctest，`installedHelper` 那条向上找 .build 的路走不通。
        let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/claude-session-helper")
        guard FileManager.default.isExecutableFile(atPath: AgentHelperProcess.nodeRuntime(in: helper).path),
              FileManager.default.isReadableFile(atPath: helper.appendingPathComponent("rename-session.mjs").path)
        else { throw XCTSkip("Claude session helper not prepared") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rename-test-\(UUID())")
        let project = root.appendingPathComponent("projects/-tmp-fixture")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        let message = UUID().uuidString.lowercased()
        let lines: [[String: Any]] = [
            ["type": "mode", "mode": "normal", "sessionId": id],
            ["type": "user", "isSidechain": false, "parentUuid": NSNull(), "uuid": message,
             "sessionId": id, "cwd": "/tmp/fixture", "timestamp": "2026-09-07T00:00:00.000Z",
             "message": ["role": "user", "content": "Synthetic test"]],
        ]
        let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n") + "\n"
        try text.write(to: project.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
        let source = SessionCatalogSource(agent: .claude, root: root, executable: "/nonexistent/claude",
                                          configuration: .custom(root.path))
        let key = AgentSessionKey(agent: .claude, sourceRoot: root.path, nativeID: id)
        try SessionRename.rename(key, to: "改过的名字",
                                 provider: ClaudeSessionProvider(source: source, helperDirectory: helper))
        let records = try ClaudeSessionProvider(source: source, helperDirectory: helper)
            .sessions(archived: false, cancelled: { false })
        XCTAssertEqual(records.first(where: { $0.key.nativeID == id })?.title, "改过的名字")
    }
}

struct SessionRenameTests {
    private let id = "01a07a5f-6811-7f12-94c5-dc0f0f92f40a"

    /// 两条改名路径（敲 `/rename`、走官方接口）共用一个清洗函数，否则同一个名字
    /// 在两条路上会存成两个样子。敲进终端的那条命令必须和官方接口收到的名字一致，
    /// 而且不带行尾——提交是另外按一次回车键，不是文本的一部分
    ///（见 `TerminalSurfaceView.sendText`）。
    @Test func renameNameIsSanitizedIdenticallyOnBothPaths() {
        let cases: [(input: String, cleaned: String?)] = [
            // 首尾空白去掉
            ("  修好灵动岛  ", "修好灵动岛"),
            // 换行压成一个空格，不能带行尾
            ("第一行\n第二行", "第一行 第二行"),
            // 控制字符去掉
            ("带\u{7}响铃", "带响铃"),
            // 截到 240 个字
            (String(repeating: "名", count: 300), String(repeating: "名", count: 240)),
            // 清洗后为空的一律是 nil
            ("", nil), ("   ", nil), ("\n\n", nil), ("\u{1}", nil),
        ]
        for c in cases {
            #expect(SessionRename.sanitize(c.input) == c.cleaned, "sanitize(\(c.input.debugDescription))")
            #expect(AgentCommand.rename(c.input).shellInput == c.cleaned.map { "/rename \($0)" },
                    "typed command for \(c.input.debugDescription)")
        }
    }

    /// 会话身份不匹配时不发任何请求：改名同样是写进用户的 agent 目录，
    /// 来源对不上就不能动。
    @Test func mismatchedSourceIsRejectedBeforeAnyProcessStarts() {
        let key = AgentSessionKey(agent: .codex, sourceRoot: "/fixture/.codex", nativeID: id)
        let elsewhere = FakeSessionProvider(agent: .codex, root: "/other/.codex")
        #expect(throws: SessionRename.Failure.invalidSource) {
            try SessionRename.rename(key, to: "新名字", provider: elsewhere)
        }
        let wrongAgent = FakeSessionProvider(agent: .claude, root: "/fixture/.codex")
        #expect(throws: SessionRename.Failure.invalidSource) {
            try SessionRename.rename(key, to: "新名字", provider: wrongAgent)
        }
        let notAUUID = AgentSessionKey(agent: .codex, sourceRoot: "/fixture/.codex", nativeID: "../escape")
        let provider = FakeSessionProvider(agent: .codex, root: "/fixture/.codex")
        #expect(throws: SessionRename.Failure.invalidSource) {
            try SessionRename.rename(notAUUID, to: "新名字", provider: provider)
        }
        #expect(throws: SessionRename.Failure.invalidName) {
            try SessionRename.rename(key, to: "  \n ", provider: provider)
        }
        #expect(elsewhere.calls.isEmpty && wrongAgent.calls.isEmpty && provider.calls.isEmpty)
    }
}
