import XCTest
import LighttyCore
@testable import lightty

final class SessionOccupancyTests: XCTestCase {
    private let id = "01a07a5f-6811-7f12-94c5-dc0f0f92f40a"

    private func output(command: String = "codex", access: String = "u", path: String) -> Data {
        Data("p123\0c\(command)\0\nf39\0a\(access)\0n\(path)\0\n".utf8)
    }

    func testOSProbeFindsOnlyFixtureWriterAndDoesNotModifyTranscript() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = directory.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A tiny fixture, not a real CLI. Avoid relocating an Apple platform-signed binary.
        let executable = directory.appendingPathComponent("codex")
        let source = directory.appendingPathComponent("fixture.c")
        try "#include <fcntl.h>\n#include <unistd.h>\nint main(int argc,char **argv){int fd=open(argv[1],O_RDWR);if(fd<0)return 1;write(1,\"ready\\n\",6);sleep(30);close(fd);return 0;}\n"
            .write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = [source.path, "-o", executable.path]
        try compiler.run()
        compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0)
        let transcript = sessions.appendingPathComponent("rollout-fixture-\(id).jsonl")
        let original = Data("fixture history\n".utf8)
        try original.write(to: transcript)
        let process = Process()
        process.executableURL = executable
        process.arguments = [transcript.path]
        process.standardInput = FileHandle.nullDevice
        let ready = Pipe()
        process.standardOutput = ready
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        try ready.fileHandleForWriting.close()
        XCTAssertEqual(ready.fileHandleForReading.availableData, Data("ready\n".utf8))
        let key = AgentSessionKey(agent: .codex, sourceRoot: directory.path, nativeID: id)
        let provider = CodexSessionProvider(source: .init(agent: .codex, root: directory,
            executable: executable.path, configuration: .custom(directory.path)))
        let result = provider.occupancy(of: key)
        XCTAssertEqual(result, .inUse(pid: process.processIdentifier))
        XCTAssertTrue(process.isRunning, "The probe must not terminate the writer")
        XCTAssertEqual(try Data(contentsOf: transcript), original)
        process.terminate() // Only the fake writer created by this test.
        process.waitUntilExit()
        XCTAssertEqual(provider.occupancy(of: key), .unknown, "A history file alone is not occupancy evidence")
    }

    /// `inspect()`：lsof 行 → 占用结论的查表。正例是「codex 以可写方式打开本源根下
    /// 精确匹配的会话记录」；差任何一样都是 unknown。
    func testCodexInspectClassifiesOpenFileRows() {
        let key = AgentSessionKey(agent: .codex, sourceRoot: "/fixture/.codex", nativeID: id)
        var cases: [(name: String, data: Data, expected: SessionOccupancy.Result)] = []
        for directory in ["sessions/2026/09/06", "archived_sessions"] {
            let path = "/fixture/.codex/\(directory)/rollout-date-\(id).jsonl"
            // 可写打开（u / w）算证据
            cases.append(("\(directory): access u", output(path: path), .inUse(pid: 123)))
            cases.append(("\(directory): access w", output(access: "w", path: path), .inUse(pid: 123)))
            // 只读打开不算
            cases.append(("\(directory): access r", output(access: "r", path: path), .unknown))
            // 命令名不是 codex 不算（包括前缀相同的别的命令）
            cases.append(("\(directory): command cat", output(command: "cat", path: path), .unknown))
            cases.append(("\(directory): command codex-other", output(command: "codex-other", path: path), .unknown))
        }
        // 别的源根、别的会话 ID、不是会话记录的文件，都不算
        for path in ["/other/.codex/sessions/rollout-date-\(id).jsonl",
                     "/fixture/.codex-other/sessions/rollout-date-\(id).jsonl",
                     "/fixture/.codex/sessions/rollout-date-other.jsonl",
                     "/fixture/.codex/config.toml", "/fixture/.codex/sessions/rollout-date-\(id).jsonl.bak"] {
            cases.append(("path \(path)", output(path: path), .unknown))
        }
        // 空输出与报错文本
        cases.append(("empty output", Data(), .unknown))
        cases.append(("error text", Data("permission denied".utf8), .unknown))
        for c in cases {
            XCTAssertEqual(CodexSessionProvider.inspect(c.data, for: key), c.expected, c.name)
        }
    }

    func testClaudeAndDescriptorStateDoNotLeakBetweenRecords() {
        let key = AgentSessionKey(agent: .claude, sourceRoot: "/fixture/.claude", nativeID: id)
        let path = "/fixture/.claude/projects/project/\(id).jsonl"
        XCTAssertEqual(ClaudeSessionProvider.inspect(output(command: "claude", path: path), for: key), .inUse(pid: 123))
        XCTAssertEqual(ClaudeSessionProvider.inspect(output(command: "node", path: path), for: key), .unknown)
        let records = Data("p123\0cclaude\0\nf3\0au\0n/tmp/other\0\nf4\0n\(path)\0\n".utf8)
        XCTAssertEqual(ClaudeSessionProvider.inspect(records, for: key), .unknown)
        let differentProcess = Data("p123\0cclaude\0\nf3\0au\0n/tmp/other\0\np456\0ccat\0\nf4\0au\0n\(path)\0\n".utf8)
        XCTAssertEqual(ClaudeSessionProvider.inspect(differentProcess, for: key), .unknown)
    }

    /// `decodeLiveSessions`：活会话表的输入 → 结果查表。
    ///
    /// 认不出来必须是「问不出来」（nil），不能是空表——空表会被读成「一个都没在跑」，
    /// 于是一段正开着的会话会被当成可以删。
    func testClaudeLiveRegistryDecodesOrRefuses() {
        typealias Row = (pid: Int32, sessionID: String, cwd: String?)
        let other = "5b6ff2ba-3f6c-4d1e-9f70-2b1c0a4d8e11"
        let cases: [(name: String, text: String, expected: [Row]?)] = [
            // 正例：pid → 会话，cwd 也要读出来——官方开发包偶尔给不出会话目录，靠这张表补空
            ("two sessions", """
             [{"pid":51228,"cwd":"/w","kind":"interactive","sessionId":"\(id)","name":"a","status":"idle"},
              {"pid":51233,"cwd":"/w","kind":"interactive","sessionId":"\(other)","name":"b","status":"busy"}]
             """, [(51228, id, "/w"), (51233, other, "/w")]),
            // 空表是合法的「一个都没在跑」
            ("empty array", "[]", []),
            // cwd 缺了不算致命——它只补目录，不参与占用判断，整张表仍然可信
            ("missing cwd", "[{\"pid\":7,\"sessionId\":\"\(id)\",\"status\":\"idle\"}]", [(7, id, nil)]),
            // 反例：八种坏输入都必须是 nil 而非空表
            ("empty", "", nil),
            ("not json", "not json", nil),
            ("object not array", "{\"pid\":1}", nil),
            ("row without pid", "[{\"cwd\":\"/w\"}]", nil),
            ("pid 0", "[{\"pid\":0,\"sessionId\":\"\(id)\"}]", nil),
            ("session id not a uuid", "[{\"pid\":1,\"sessionId\":\"not-a-uuid\"}]", nil),
            ("pid as string", "[{\"pid\":\"1\",\"sessionId\":\"\(id)\"}]", nil),
            ("one good row beside a bad one", "[{\"pid\":1,\"sessionId\":\"\(id)\"},{\"cwd\":\"/w\"}]", nil),
        ]
        for c in cases {
            let decoded = ClaudeSessionProvider.decodeLiveSessions(Data(c.text.utf8))
            guard let expected = c.expected else {
                XCTAssertNil(decoded, c.name)
                continue
            }
            let rows = decoded?.map { [String($0.pid), $0.sessionID, $0.cwd ?? "<nil>"] }
            XCTAssertEqual(rows, expected.map { [String($0.pid), $0.sessionID, $0.cwd ?? "<nil>"] }, c.name)
        }
    }

    /// 一次问出「哪些会话正开着」——列表要在点下去之前标注，逐条问 N 次不现实。
    func testOpenSessionPIDsAreCollectedInOneScan() {
        let other = "5b6ff2ba-3f6c-4d1e-9f70-2b1c0a4d8e11"
        let root = "/fixture/.codex"
        var text = "p1\0ccodex\0\nf3\0au\0n\(root)/sessions/2026/09/09/rollout-2026-09-09T00-00-00-\(id).jsonl\0\n"
        text += "p2\0ccodex\0\nf4\0aw\0n\(root)/archived_sessions/rollout-x-\(other).jsonl\0\n"
        // 只读打开不算证据；别的命令打开也不算。
        text += "p3\0ccodex\0\nf5\0ar\0n\(root)/sessions/rollout-y-11111111-1111-1111-1111-111111111111.jsonl\0\n"
        text += "p4\0ccat\0\nf6\0au\0n\(root)/sessions/rollout-z-22222222-2222-2222-2222-222222222222.jsonl\0\n"
        XCTAssertEqual(CodexSessionProvider.decodeOpenSessionPIDs(Data(text.utf8), root: root),
                       [id: [1], other: [2]])
        // 不是会话记录的文件不算。
        let noise = "p1\0ccodex\0\nf3\0au\0n\(root)/config.toml\0\n"
        XCTAssertTrue(CodexSessionProvider.decodeOpenSessionPIDs(Data(noise.utf8), root: root).isEmpty)
    }
}
