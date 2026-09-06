import Foundation
import XCTest
import LighttyCore
@testable import lightty

final class ClaudeSessionCatalogTests: XCTestCase {
    private var helper: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/claude-session-helper")
    }

    func testOfficialHelperListsTwoPagesWithoutOptionalClaudeBinary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-provider-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("projects")
        let paths = [projects.appendingPathComponent("project-a"), projects.appendingPathComponent("project-b")]
        for path in paths { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        var ids = Set<String>()
        for index in 0..<106 {
            let id = UUID().uuidString.lowercased()
            if index < 105 { ids.insert(id) }
            let record: [String: Any] = ["type": "user", "sessionId": id, "uuid": UUID().uuidString,
                "parentUuid": NSNull(), "isSidechain": index == 105, "cwd": "/tmp/中文 project",
                "timestamp": "2026-09-07T00:00:00Z", "entrypoint": "cli",
                "message": ["role": "user", "content": "Synthetic session \(index)"]]
            var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            data.append(10)
            if index == 1 { data.append(Data("{\"partial\":".utf8)) }
            try data.write(to: paths[index % 2].appendingPathComponent("\(id).jsonl"))
        }
        let source = SessionCatalogSource(agent: .claude, root: root, executable: "/missing/claude")
        let provider = ClaudeSessionCatalog(source: source, helperDirectory: helper)
        let first = try provider.page(archived: false, cursor: nil, cancelled: { false })
        XCTAssertEqual(first.sessions.count, 100)
        XCTAssertEqual(first.nextCursor, "100")
        let second = try provider.page(archived: false, cursor: first.nextCursor, cancelled: { false })
        XCTAssertEqual(second.sessions.count, 5)
        XCTAssertNil(second.nextCursor)
        XCTAssertEqual(Set((first.sessions + second.sessions).map(\.key.nativeID)), ids)
        XCTAssertTrue(first.sessions.allSatisfy { $0.key.agent == .claude && $0.workingDirectory == "/tmp/中文 project" })
        XCTAssertTrue(try provider.page(archived: true, cursor: nil, cancelled: { false }).sessions.isEmpty)
        XCTAssertThrowsError(try provider.page(archived: false, cursor: nil, cancelled: { true }))
    }

    func testMetadataContractRejectsMalformedResponsesAndUsesMilliseconds() throws {
        let source = SessionCatalogSource(agent: .claude, root: URL(fileURLWithPath: "/fixture"), executable: "/claude")
        let id = UUID().uuidString
        let data = Data("{\"version\":1,\"sessions\":[{\"id\":\"\(id)\",\"title\":\"name\",\"cwd\":null,\"updatedAt\":1700000000000}],\"nextCursor\":null}".utf8)
        let page = try ClaudeSessionCatalog.decode(data, source: source, offset: 0)
        XCTAssertEqual(page.sessions.first?.updatedAt?.timeIntervalSince1970, 1700000000)
        XCTAssertThrowsError(try ClaudeSessionCatalog.decode(Data("{\"version\":2,\"sessions\":[]}".utf8), source: source, offset: 0))
        XCTAssertThrowsError(try ClaudeSessionCatalog.decode(Data("{\"version\":1,\"sessions\":[],\"nextCursor\":\"0\"}".utf8), source: source, offset: 0))
    }

    func testMissingHelperDoesNotFallBackToUserNodeOrPrivateParser() {
        let source = SessionCatalogSource(agent: .claude, root: URL(fileURLWithPath: "/fixture"), executable: "/claude")
        let provider = ClaudeSessionCatalog(source: source, helperDirectory: URL(fileURLWithPath: "/missing-helper"))
        XCTAssertThrowsError(try provider.page(archived: false, cursor: nil, cancelled: { false }))
    }

    func testHelperProcessCancellationTimeoutOutputLimitAndExitCode() throws {
        func run(_ script: String, timeout: TimeInterval = 1, limit: Int = 1024, cancelled: () -> Bool = { false }) throws -> Data {
            try SessionHelperProcess.readPage(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                directory: URL(fileURLWithPath: "/tmp"), environment: ["PATH": "/usr/bin:/bin"],
                cancelled: cancelled, timeout: timeout, maximumBytes: limit)
        }
        XCTAssertEqual(try run("printf safe"), Data("safe".utf8))
        XCTAssertThrowsError(try run("exit 4"))
        XCTAssertThrowsError(try run("printf '%02000d' 0", limit: 16))
        let start = Date()
        XCTAssertThrowsError(try run("while :; do :; done", timeout: 0.05))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        let cancelledAt = Date().addingTimeInterval(0.05)
        XCTAssertThrowsError(try run("while :; do :; done", cancelled: { Date() > cancelledAt }))
    }

    /// 官方开发包列会话时只在转录文件的**头 64KB** 里找工作目录。用户第一句话里
    /// 贴了图片时，第一条用户记录有几百 KB，`cwd` 写在这条记录的末尾，落在窗口
    /// 之外——整条会话就报不出工作目录，点开会弹「原会话目录不存在」。
    ///
    /// 夹具照着真实文件的形状搭：`cwd` 排在超长正文之后，绝对位置越过 65536。
    /// （真实文件里它在第 486191 字节。）关键是**不能让 `cwd` 排到正文前面**——
    /// 那样它落在窗口内，官方接口自己就读到了，这条测试会变成什么都没测。
    /// 下面那句断言就是守着这一点的。
    func testWorkingDirectoryIsRecoveredWhenTheOfficialSummaryWindowMissesIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-oversized-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("projects/project-a")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let directory = "/tmp/中文 project"

        func line(_ record: [String: Any]) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            data.append(10)
            return data
        }
        var file = Data()
        for type in ["mode", "permission-mode", "atis-latch", "bridge-session", "file-history-snapshot"] {
            file.append(try line(["type": type, "sessionId": id]))
        }
        // 标题走单独一条小记录：超长那条被跳过后，会话仍要有名字，否则它根本不进列表。
        file.append(try line(["type": "ai-title", "sessionId": id, "aiTitle": "贴图开头的会话"]))
        // 这一条得手写：字段顺序就是这条测试的全部意义，`JSONSerialization` 不保证顺序。
        let body = String(repeating: "图", count: 200_000)
        let prefix = Data(("{\"type\":\"user\",\"sessionId\":\"\(id)\",\"parentUuid\":null,"
            + "\"isSidechain\":false,\"entrypoint\":\"cli\","
            + "\"timestamp\":\"2026-09-09T00:00:00Z\","
            + "\"message\":{\"role\":\"user\",\"content\":\"\(body)\"},").utf8)
        XCTAssertGreaterThan(file.count + prefix.count, 65_536,
                             "cwd 必须落在官方那 64KB 窗口之外，否则这条测试测不到东西")
        file.append(prefix)
        file.append(Data("\"cwd\":\"\(directory)\"}\n".utf8))
        file.append(try line(["type": "assistant", "sessionId": id, "uuid": UUID().uuidString,
            "timestamp": "2026-09-09T00:00:01Z",
            "message": ["role": "assistant", "content": "好的"]]))
        try file.write(to: project.appendingPathComponent("\(id).jsonl"))

        let source = SessionCatalogSource(agent: .claude, root: root, executable: "/missing/claude")
        let provider = ClaudeSessionCatalog(source: source, helperDirectory: helper)
        let page = try provider.page(archived: false, cursor: nil, cancelled: { false })
        let session = try XCTUnwrap(page.sessions.first { $0.key.nativeID == id })
        XCTAssertEqual(session.workingDirectory, directory)
    }

    /// 「目录记下来了但现在不在」和「压根没读出目录」是两回事，不能共用一句话。
    func testFolderPromptSeparatesAMissingFolderFromAnUnrecordedOne() throws {
        let existing = FileManager.default.temporaryDirectory.appendingPathComponent("resume-folder-\(UUID())")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: existing) }
        let file = existing.appendingPathComponent("not-a-folder")
        try Data().write(to: file)

        XCTAssertNil(SessionResumeFlow.folderPromptMessage(for: existing.path))
        let unrecorded = try XCTUnwrap(SessionResumeFlow.folderPromptMessage(for: nil))
        let missing = try XCTUnwrap(SessionResumeFlow.folderPromptMessage(for: existing.path + "/gone"))
        let notAFolder = try XCTUnwrap(SessionResumeFlow.folderPromptMessage(for: file.path))
        XCTAssertEqual(missing, notAFolder)
        XCTAssertNotEqual(unrecorded, missing, "没读出目录不能说成目录不存在")
    }
}

