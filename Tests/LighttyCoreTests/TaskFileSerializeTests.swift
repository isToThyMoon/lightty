import XCTest
@testable import LighttyCore

final class TaskFileSerializeTests: XCTestCase {

    func testSerializeFixedKeyOrder() {
        let file = TaskFile(
            name: "修会话",
            status: "stuck",
            workdir: "/Users/me/p",
            tool: "claude",
            created: utc("2026-08-22T10:00:00Z"),
            updated: utc("2026-08-22T12:30:00Z"),
            sessions: [TaskSession(tool: "claude", id: "s1")],
            unknownLines: ["x-b: 2", "x-a: 1"],
            body: "hi"
        )
        let expected = """
        ---
        name: 修会话
        status: stuck
        workdir: /Users/me/p
        tool: claude
        created: 2026-08-22T10:00:00Z
        updated: 2026-08-22T12:30:00Z
        x-b: 2
        x-a: 1
        sessions:
          - claude:s1
        ---
        hi
        """
        XCTAssertEqual(file.serialize(), td(expected))
    }

    func testSerializeOmitsToolAndEmptySessions() {
        let file = TaskFile(
            name: "a", status: "active", workdir: "/x",
            created: utc("2026-08-22T10:00:00Z"), updated: utc("2026-08-22T10:00:00Z")
        )
        let expected = "---\nname: a\nstatus: active\nworkdir: /x\ncreated: 2026-08-22T10:00:00Z\nupdated: 2026-08-22T10:00:00Z\n---\n"
        XCTAssertEqual(file.serialize(), td(expected))
    }

    func testRoundTripByteFidelity() throws {
        // 键序为规范序时，parse → serialize 须字节等同（含未知键、正文无结尾换行）
        let input = "---\nname: 任务 甲\nstatus: done\nworkdir: /a/b\ntool: codex\ncreated: 2026-08-22T10:00:00Z\nupdated: 2026-08-22T12:30:00Z\nx-vendor: 原样 保留  值\nsessions:\n  - codex:id-1\n  - claude:id-2\n---\n正文\n末行无换行"
        let data = td(input)
        let file = try TaskFile.parse(data)
        XCTAssertEqual(file.serialize(), data)
    }

    func testRoundTripEmptyBody() throws {
        let input = "---\nname: a\nstatus: active\nworkdir: /x\ncreated: 2026-08-22T10:00:00Z\nupdated: 2026-08-22T10:00:00Z\n---\n"
        let file = try TaskFile.parse(td(input))
        XCTAssertEqual(file.serialize(), td(input))
        XCTAssertEqual(file.body, "")
    }

    func testLegacyCWDOnlyFileUpgradesOnRewrite() throws {
        // ≤v0.3.0 的旧文件只有 cwd；重写时升级为 workdir（干净切换，不再回写 cwd）
        let input = "---\nname: a\nstatus: active\ncwd: /x\ncreated: 2026-08-22T10:00:00Z\nupdated: 2026-08-22T10:00:00Z\n---\n"
        let file = try TaskFile.parse(td(input))
        XCTAssertEqual(file.workdir, "/x")
        let expected = "---\nname: a\nstatus: active\nworkdir: /x\ncreated: 2026-08-22T10:00:00Z\nupdated: 2026-08-22T10:00:00Z\n---\n"
        XCTAssertEqual(file.serialize(), td(expected))
    }
}
