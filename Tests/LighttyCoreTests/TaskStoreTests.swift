import XCTest
@testable import LighttyCore

final class TaskStoreTests: XCTestCase {

    var root: URL!
    var now: Date!

    override func setUpWithError() throws {
        // temporaryDirectory 在 macOS 上位于 /var（→ /private/var 符号链接），天然覆盖该陷阱
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lightty-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        now = utc("2026-08-22T10:00:00Z")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func makeStore(sub: String = "tasks") -> TaskStore {
        TaskStore(directory: root.appendingPathComponent(sub)) { self.now }
    }

    // MARK: - create

    func testCreateWritesSanitizedFile() throws {
        let store = makeStore()
        let created = try store.create(name: "修 a/b: 会话  管理", cwd: "/Users/me/p", tool: "claude")
        XCTAssertEqual(created.fileURL.lastPathComponent, "修 ab 会话 管理.md")
        XCTAssertEqual(created.task.name, "修 a/b: 会话  管理")
        XCTAssertEqual(created.task.status, .active)
        XCTAssertEqual(created.task.tool, "claude")
        XCTAssertEqual(created.task.created, now)
        XCTAssertEqual(created.task.updated, now)
        XCTAssertEqual(created.task.body, "")
        // 落盘内容可解析且一致
        let onDisk = try store.load(at: created.fileURL)
        XCTAssertEqual(onDisk, created.task)
    }

    func testCreateDuplicateNamesAppendSuffix() throws {
        let store = makeStore()
        let a = try store.create(name: "同名", cwd: "/x")
        let b = try store.create(name: "同名", cwd: "/x")
        let c = try store.create(name: "同/名", cwd: "/x") // 净化后同名
        XCTAssertEqual(a.fileURL.lastPathComponent, "同名.md")
        XCTAssertEqual(b.fileURL.lastPathComponent, "同名-2.md")
        XCTAssertEqual(c.fileURL.lastPathComponent, "同名-3.md")
    }

    func testCreateEmptyNameUsesTaskFallback() throws {
        let store = makeStore()
        let a = try store.create(name: "/:", cwd: "/x")
        XCTAssertEqual(a.fileURL.lastPathComponent, "task.md")
    }

    // MARK: - list

    func testListIgnoresDotfilesAndNonMarkdown() throws {
        let store = makeStore()
        try store.create(name: "甲", cwd: "/x")
        try store.create(name: "乙", cwd: "/x")
        try td("junk").write(to: store.directory.appendingPathComponent(".hidden.md"))
        try td("junk").write(to: store.directory.appendingPathComponent("notes.txt"))
        let result = store.list()
        XCTAssertEqual(result.tasks.map { $0.task.name }.sorted(), ["乙", "甲"])
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testListIsolatesInvalidFiles() throws {
        let store = makeStore()
        try store.create(name: "好的", cwd: "/x")
        let bad = store.directory.appendingPathComponent("坏的.md")
        try td("not frontmatter").write(to: bad)
        let result = store.list()
        XCTAssertEqual(result.tasks.map { $0.task.name }, ["好的"])
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures[0].fileURL.lastPathComponent, "坏的.md")
        XCTAssertTrue(result.failures[0].error is TaskParseError)
    }

    // MARK: - update

    func testUpdateWritesBackAndRefreshesUpdated() throws {
        let store = makeStore()
        let created = try store.create(name: "a", cwd: "/x")
        var task = created.task
        task.status = .done
        task.body = "收工记录\n"
        now = utc("2026-08-22T12:00:00Z")
        let updated = try store.update(at: created.fileURL, task: task)
        XCTAssertEqual(updated.status, .done)
        XCTAssertEqual(updated.updated, utc("2026-08-22T12:00:00Z"))
        XCTAssertEqual(updated.created, utc("2026-08-22T10:00:00Z"))
        let onDisk = try store.load(at: created.fileURL)
        XCTAssertEqual(onDisk, updated)
    }

    func testUpdatePreservesUnknownKeysAndBodyBytes() throws {
        // 手写一个带未知键、正文无结尾换行的文件，load → update 后须字节保真
        let store = makeStore()
        let url = store.directory.appendingPathComponent("外部.md")
        let raw = "---\nname: 外部\nstatus: active\ncwd: /x\ncreated: 2026-08-22T09:00:00Z\nupdated: 2026-08-22T09:00:00Z\nx-hook: v1\n---\n正文无换行结尾"
        try td(raw).write(to: url)
        var task = try store.load(at: url)
        task.status = .stuck
        let updated = try store.update(at: url, task: task)
        XCTAssertEqual(updated.unknownLines, ["x-hook: v1"])
        XCTAssertEqual(updated.body, "正文无换行结尾")
        let expected = "---\nname: 外部\nstatus: stuck\ncwd: /x\ncreated: 2026-08-22T09:00:00Z\nupdated: 2026-08-22T10:00:00Z\nx-hook: v1\n---\n正文无换行结尾"
        XCTAssertEqual(try Data(contentsOf: url), td(expected))
    }

    // MARK: - rename

    func testRenameMovesFileAndUpdatesName() throws {
        let store = makeStore()
        let created = try store.create(name: "旧名", cwd: "/x")
        now = utc("2026-08-22T11:00:00Z")
        let newURL = try store.rename(at: created.fileURL, to: "新/名: 字")
        XCTAssertEqual(newURL.lastPathComponent, "新名 字.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.fileURL.path))
        let moved = try store.load(at: newURL)
        XCTAssertEqual(moved.name, "新/名: 字")
        XCTAssertEqual(moved.updated, utc("2026-08-22T11:00:00Z"))
        XCTAssertEqual(moved.created, utc("2026-08-22T10:00:00Z"))
    }

    func testRenameCollisionAppendsSuffix() throws {
        let store = makeStore()
        try store.create(name: "占位", cwd: "/x")
        let created = try store.create(name: "自己", cwd: "/x")
        let newURL = try store.rename(at: created.fileURL, to: "占位")
        XCTAssertEqual(newURL.lastPathComponent, "占位-2.md")
    }

    func testRenameToSameSanitizedNameKeepsFile() throws {
        let store = makeStore()
        let created = try store.create(name: "同名", cwd: "/x")
        // "同名:" 净化后与现文件同名 → 原地写回，不产生 -2 后缀
        let newURL = try store.rename(at: created.fileURL, to: "同名:")
        XCTAssertEqual(newURL, created.fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.fileURL.path))
        XCTAssertEqual(try store.load(at: newURL).name, "同名:")
    }

    // MARK: - appendSession

    func testAppendSessionAppendsAndDedupes() throws {
        let store = makeStore()
        let created = try store.create(name: "a", cwd: "/x")
        now = utc("2026-08-22T11:00:00Z")
        let one = try store.appendSession(at: created.fileURL, tool: "claude", id: "s1")
        XCTAssertEqual(one.sessions, [TaskSession(tool: "claude", id: "s1")])
        XCTAssertEqual(one.updated, utc("2026-08-22T11:00:00Z"))
        // tool+id 相同：去重，不重复写入、不刷新 updated
        now = utc("2026-08-22T12:00:00Z")
        let dup = try store.appendSession(at: created.fileURL, tool: "claude", id: "s1")
        XCTAssertEqual(dup.sessions.count, 1)
        XCTAssertEqual(dup.updated, utc("2026-08-22T11:00:00Z"))
        // 不同 id 追加
        let two = try store.appendSession(at: created.fileURL, tool: "claude", id: "s2")
        XCTAssertEqual(two.sessions, [
            TaskSession(tool: "claude", id: "s1"),
            TaskSession(tool: "claude", id: "s2"),
        ])
        XCTAssertEqual(try store.load(at: created.fileURL).sessions, two.sessions)
    }

    // MARK: - 原子写与符号链接

    func testNoTempFileResidue() throws {
        let store = makeStore()
        let created = try store.create(name: "a", cwd: "/x")
        var task = created.task
        task.status = .done
        try store.update(at: created.fileURL, task: task)
        try store.appendSession(at: created.fileURL, tool: "t", id: "i")
        try store.rename(at: created.fileURL, to: "b")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
            .filter { $0.hasPrefix(".") || $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }

    func testDirectorySymlinksResolved() throws {
        // 显式符号链接指向真实目录，store 须解析到真实路径
        let real = root.appendingPathComponent("real-tasks")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link-tasks")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let store = TaskStore(directory: link) { self.now }
        XCTAssertEqual(store.directory.path, store.directory.resolvingSymlinksInPath().path)
        let created = try store.create(name: "a", cwd: "/x")
        XCTAssertTrue(created.fileURL.path.hasPrefix(store.directory.path))
        // list 返回的路径与 create 一致（不受 /var vs /private/var 影响）
        XCTAssertEqual(store.list().tasks.map { $0.fileURL }, [created.fileURL])
    }

    func testInitCreatesMissingDirectory() throws {
        let dir = root.appendingPathComponent("nested/tasks")
        _ = TaskStore(directory: dir) { self.now }
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }
}
