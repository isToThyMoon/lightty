import XCTest
@testable import LighttyCore

/// 任务绑定的唯一所有者：终端 ↔ 任务文件、指针文件、任务文件生命周期对绑定的传导。
/// 全程不建视图：指针走内存 adapter，删除走注入的废纸篓，目录变更走手动触发的 adapter，
/// 变更走独立的 NotificationCenter。
final class TaskBindingsTests: XCTestCase {
    private var root: URL!
    private var store: TaskStore!
    private var pointers: InMemoryTaskPointerStore!
    private var center: NotificationCenter!
    private var bindings: TaskBindings!
    private var changes: [TaskBindingChange] = []
    private var trashed: [URL] = []
    private var trashFailure: Error?
    private var observer: NSObjectProtocol?
    private var folder: ManualTaskFolderChanges!
    private var taskListChanges = 0
    private var taskListObserver: NSObjectProtocol?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lightty-bindings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = TaskStore(directory: root.appendingPathComponent("tasks"), trash: { [unowned self] url in
            if let trashFailure { throw trashFailure }
            trashed.append(url)
            try FileManager.default.removeItem(at: url)
        })
        pointers = InMemoryTaskPointerStore()
        center = NotificationCenter()
        folder = ManualTaskFolderChanges()
        bindings = TaskBindings(store: store, pointers: pointers, notificationCenter: center,
                                folderChanges: folder.source)
        observer = center.addObserver(forName: .lighttyTaskBindingsDidChange, object: bindings, queue: nil) {
            [unowned self] note in
            if let change = TaskBindingChange.from(note) { changes.append(change) }
        }
        taskListObserver = center.addObserver(forName: .lighttyTasksDidChange, object: bindings, queue: nil) {
            [unowned self] _ in taskListChanges += 1
        }
    }

    override func tearDownWithError() throws {
        if let observer { center.removeObserver(observer) }
        if let taskListObserver { center.removeObserver(taskListObserver) }
        try? FileManager.default.removeItem(at: root)
    }

    private func makeTask(_ name: String) throws -> URL {
        try store.create(name: name, workdir: root.path).fileURL
    }

    // MARK: - 绑定与查询

    func testSeveralPanesCanBindTheSameTask() throws {
        let task = try makeTask("shared")
        let (first, second) = (UUID(), UUID())
        bindings.bind(first, to: task, name: "shared")
        bindings.bind(second, to: task, name: "shared")

        XCTAssertEqual(bindings.panes(for: task), [first, second])
        XCTAssertTrue(bindings.isOpen(task))
        XCTAssertEqual(bindings.task(for: first), BoundTask(fileURL: task, name: "shared"))
        XCTAssertEqual(pointers.pointers, [first: task.path, second: task.path])

        bindings.unbind(first)
        XCTAssertEqual(bindings.panes(for: task), [second], "解绑一个终端不影响同任务的其他终端")
        XCTAssertTrue(bindings.isOpen(task))
        XCTAssertNil(bindings.task(for: first))
        XCTAssertEqual(pointers.pointers, [second: task.path])
    }

    func testQueriesMatchEquivalentFileURLs() throws {
        let task = try makeTask("dotted")
        let pane = UUID()
        let spelled = task.deletingLastPathComponent()
            .appendingPathComponent(".", isDirectory: true)
            .appendingPathComponent(task.lastPathComponent)
        bindings.bind(pane, to: spelled, name: "dotted")
        XCTAssertEqual(bindings.panes(for: task), [pane])
        XCTAssertEqual(bindings.task(for: pane)?.fileURL, spelled, "绑定保留调用方给的 URL，快照原样写回")
    }

    func testRemovingAPaneDropsItsBindingWithoutTouchingPointerFiles() throws {
        let task = try makeTask("closing")
        let (bound, unbound) = (UUID(), UUID())
        bindings.bind(bound, to: task, name: "closing")
        changes.removeAll()

        bindings.removePane(unbound)
        XCTAssertTrue(changes.isEmpty, "没绑任务的终端关掉不算绑定变化")

        bindings.removePane(bound)
        XCTAssertFalse(bindings.isOpen(task))
        XCTAssertEqual(pointers.pointers[bound], task.path, "运行时目录随终端注销整体删除，这里不重复动磁盘")
        XCTAssertEqual(changes, [TaskBindingChange(
            cause: .paneRemoved,
            panes: [bound: .init(before: BoundTask(fileURL: task, name: "closing"), after: nil)],
            tasks: [task.standardizedFileURL])])
    }

    // MARK: - 变更事件

    func testBindRebindAndUnbindPublishTypedChanges() throws {
        let a = try makeTask("a"), b = try makeTask("b")
        let pane = UUID()
        bindings.bind(pane, to: a, name: "a")
        bindings.bind(pane, to: b, name: "b")
        bindings.unbind(pane)

        let taskA = BoundTask(fileURL: a, name: "a"), taskB = BoundTask(fileURL: b, name: "b")
        XCTAssertEqual(changes, [
            TaskBindingChange(cause: .bind, panes: [pane: .init(before: nil, after: taskA)],
                              tasks: [a.standardizedFileURL]),
            TaskBindingChange(cause: .bind, panes: [pane: .init(before: taskA, after: taskB)],
                              tasks: [a.standardizedFileURL, b.standardizedFileURL]),
            TaskBindingChange(cause: .unbind, panes: [pane: .init(before: taskB, after: nil)],
                              tasks: [b.standardizedFileURL]),
        ])
    }

    func testRebindingKeepsTheHookMarkerButUnbindingClearsIt() throws {
        let a = try makeTask("a"), b = try makeTask("b")
        let pane = UUID()
        bindings.bind(pane, to: a, name: "a")
        pointers.recordInjection(for: pane, session: "s1", path: a.path)
        bindings.bind(pane, to: b, name: "b")
        XCTAssertNotNil(pointers.markers[pane], "换绑不删标记：路径变了 hook 自己会重注")
        XCTAssertEqual(pointers.pointers[pane], b.path)

        bindings.unbind(pane)
        XCTAssertNil(pointers.pointers[pane])
        XCTAssertNil(pointers.markers[pane], "解绑连去重标记一起删，绑回同一任务才会重注")
    }

    func testCreatingATaskCanBindItToAPane() throws {
        let pane = UUID()
        let created = try bindings.createTask(name: "fresh", workdir: root.path, bindingTo: pane)
        XCTAssertEqual(try store.load(at: created.fileURL).name, "fresh")
        XCTAssertEqual(bindings.panes(for: created.fileURL), [pane])
        XCTAssertEqual(pointers.pointers[pane], created.fileURL.path)
        let bound = BoundTask(fileURL: created.fileURL, name: "fresh")
        XCTAssertEqual(changes, [TaskBindingChange(cause: .create, panes: [pane: .init(before: nil, after: bound)],
                                                   tasks: [created.fileURL.standardizedFileURL])])

        changes.removeAll()
        let unboundTask = try bindings.createTask(name: "later", workdir: root.path, body: "notes")
        XCTAssertFalse(bindings.isOpen(unboundTask.fileURL))
        XCTAssertEqual(try store.load(at: unboundTask.fileURL).body, "notes")
        XCTAssertEqual(changes, [TaskBindingChange(cause: .create, panes: [:],
                                                   tasks: [unboundTask.fileURL.standardizedFileURL])])
    }

    // MARK: - 任务文件生命周期的传导

    func testArchiveUnbindsEveryBoundPane() throws {
        let task = try makeTask("archive me"), other = try makeTask("other")
        let (first, second, bystander) = (UUID(), UUID(), UUID())
        bindings.bind(first, to: task, name: "archive me")
        bindings.bind(second, to: task, name: "archive me")
        bindings.bind(bystander, to: other, name: "other")
        pointers.recordInjection(for: first, session: "s1", path: task.path)
        pointers.recordInjection(for: bystander, session: "s2", path: other.path)
        changes.removeAll()

        let archived = try bindings.archiveTask(at: task)
        XCTAssertEqual(archived.deletingLastPathComponent().standardizedFileURL,
                       store.archiveDirectory.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.path))
        XCTAssertTrue(bindings.panes(for: task).isEmpty)
        XCTAssertFalse(bindings.isOpen(task))
        XCTAssertNil(pointers.pointers[first])
        XCTAssertNil(pointers.pointers[second])
        XCTAssertNil(pointers.markers[first])
        XCTAssertEqual(pointers.pointers[bystander], other.path, "别的任务的终端不受影响")
        XCTAssertNotNil(pointers.markers[bystander])

        let bound = BoundTask(fileURL: task, name: "archive me")
        XCTAssertEqual(changes, [TaskBindingChange(
            cause: .archive,
            panes: [first: .init(before: bound, after: nil), second: .init(before: bound, after: nil)],
            tasks: [task.standardizedFileURL])], "一次归档只发一条变更，覆盖全部终端")
    }

    func testDeleteGoesThroughTaskStoreAndUnbindsEveryPane() throws {
        let task = try makeTask("delete me")
        let (first, second) = (UUID(), UUID())
        bindings.bind(first, to: task, name: "delete me")
        bindings.bind(second, to: task, name: "delete me")
        changes.removeAll()

        try bindings.deleteTask(at: task)
        XCTAssertEqual(trashed, [task], "删除经 TaskStore 的废纸篓操作，不直接删文件")
        XCTAssertFalse(bindings.isOpen(task))
        XCTAssertTrue(pointers.pointers.isEmpty)
        XCTAssertEqual(changes.map(\.cause), [.delete])
        XCTAssertEqual(Set(changes.first.map { Array($0.panes.keys) } ?? []), [first, second])
    }

    func testFailedDeleteLeavesBindingsAlone() throws {
        let task = try makeTask("stubborn")
        let pane = UUID()
        bindings.bind(pane, to: task, name: "stubborn")
        changes.removeAll()
        trashFailure = CocoaError(.fileWriteNoPermission)

        XCTAssertThrowsError(try bindings.deleteTask(at: task))
        XCTAssertEqual(bindings.panes(for: task), [pane])
        XCTAssertEqual(pointers.pointers[pane], task.path)
        XCTAssertTrue(changes.isEmpty)
    }

    func testRenameRetargetsEveryBoundPane() throws {
        let task = try makeTask("old name")
        let (first, second) = (UUID(), UUID())
        bindings.bind(first, to: task, name: "old name")
        bindings.bind(second, to: task, name: "old name")
        pointers.recordInjection(for: first, session: "s1", path: task.path)
        changes.removeAll()

        let renamed = try bindings.renameTask(at: task, to: "new name")
        XCTAssertNotEqual(renamed, task)
        XCTAssertEqual(try store.load(at: renamed).name, "new name")
        let expected = BoundTask(fileURL: renamed, name: "new name")
        XCTAssertEqual(bindings.task(for: first), expected)
        XCTAssertEqual(bindings.task(for: second), expected)
        XCTAssertTrue(bindings.panes(for: task).isEmpty)
        XCTAssertEqual(bindings.panes(for: renamed), [first, second])
        XCTAssertEqual(pointers.pointers, [first: renamed.path, second: renamed.path], "hook 要读到新的回写地址")
        XCTAssertNotNil(pointers.markers[first], "改名不删标记：路径变了 hook 自己会重注")

        let before = BoundTask(fileURL: task, name: "old name")
        XCTAssertEqual(changes, [TaskBindingChange(
            cause: .rename,
            panes: [first: .init(before: before, after: expected), second: .init(before: before, after: expected)],
            tasks: [task.standardizedFileURL, renamed.standardizedFileURL])])
    }

    // MARK: - 任务目录变更

    func testWatchesTheStoreDirectoryAndPublishesOneTaskListChangePerFolderChange() throws {
        XCTAssertEqual(folder.directory, store.directory)
        let task = try makeTask("untouched")
        bindings.bind(UUID(), to: task, name: "untouched")
        changes.removeAll()

        folder.fire()
        XCTAssertEqual(taskListChanges, 1, "目录事件的防抖归变更源，这里一次事件一条通知")
        XCTAssertTrue(changes.isEmpty, "名字没变不算绑定变化")

        folder.fire()
        XCTAssertEqual(taskListChanges, 2)
    }

    func testAnExternalRenameReachesEveryBoundPane() throws {
        let task = try makeTask("before"), bystander = try makeTask("bystander")
        let (first, second) = (UUID(), UUID())
        bindings.bind(first, to: task, name: "before")
        bindings.bind(second, to: task, name: "before")
        bindings.bind(UUID(), to: bystander, name: "bystander")
        let unbound = try makeTask("unbound")
        changes.removeAll()

        // 外部改的是 frontmatter 里的 name，文件路径不变。
        for (url, name) in [(task, "after"), (unbound, "unbound renamed")] {
            var file = try store.load(at: url)
            file.name = name
            try store.update(at: url, task: file)
        }
        folder.fire()

        let before = BoundTask(fileURL: task, name: "before"), after = BoundTask(fileURL: task, name: "after")
        XCTAssertEqual(bindings.task(for: first), after)
        XCTAssertEqual(bindings.task(for: second), after)
        XCTAssertEqual(pointers.pointers[first], task.path, "路径没变，指针不动")
        XCTAssertEqual(changes, [TaskBindingChange(
            cause: .rename,
            panes: [first: .init(before: before, after: after), second: .init(before: before, after: after)],
            tasks: [task.standardizedFileURL])], "只比较已绑定的任务，没绑的改名只刷新列表")
        XCTAssertEqual(taskListChanges, 1)
    }

    func testABoundFileThatVanishesOrCannotBeReadStaysBound() throws {
        let vanished = try makeTask("vanished"), garbled = try makeTask("garbled")
        let (a, b) = (UUID(), UUID())
        bindings.bind(a, to: vanished, name: "vanished")
        bindings.bind(b, to: garbled, name: "garbled")
        changes.removeAll()

        // 交接协议的「临时文件 + mv」之间文件可能短暂不在，也可能读到别人写坏的内容。
        try FileManager.default.removeItem(at: vanished)
        try Data("not a task".utf8).write(to: garbled)
        folder.fire()

        XCTAssertEqual(bindings.task(for: a), BoundTask(fileURL: vanished, name: "vanished"))
        XCTAssertEqual(bindings.task(for: b), BoundTask(fileURL: garbled, name: "garbled"))
        XCTAssertEqual(pointers.pointers, [a: vanished.path, b: garbled.path])
        XCTAssertTrue(changes.isEmpty, "读不出来不算改名，也不解绑")
        XCTAssertEqual(taskListChanges, 1)
    }

    func testAChangeFromAnotherThreadArrivesOnTheMainThread() throws {
        let arrived = expectation(description: "task list change on main")
        let observer = center.addObserver(forName: .lighttyTasksDidChange, object: bindings, queue: nil) { _ in
            XCTAssertTrue(Thread.isMainThread)
            arrived.fulfill()
        }
        defer { center.removeObserver(observer) }
        DispatchQueue.global().async { [folder] in folder!.fire() }
        wait(for: [arrived], timeout: 2)
    }

    func testReleasingTheBindingsStopsWatching() throws {
        XCTAssertNotNil(folder.token)
        if let observer { center.removeObserver(observer) }
        if let taskListObserver { center.removeObserver(taskListObserver) }
        observer = nil
        taskListObserver = nil
        bindings = nil
        XCTAssertNil(folder.token, "监听凭据随 TaskBindings 释放，大量创建不泄漏监听")
        folder.fire()  // 迟到的回调：静默
    }

    func testAFolderThatCannotBeWatchedStillWorks() throws {
        let broken = ManualTaskFolderChanges()
        broken.failure = CocoaError(.fileNoSuchFile)
        let unwatched = TaskBindings(store: store, pointers: pointers, notificationCenter: center,
                                     folderChanges: broken.source)
        let task = try makeTask("still bindable")
        let pane = UUID()
        unwatched.bind(pane, to: task, name: "still bindable")
        XCTAssertEqual(unwatched.task(for: pane)?.name, "still bindable")
    }

    /// 真实 adapter：Agent 按交接协议「写点开头的临时文件，再 mv 到任务文件」，
    /// 经 `TaskFolderWatcher` 防抖后到达一次。
    func testTheRealWatcherTurnsATempFileAndMoveIntoOneTaskListChange() throws {
        let watched = TaskBindings(store: store, pointers: pointers, notificationCenter: center)
        var arrivals = 0
        let observer = center.addObserver(forName: .lighttyTasksDidChange, object: watched, queue: nil) { _ in
            XCTAssertTrue(Thread.isMainThread)
            arrivals += 1
        }
        defer { center.removeObserver(observer) }

        let temp = store.directory.appendingPathComponent(".handoff.tmp")
        try TaskFile(name: "agent wrote", workdir: root.path, created: Date(), updated: Date())
            .serialize().write(to: temp)
        try FileManager.default.moveItem(at: temp, to: store.directory.appendingPathComponent("agent wrote.md"))

        let deadline = Date().addingTimeInterval(3)
        while arrivals == 0, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))  // 再等一个防抖窗口，确认没有第二次
        XCTAssertEqual(arrivals, 1)
        withExtendedLifetime(watched) {}
    }

    // MARK: - 磁盘 adapter

    func testDiskPointerStoreWritesAndClearsHookFiles() throws {
        let runtime = root.appendingPathComponent("panes", isDirectory: true)
        let disk = DiskTaskPointerStore(root: runtime)
        let pane = UUID()
        let id = pane.uuidString
        let task = root.appendingPathComponent("tasks/some task.md")

        disk.write(taskFile: task, for: pane)
        let pointer = PaneRuntimeDirectory.taskPointerFile(for: id, root: runtime)
        XCTAssertEqual(pointer.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL,
                       runtime.standardizedFileURL)
        XCTAssertEqual(try String(contentsOf: pointer, encoding: .utf8), task.path + "\n",
                       "hook 读的是一行绝对路径")
        XCTAssertEqual(try String(contentsOf: PaneRuntimeDirectory.ownerPIDFile(for: id, root: runtime), encoding: .utf8),
                       "\(getpid())\n", "目录顺带落 owner.pid，供 sweepStale 判活")

        let marker = PaneRuntimeDirectory.handoffMarkerFile(for: id, root: runtime)
        try PaneRuntimeDirectory.atomicWrite(Data("s1\n\(task.path)\n".utf8), to: marker)
        disk.clear(for: pane)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pointer.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        disk.clear(for: UUID())  // 从没写过：静默
    }
}
