import XCTest
@testable import LighttyCore

/// 测试用：字符串转字节
func td(_ s: String) -> Data { Data(s.utf8) }

/// 测试用：构造 UTC 时间
func utc(_ s: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)!
}

/// 断言解析抛出带指定行号的错误
func assertParseError(
    _ input: String, line expectedLine: Int, messageContains fragment: String? = nil,
    file: StaticString = #filePath, sourceLine: UInt = #line
) {
    XCTAssertThrowsError(try TaskFile.parse(td(input)), file: file, line: sourceLine) { error in
        guard let e = error as? TaskParseError else {
            XCTFail("错误类型不是 TaskParseError: \(error)", file: file, line: sourceLine)
            return
        }
        XCTAssertEqual(e.line, expectedLine, "行号不符: \(e)", file: file, line: sourceLine)
        if let fragment {
            XCTAssertTrue(e.message.contains(fragment), "信息不含「\(fragment)」: \(e.message)", file: file, line: sourceLine)
        }
    }
}

final class TaskFileParseTests: XCTestCase {

    let fullSample = """
    ---
    name: 修会话管理方案
    status: active
    cwd: /Users/me/project/foo
    tool: claude
    created: 2026-08-22T10:00:00Z
    updated: 2026-08-22T12:30:00Z
    x-extra: 保留我
    sessions:
      - claude:3551e356-5b15-43d1-86a5-69764b142807
      - codex:abc
    ---
    正文第一行

    第二行无结尾换行
    """

    func testParseFullFile() throws {
        let file = try TaskFile.parse(td(fullSample))
        XCTAssertEqual(file.name, "修会话管理方案")
        XCTAssertEqual(file.status, .active)
        XCTAssertEqual(file.cwd, "/Users/me/project/foo")
        XCTAssertEqual(file.tool, "claude")
        XCTAssertEqual(file.created, utc("2026-08-22T10:00:00Z"))
        XCTAssertEqual(file.updated, utc("2026-08-22T12:30:00Z"))
        XCTAssertEqual(file.unknownLines, ["x-extra: 保留我"])
        XCTAssertEqual(file.sessions, [
            TaskSession(tool: "claude", id: "3551e356-5b15-43d1-86a5-69764b142807"),
            TaskSession(tool: "codex", id: "abc"),
        ])
        XCTAssertEqual(file.body, "正文第一行\n\n第二行无结尾换行")
    }

    func testParseMinimalFile() throws {
        let input = """
        ---
        name: a
        status: done
        cwd: /tmp
        created: 2026-08-22T10:00:00Z
        updated: 2026-08-22T10:00:00Z
        ---

        """
        let file = try TaskFile.parse(td(input))
        XCTAssertNil(file.tool)
        XCTAssertEqual(file.sessions, [])
        XCTAssertEqual(file.unknownLines, [])
        XCTAssertEqual(file.status, .done)
        // 多行字面量闭合前的末尾空行只贡献闭合 --- 的换行，正文为空
        XCTAssertEqual(file.body, "")
    }

    func testBodyBytePreservation() throws {
        // 正文结尾多个换行须原样保留
        let input = "---\nname: a\nstatus: stuck\ncwd: /x\ncreated: 2026-08-22T10:00:00Z\nupdated: 2026-08-22T10:00:00Z\n---\nbody\n\n\n"
        let file = try TaskFile.parse(td(input))
        XCTAssertEqual(file.body, "body\n\n\n")
    }

    func testEmptyBodyWhenFileEndsAtClosingDashes() throws {
        // 闭合 --- 后无换行也无正文
        let input = "---\nname: a\nstatus: active\ncwd: /x\ncreated: 2026-08-22T10:00:00Z\nupdated: 2026-08-22T10:00:00Z\n---"
        let file = try TaskFile.parse(td(input))
        XCTAssertEqual(file.body, "")
    }

    // MARK: - 非法输入

    func testErrorNotStartingWithDashes() {
        assertParseError("name: x\n", line: 1)
        assertParseError("", line: 1)
        assertParseError("--- \nname: x\n---\n", line: 1)
    }

    func testErrorUnclosedFrontmatter() {
        assertParseError("---\nname: x\n", line: 2, messageContains: "闭合")
        assertParseError("---\n", line: 1, messageContains: "闭合")
    }

    func testErrorLineWithoutColon() {
        assertParseError("---\nname: x\nbadline\n---\n", line: 3, messageContains: "冒号")
    }

    func testErrorColonWithoutSpace() {
        assertParseError("---\nname:x\n---\n", line: 2)
    }

    func testErrorDuplicateKey() {
        let input = "---\nname: a\nstatus: active\nname: b\n---\n"
        assertParseError(input, line: 4, messageContains: "重复")
    }

    func testErrorBadStatus() {
        let input = "---\nname: a\nstatus: paused\ncwd: /x\ncreated: 2026-08-22T10:00:00Z\nupdated: 2026-08-22T10:00:00Z\n---\n"
        assertParseError(input, line: 3, messageContains: "status")
    }

    func testErrorBadTimestamp() {
        let input = "---\nname: a\nstatus: active\ncwd: /x\ncreated: 2026-08-22 10:00\nupdated: 2026-08-22T10:00:00Z\n---\n"
        assertParseError(input, line: 5)
    }

    func testErrorSessionEntryOutsideBlock() {
        let input = "---\nname: a\nstatus: active\ncwd: /x\ncreated: 2026-08-22T10:00:00Z\nupdated: 2026-08-22T10:00:00Z\n  - claude:x\n---\n"
        assertParseError(input, line: 7)
    }

    func testErrorSessionEntryAfterBlockClosed() {
        // sessions 块被普通键打断后再出现条目行
        let input = "---\nname: a\nstatus: active\ncwd: /x\ncreated: 2026-08-22T10:00:00Z\nsessions:\n  - claude:x\nupdated: 2026-08-22T10:00:00Z\n  - claude:y\n---\n"
        assertParseError(input, line: 9)
    }

    func testErrorSessionEntryMissingColon() {
        let input = "---\nname: a\nstatus: active\ncwd: /x\ncreated: 2026-08-22T10:00:00Z\nupdated: 2026-08-22T10:00:00Z\nsessions:\n  - nocolon\n---\n"
        assertParseError(input, line: 8)
    }

    func testErrorMissingRequiredKey() {
        // 缺 cwd，报错落在闭合行
        let input = "---\nname: a\nstatus: active\ncreated: 2026-08-22T10:00:00Z\nupdated: 2026-08-22T10:00:00Z\n---\n"
        assertParseError(input, line: 6, messageContains: "cwd")
    }
}
