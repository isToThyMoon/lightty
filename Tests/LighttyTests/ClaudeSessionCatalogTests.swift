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