@MainActor
final class SessionLibraryPagingTests: XCTestCase {
    func testPagesMergeWithoutDuplicates() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-pages-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SessionLibrary(fileURL: root.appendingPathComponent("organization.json"), providers: [PagedFixture()])
        library.refresh()
        wait { !library.loading }
        XCTAssertEqual(library.records.map(\.title), ["first"])
        XCTAssertTrue(library.hasMore(archived: false))
        library.loadMore(archived: false)
        wait { !library.loading }
        XCTAssertEqual(Set(library.records.map(\.title)), ["first", "second"])
        XCTAssertFalse(library.hasMore(archived: false))
    }

    func testLaterPageFailureRetainsRowsAndRetryCursor() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SessionLibrary(fileURL: root.appendingPathComponent("organization.json"), providers: [PagedFixture(failSecond: true)])
        library.refresh()
        wait { !library.loading }
        library.loadMore(archived: false)
        wait { !library.loading }
        XCTAssertEqual(library.records.map(\.title), ["first"])
        XCTAssertTrue(library.hasMore(archived: false))
        XCTAssertNotNil(library.errors[.claude])
    }

    func testRefreshAndCancelIgnoreLateResults() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SessionLibrary(fileURL: root.appendingPathComponent("organization.json"), providers: [PagedFixture(delay: 0.05)])
        library.refresh()
        library.cancelLoading()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertTrue(library.records.isEmpty)
        XCTAssertFalse(library.loading)
        library.refresh()
        wait { !library.loading }
        XCTAssertEqual(library.records.count, 1)
        library.loadMore(archived: false)
        library.cancelLoading()
        library.loadMore(archived: false)
        wait { !library.loading }
        XCTAssertEqual(library.records.count, 2)
    }

    private func wait(_ ready: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !ready(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(ready())
    }
}

private struct PagedFixture: SessionCatalogProvider {
    var delay: TimeInterval = 0
    var failSecond = false
    let source = SessionCatalogSource(agent: .claude, root: URL(fileURLWithPath: "/fixture"), executable: "/claude")
    func page(archived: Bool, cursor: String?, cancelled: () -> Bool) throws -> SessionCatalogPage {
        if archived { return SessionCatalogPage(sessions: [], nextCursor: nil) }
        Thread.sleep(forTimeInterval: delay) // Deliberately returns late to exercise generation guard.
        if failSecond && cursor != nil { throw SessionCatalogError.timeout }
        let names = cursor == nil ? ["first"] : ["first", "second"]
        return SessionCatalogPage(sessions: names.map {
            AgentSession(key: .init(agent: .claude, sourceRoot: "/fixture", nativeID: $0), title: $0, workingDirectory: nil, updatedAt: nil)
        }, nextCursor: cursor == nil ? "next" : nil)
    }
}
