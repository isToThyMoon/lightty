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
        let result = SessionOccupancy.check(key)
        XCTAssertEqual(result, .inUse(pid: process.processIdentifier))
        XCTAssertTrue(process.isRunning, "The probe must not terminate the writer")
        XCTAssertEqual(try Data(contentsOf: transcript), original)
        process.terminate() // Only the fake writer created by this test.
        process.waitUntilExit()
        XCTAssertEqual(SessionOccupancy.check(key), .unknown, "A history file alone is not occupancy evidence")
    }

    func testExactWritableCodexTranscriptIsPositiveEvidence() {
        let key = AgentSessionKey(agent: .codex, sourceRoot: "/fixture/.codex", nativeID: id)
        for directory in ["sessions/2026/09/06", "archived_sessions"] {
            let path = "/fixture/.codex/\(directory)/rollout-date-\(id).jsonl"
            XCTAssertEqual(SessionOccupancy.inspect(output(path: path), for: key), .inUse(pid: 123))
            XCTAssertEqual(SessionOccupancy.inspect(output(access: "w", path: path), for: key), .inUse(pid: 123))
            XCTAssertEqual(SessionOccupancy.inspect(output(access: "r", path: path), for: key), .unknown)
            XCTAssertEqual(SessionOccupancy.inspect(output(command: "cat", path: path), for: key), .unknown)
            XCTAssertEqual(SessionOccupancy.inspect(output(command: "codex-other", path: path), for: key), .unknown)
        }
    }

    func testDifferentSourceSessionAndNonTranscriptAreUnknown() {
        let key = AgentSessionKey(agent: .codex, sourceRoot: "/fixture/.codex", nativeID: id)
        for path in ["/other/.codex/sessions/rollout-date-\(id).jsonl",
                     "/fixture/.codex-other/sessions/rollout-date-\(id).jsonl",
                     "/fixture/.codex/sessions/rollout-date-other.jsonl",
                     "/fixture/.codex/config.toml", "/fixture/.codex/sessions/rollout-date-\(id).jsonl.bak"] {
            XCTAssertEqual(SessionOccupancy.inspect(output(path: path), for: key), .unknown)
        }
        XCTAssertEqual(SessionOccupancy.inspect(Data(), for: key), .unknown)
        XCTAssertEqual(SessionOccupancy.inspect(Data("permission denied".utf8), for: key), .unknown)
    }

    func testClaudeAndDescriptorStateDoNotLeakBetweenRecords() {
        let key = AgentSessionKey(agent: .claude, sourceRoot: "/fixture/.claude", nativeID: id)
        let path = "/fixture/.claude/projects/project/\(id).jsonl"
        XCTAssertEqual(SessionOccupancy.inspect(output(command: "claude", path: path), for: key), .inUse(pid: 123))
        XCTAssertEqual(SessionOccupancy.inspect(output(command: "node", path: path), for: key), .unknown)
        let records = Data("p123\0cclaude\0\nf3\0au\0n/tmp/other\0\nf4\0n\(path)\0\n".utf8)
        XCTAssertEqual(SessionOccupancy.inspect(records, for: key), .unknown)
        let differentProcess = Data("p123\0cclaude\0\nf3\0au\0n/tmp/other\0\np456\0ccat\0\nf4\0au\0n\(path)\0\n".utf8)
        XCTAssertEqual(SessionOccupancy.inspect(differentProcess, for: key), .unknown)
    }
}
