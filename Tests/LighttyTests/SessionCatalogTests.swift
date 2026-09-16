import AppKit
import XCTest
import LighttyCore
@testable import lightty

final class SessionCatalogTests: XCTestCase {
    func testCodexDecodeUsesThreadIDAndSecondsAndExcludesDesktop() throws {
        let source = SessionCatalogSource(agent: .codex, root: URL(fileURLWithPath: "/config"), executable: "/bin/codex", configuration: .custom("/config"))
        let page: [String: Any] = ["data": [
            ["id": "thread-1", "sessionId": "shared-tree", "source": "cli", "cwd": "/repo", "updatedAt": 1000.0, "preview": "Preview"],
            ["id": "desktop-1", "source": "appServer"],
            ["id": "ide-1", "source": "vscode"],
        ]]
        let rows = try CodexSessionProvider.decode(page, source: source, archived: false)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.key.nativeID, "thread-1")
        XCTAssertEqual(rows.first?.updatedAt, Date(timeIntervalSince1970: 1000))
        XCTAssertThrowsError(try CodexSessionProvider.decode([:], source: source, archived: false))
    }

    func testInstalledCodexReadsOnlySyntheticCLIHistory() throws {
        guard let executable = HookInstaller.locateExecutable("codex") else { throw XCTSkip("Codex CLI not installed") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("sessions/2026/09/07")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var expected = Set<String>()
        for index in 0..<3 {
            let id = UUID().uuidString.lowercased()
            if index < 2 { expected.insert(id) }
            let stamp = "2026-09-07T00:00:0\(index).000Z"
            let lines: [[String: Any]] = [
                ["timestamp": stamp, "type": "session_meta", "payload": [
                    "id": id, "timestamp": stamp, "cwd": root.path,
                    "originator": "lightty-test", "cli_version": "0.153.4",
                    "source": index < 2 ? "cli" : "vscode", "model_provider": "openai",
                ]],
                ["timestamp": stamp, "type": "event_msg", "payload": [
                    "type": "user_message", "message": "Synthetic test", "images": [],
                ]],
            ]
            let data = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
            try data.write(to: directory.appendingPathComponent("rollout-2026-09-07T00-00-0\(index)-\(id).jsonl"), atomically: true, encoding: .utf8)
        }
        let provider = CodexSessionProvider(source: .init(agent: .codex, root: root, executable: executable, configuration: .custom(root.path)))
        let records = try provider.sessions(archived: false, cancelled: { false })
        XCTAssertEqual(Set(records.map(\.key.nativeID)), expected)
        XCTAssertTrue(records.allSatisfy { $0.workingDirectory == root.path })
        XCTAssertTrue(try provider.sessions(archived: true, cancelled: { false }).isEmpty)
        XCTAssertThrowsError(try provider.sessions(archived: false, cancelled: { true }))
    }
}

@MainActor
final class PrimarySidebarTests: XCTestCase {
    func testMoveToRecentMenuOnlyAppearsForProjectMembers() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SessionLibrary(fileURL: root.appendingPathComponent("organization.json"), providers: [])
        let content = SessionsSidebarContent(library: library)
        try waitUntil("condition") { library.organizationReady }
        let record = AgentSession(key: .init(agent: .claude, sourceRoot: root.path, nativeID: "fixture"),
                                  title: "Fixture", workingDirectory: root.path, updatedAt: nil)
        let title = L("Move to recent sessions")
        XCTAssertFalse(content.sessionMenuItems(record, anchor: NSView()).contains { $0.title == title })
        let emptyProjectMenu = ShellMenuPopover.visibleItems(content.sessionMenuItems(record, anchor: NSView()))
        for (previous, next) in zip(emptyProjectMenu, emptyProjectMenu.dropFirst()) {
            if case .separator = previous.kind, case .separator = next.kind {
                XCTFail("An empty project group must not leave adjacent separators")
            }
        }
        if let path = ProcessInfo.processInfo.environment["LIGHTTY_UI_SNAPSHOT_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let menu = ShellMenuController(items: emptyProjectMenu)
                let host = MenuPreviewBackdrop()
                host.appearance = NSAppearance(named: appearance)
                host.addSubview(menu.view)
                let size = menu.view.fittingSize
                host.frame = NSRect(origin: .zero, size: size)
                menu.view.frame = host.bounds
                host.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(
                    to: directory.appendingPathComponent("session-menu-\(appearance.rawValue).png"))
            }
        }
        let project = SessionProject(name: "Project")
        library.updateOrganization {
            $0.projects = [project]
            $0.move(record, to: project.id)
        }
        try waitUntil("condition") { !library.saving }
        let item = try XCTUnwrap(content.sessionMenuItems(record, anchor: NSView()).first { $0.title == title })
        guard case .action(let action) = item.kind else { return XCTFail("Expected move action") }
        action()
        try waitUntil("condition") { !library.saving }
        XCTAssertNil(library.organization.projectID(for: record))
        XCTAssertFalse(content.sessionMenuItems(record, anchor: NSView()).contains { $0.title == title })
    }

    /// 关着的会话也能改名——走官方接口，不需要先把会话开起来（见 `SessionRename`）。
    func testRenameIsOfferedForSessionsThatAreNotOpen() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SessionLibrary(fileURL: root.appendingPathComponent("organization.json"), providers: [])
        let content = SessionsSidebarContent(library: library)
        try waitUntil("condition") { library.organizationReady }
        let record = AgentSession(key: .init(agent: .claude, sourceRoot: root.path, nativeID: "fixture"),
                                  title: "Fixture", workingDirectory: root.path, updatedAt: nil)
        let items = content.sessionMenuItems(record, anchor: NSView())
        XCTAssertTrue(items.contains { $0.title == L("Rename session…") })
        // 没打开的会话给的是三个打开方式，不是「显示终端」。
        XCTAssertTrue(items.contains { $0.title == L("Continue in new tab") })
        XCTAssertFalse(items.contains { $0.title == L("Show terminal") })
    }

    /// 按住一行时 AppKit 会把它报成「深色重点底」，行里的模板图标和 SF Symbol 随之
    /// 反白——而这套侧栏的选中底一直是浅灰，图标就此消失。文字不受影响（各有写死的
    /// 颜色），所以只能盯图标。
    func testPressedRowKeepsItsIconsVisibleOnTheLightSelectionFill() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pressed-row-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SessionLibrary(fileURL: root.appendingPathComponent("organization.json"),
                                     providers: [FixtureCatalog(root: root)])
        let content = SessionsSidebarContent(library: library)
        library.start(); content.activate()
        try waitUntil("condition") { library.organizationReady && !library.loading }
        let table = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first)
        let row = try XCTUnwrap(content.tableView(table, rowViewForRow: 3))
        let cell = try XCTUnwrap(content.tableView(table, viewFor: nil, row: 3) as? NSTableCellView)
        row.frame = NSRect(x: 0, y: 0, width: 260, height: 56)
        cell.frame = row.bounds
        row.addSubview(cell)
        row.appearance = NSAppearance(named: .aqua)
        row.isSelected = true
        row.isEmphasized = true
        row.layoutSubtreeIfNeeded()
        XCTAssertEqual(row.interiorBackgroundStyle, .normal,
                       "Light selection fill must never ask AppKit to invert the row's contents")
        let icon = try XCTUnwrap(descendants(cell).compactMap { $0 as? NSImageView }
            .first { $0.image != nil && !$0.isHidden })
        let bitmap = try XCTUnwrap(row.bitmapImageRepForCachingDisplay(in: row.bounds))
        row.cacheDisplay(in: row.bounds, to: bitmap)
        // 位图按屏幕缩放取样，且原点在左上；视图坐标是左下，得换算。
        let scale = CGFloat(bitmap.pixelsWide) / row.bounds.width
        let frame = icon.convert(icon.bounds, to: row)
        var darkest = 1.0
        for x in Int(frame.minX * scale)..<Int(frame.maxX * scale) {
            for y in Int((row.bounds.height - frame.maxY) * scale)..<Int((row.bounds.height - frame.minY) * scale)
            where bitmap.pixelsWide > x && bitmap.pixelsHigh > y {
                if let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    darkest = min(darkest, Double(colour.brightnessComponent))
                }
            }
        }
        XCTAssertLessThan(darkest, 0.7, "Agent icon washed out to white on the pressed row")
    }

    func testProjectRowsAreDisclosureOnlyNotSelectable() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-selection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SessionLibrary(fileURL: root.appendingPathComponent("organization.json"), providers: [FixtureCatalog(root: root)])
        let content = SessionsSidebarContent(library: library)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = content
        library.start(); content.activate()
        try waitUntil("condition") { library.organizationReady && !library.loading }
        library.updateOrganization { $0.projects = [SessionProject(name: "Project")] }
        try waitUntil("condition") { !library.saving }
        let table = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first)
        XCTAssertFalse(content.tableView(table, shouldSelectRow: 1), "A project toggles its members; it isn't a selected destination")
        content.layoutSubtreeIfNeeded()
        let rowView = try XCTUnwrap(table.rowView(atRow: 1, makeIfNecessary: true))
        let point = table.convert(NSPoint(x: 60, y: table.rect(ofRow: 1).midY), to: nil)
        for expected in [true, false] {
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                modifierFlags: [], timestamp: up.timestamp, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            NSApp.postEvent(up, atStart: true)
            table.mouseDown(with: down)
            try waitUntil("condition") { !library.saving }
            XCTAssertEqual(library.organization.projects[0].collapsed, expected)
            XCTAssertEqual(table.selectedRow, -1)
            XCTAssertFalse(rowView.isSelected)
            XCTAssertEqual(rowView.interiorBackgroundStyle, .normal)
        }
    }

    func testProjectDisclosureKeepsUnchangedVisibleCellsThroughSaveNotifications() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-flicker-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SessionLibrary(fileURL: root.appendingPathComponent("organization.json"), providers: [FixtureCatalog(root: root)])
        let content = SessionsSidebarContent(library: library)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = content
        library.start(); content.activate()
        try waitUntil("condition") { library.organizationReady && !library.loading }
        library.updateOrganization { $0.projects = [SessionProject(name: "Empty project")] }
        try waitUntil("condition") { !library.saving }
        content.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first)
        let recentCell = try XCTUnwrap(table.view(atColumn: 0, row: 3, makeIfNecessary: true))
        table.selectRowIndexes([1], byExtendingSelection: false)
        XCTAssertTrue(table.sendAction(table.action, to: table.target))
        XCTAssertTrue(table.view(atColumn: 0, row: 3, makeIfNecessary: true) === recentCell,
                      "Saving state must not tear down unrelated visible cells")
        try waitUntil("condition") { !library.saving }
        XCTAssertTrue(table.view(atColumn: 0, row: 3, makeIfNecessary: true) === recentCell,
                      "An empty project's disclosure must only update its own icon")
        content.toggleProjects()
        XCTAssertTrue(table.view(atColumn: 0, row: 2, makeIfNecessary: true) === recentCell,
                      "Collapsing the project section must retain recent-session cells")
    }

    func testRapidDisclosureKeepsRowsAndAnimatedChevronInSync() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-animation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SessionLibrary(fileURL: root.appendingPathComponent("organization.json"), providers: [FixtureCatalog(root: root)])
        let content = SessionsSidebarContent(library: library)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = content
        library.start(); content.activate()
        try waitUntil("condition") { library.organizationReady && !library.loading }
        library.updateOrganization { state in
            let project = SessionProject(name: "Project")
            state.projects = [project]
            for record in library.records { state.move(record, to: project.id) }
        }
        try waitUntil("condition") { !library.saving }
        content.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first)
        let button = try XCTUnwrap(descendants(content).compactMap { $0 as? SidebarDisclosureButton }.first)
        XCTAssertEqual(table.numberOfRows, 5)
        for index in 0..<12 {
            content.toggleProjects()
            let expanded = index % 2 == 1
            XCTAssertEqual(button.expanded, expanded)
            XCTAssertEqual(table.numberOfRows, expanded ? 5 : 2)
            XCTAssertFalse(library.loading)
        }
        // 让最后一次展开的折叠钮动画走完，后面对下一层折叠钮的断言不受它影响。
        try waitUntil("disclosure animation finished") { button.disclosureLayer?.animation(forKey: "disclosure") == nil }
        XCTAssertTrue(button.expanded)
        XCTAssertEqual(table.numberOfRows, 5)
        if let path = ProcessInfo.processInfo.environment["LIGHTTY_UI_SNAPSHOT_DIR"] {
            // 这条分支要拿 screencapture 抓窗口像素，必须真的上屏：alpha 0 或挪到屏外
            // 的窗口 `screencapture -l` 都静默不产出文件（实测）。它只在显式开启快照
            // 目录时执行，普通 `swift test` 走不到，所以不经 orderFrontInvisibly。
            window.orderFront(nil)
            window.display()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber), path + "/disclosure-expanded.png"]
            try capture.run(); capture.waitUntilExit()
            content.toggleProjects()
            RunLoop.main.run(until: Date().addingTimeInterval(ShellStyle.animationDuration + 0.05))
            let collapsed = Process()
            collapsed.executableURL = capture.executableURL
            collapsed.arguments = ["-x", "-l", String(window.windowNumber), path + "/disclosure-collapsed.png"]
            try collapsed.run(); collapsed.waitUntilExit()
            content.toggleProjects()
            RunLoop.main.run(until: Date().addingTimeInterval(ShellStyle.animationDuration + 0.05))
            window.orderOut(nil)
        }
        // A concrete project's members animate independently of the outer section.
        table.selectRowIndexes([1], byExtendingSelection: false)
        XCTAssertTrue(table.sendAction(table.action, to: table.target))
        try waitUntil("condition") { !library.saving }
        XCTAssertEqual(table.numberOfRows, 3)
        XCTAssertTrue(button.expanded)
    }

    /// 「在读」由刷新按钮自己表达——它变成取消，读完翻回刷新。读取期间列表不位移、
    /// 缓存的行仍然可见；新开一个视图（搜索面板、再开一个侧栏）复用已读的目录，
    /// 不驱动模型再同步一次。
    func testRefreshKeepsCachedRowsAndLayoutWhileLoading() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("session-spinner-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        // 让读取真的占住一点时间，否则「开始读」和「读完」落进同一拍，翻成取消的那一拍看不到。
        let library = SessionLibrary(fileURL: root.appendingPathComponent("organization.json"),
            providers: [FixtureCatalog(root: root, delay: 0.2),
                        FixtureCatalog(root: root, agent: .claude, delay: 0.2)])
        let content = SessionsSidebarContent(library: library)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        let heading = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == L("Recent sessions") })
        let header = try XCTUnwrap(heading.superview?.superview)
        let refresh = try XCTUnwrap(descendants(header).compactMap { $0 as? NSButton }
            .first { [L("Refresh"), L("Cancel")].contains($0.toolTip ?? "") })
        XCTAssertEqual(refresh.toolTip, L("Refresh"))

        library.start(); content.activate()
        try waitUntil("first load finished") { library.loaded && !library.loading }
        try waitUntil("button back to refresh") { refresh.toolTip == L("Refresh") }
        content.layoutSubtreeIfNeeded()
        let list = try XCTUnwrap(descendants(content).compactMap { $0 as? SidebarListScrollView }.first)
        let frame = list.frame
        let records = library.records
        XCTAssertFalse(records.isEmpty)

        let search = SessionsSidebarContent(library: library, searchMode: true)
        library.start(); search.activate()
        XCTAssertFalse(library.loading, "Search should reuse the already loaded catalog")

        library.refresh()
        XCTAssertTrue(library.loading)
        // 会话库通知合流到下一拍再重算（见 `Coalescer`），所以按钮晚一拍翻。
        // 顺序是确定的：`refresh()` 先把重算排进主队列，provider 的完成回调排在它后面。
        // 真实 app 里主 runloop 一直在转，这一拍是几微秒，看不出来。
        try waitUntil("button flips to cancel") { refresh.toolTip == L("Cancel") }
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(refresh.toolTip, L("Cancel"), "在读时这个按钮就是取消")
        XCTAssertEqual(list.frame, frame, "A loading status must not move or resize the list")
        XCTAssertEqual(content.frame.width, 280, "Status text must not expand the sidebar/window")
        XCTAssertEqual(library.records, records, "Cached rows remain visible during refresh")

        try waitUntil("refresh finished") { !library.loading }
        try waitUntil("button back to refresh") { refresh.toolTip == L("Refresh") }
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(list.frame, frame)

        let reopened = SessionsSidebarContent(library: library)
        library.start(); reopened.activate()
        XCTAssertFalse(library.loading, "Reopening a view must not drive the model's synchronization")
        try waitUntil("condition") { !library.loading }
    }
    /// 会话已经在别的终端里开着时，列表要在**点下去之前**就说清楚——
    /// 否则用户点了才撞上「该会话已在其他终端中打开」那个提示框。
    /// lightty 自己开着优先：那时它在不在别处跑已经不重要了。
    func testASessionRunningElsewhereIsLabelledBeforeYouClickIt() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("session-elsewhere-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = SessionModelCatalog(root: root, agent: .claude)
        let library = SessionLibrary(fileURL: root.appendingPathComponent("organization.json"), providers: [catalog])
        let content = SessionsSidebarContent(library: library)
        try waitUntil("condition") { library.organizationReady }
        let table = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first)

        let parent = try XCTUnwrap(AgentProcessIdentity.parent(of: ProcessInfo.processInfo.processIdentifier))
        let external = try XCTUnwrap(AgentProcessIdentity.read(parent))
        let elsewhere = AgentSession(key: .init(agent: .claude, sourceRoot: root.path, nativeID: "a"),
                                     title: "在别处跑着", workingDirectory: root.path,
                                     updatedAt: Date(), sourceProcesses: [external])
        let idle = AgentSession(key: .init(agent: .claude, sourceRoot: root.path, nativeID: "b"),
                                title: "没在跑", workingDirectory: root.path, updatedAt: Date())
        catalog.records = [elsewhere, idle]
        library.start()
        try waitUntil("condition") { !library.loading }
        XCTAssertEqual(library.records.count, 2)
        XCTAssertTrue(external.liveness == .running)
        XCTAssertEqual(library.presence(for: elsewhere.key), .elsewhere)
        XCTAssertTrue(content.detailTextForTesting(elsewhere).contains(L("Open in another terminal")))
        XCTAssertFalse(content.detailTextForTesting(idle).contains(L("Open in another terminal")))
        XCTAssertFalse(content.detailTextForTesting(idle).contains(L("Open in lightty")))
        _ = table
    }

    /// 用户滚到列表下方，点一条会话开终端——列表不该弹回顶部。
    /// 先证明是不是刷新这条路把滚动位置冲掉的。
    func testRefreshDoesNotScrollTheListBackToTheTop() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("session-scroll-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SessionLibrary(fileURL: root.appendingPathComponent("organization.json"),
                                     providers: [FixtureCatalog(root: root, count: 60)])
        let content = SessionsSidebarContent(library: library)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = content
        library.start(); content.activate()
        try waitUntil("condition") { library.loaded && !library.loading }
        try waitUntil("condition") { content.makeState().rows.count > 10 }
        content.layoutSubtreeIfNeeded()

        let scroll = try XCTUnwrap(descendants(content).compactMap { $0 as? SidebarListScrollView }.first)
        let table = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first)
        // 表格必须真的排好版，否则高度是 0，「滚动位置保持不变」会变成一句空话——
        // 这个前置条件之前漏了，单独跑时测试是空跑的。
        window.layoutIfNeeded()
        content.layoutSubtreeIfNeeded()
        table.tile()
        table.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(table.numberOfRows, 20, "前置条件：要有足够多的行")
        let bottom = max(0, table.frame.height - scroll.contentView.bounds.height)
        XCTAssertGreaterThan(bottom, 0, "前置条件：列表要长到能滚动")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
        let scrolled = scroll.contentView.bounds.origin.y
        XCTAssertGreaterThan(scrolled, 0)

        library.refresh()
        try waitUntil("condition") { !library.loading }
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.bounds.origin.y, scrolled, accuracy: 1,
                       "刷新不该把列表弹回顶部")

        // 开一个终端会广播这几条：它们会把已建单元格整批重配一遍。
        library.updateWindow(UUID(), panes: [], selected: nil)
        for name: Notification.Name in [.lighttyWindowArrangementDidChange, .lighttyPaneStatusDidChange] {
            NotificationCenter.default.post(name: name, object: nil)
        }
        try drainMainQueue()  // 列表的重配合流到下一拍
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.bounds.origin.y, scrolled, accuracy: 1,
                       "开终端后的这几条通知也不该把列表弹回顶部")

        // 选中列表最后一行（点击会话就是这个效果），同样不该滚动。
        table.selectRowIndexes([table.numberOfRows - 1], byExtendingSelection: false)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.bounds.origin.y, scrolled, accuracy: 1,
                       "选中末行不该改变滚动位置")
    }

    /// `reload()` 拆成「只算」和「只写」两半之后，同一个状态重复送进来必须一个字节都不写。
    ///
    /// 会话库的通知零载荷、而且这个视图没有合流，一次 `library.refresh()` 至少发五条。
    /// 在那五遍里反复写视图会把 AppKit 的显示遍历顶成死循环。最危险的两处是
    /// **切换布局约束的激活状态**和**往表格活着的单元格里写**，都在下面盯着。
    func testRepeatedNotificationsRewriteNothingWhenTheStateIsUnchanged() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("session-render-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SessionLibrary(fileURL: root.appendingPathComponent("organization.json"), providers: [])
        let content = SessionsSidebarContent(library: library)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = content
        try waitUntil("condition") { library.organizationReady }
        content.layoutSubtreeIfNeeded()

        let heading = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == L("Recent sessions") })
        let header = try XCTUnwrap(heading.superview?.superview)
        let buttons = descendants(header).compactMap { $0 as? NSButton }
        let refresh = try XCTUnwrap(buttons.first { [L("Refresh"), L("Cancel")].contains($0.toolTip ?? "") })
        let filter = try XCTUnwrap(buttons.first { $0.toolTip == L("Filter sessions") })
        let more = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }
            .first { $0.title == L("Load more sessions") })
        let moreHeight = try XCTUnwrap(more.constraints.first { $0.firstAttribute == .height })
        let status = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTextField }
            .first { $0 !== heading && $0.font?.pointSize == 10.5 })

        let before = (image: refresh.image, tint: filter.contentTintColor, title: heading.stringValue,
                      moreHidden: more.isHidden, constraint: moreHeight.isActive,
                      status: status.stringValue)
        for _ in 0..<5 {
            NotificationCenter.default.post(name: .lighttySessionLibraryDidChange, object: library,
                userInfo: ["change": SessionChange(catalog: true)])
            content.layoutSubtreeIfNeeded()
        }
        XCTAssertTrue(refresh.image === before.image, "状态没变就不该重设图标")
        XCTAssertTrue(filter.contentTintColor === before.tint)
        XCTAssertEqual(heading.stringValue, before.title)
        XCTAssertEqual(more.isHidden, before.moreHidden)
        XCTAssertEqual(status.stringValue, before.status)
        // 注意：`moreHeight.isActive` 没有断言。重设成同一个值在 AppKit 里不可观测
        // （实测：不弄脏布局），断言它只会给人虚假信心。守卫仍然留着——那是「别做无谓
        // 的活」，不是已知会崩。
        _ = moreHeight

        // 状态真的变了还是要生效，别把守卫写成「永远不更新」。
        content.setArchiveFilter(true)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(heading.stringValue, L("Other archived sessions"))
        XCTAssertTrue(filter.contentTintColor !== before.tint, "筛选生效时图标要用重点色")
    }

    /// 渲染状态是这个模块对测试的断言面：断言值，不必遍历视图树反推显示了什么。
    /// 而且 `makeState()` 只算不写——连调十次也不能碰视图。
    func testRenderStateIsAssertableWithoutWalkingTheViewTree() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("session-state-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SessionLibrary(fileURL: root.appendingPathComponent("organization.json"), providers: [])
        let content = SessionsSidebarContent(library: library)
        try waitUntil("condition") { library.organizationReady }

        let state = content.makeState()
        XCTAssertEqual(state.recentTitle, L("Recent sessions"))
        XCTAssertEqual(state.projectTitle, L("Projects"))
        XCTAssertFalse(state.filterActive)
        XCTAssertFalse(state.showMore)
        // 只算不写：反复调用必须完全等值，且不产生任何副作用。
        for _ in 0..<10 { XCTAssertEqual(content.makeState(), state) }

        content.setArchiveFilter(true)
        let archived = content.makeState()
        XCTAssertEqual(archived.recentTitle, L("Other archived sessions"))
        XCTAssertEqual(archived.projectTitle, L("Archived"))
        XCTAssertTrue(archived.filterActive)
    }

    func testReturningToAppDoesNotRefreshVisibleSessionSidebar() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("session-refresh-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SessionLibrary(fileURL: root.appendingPathComponent("catalog.json"), providers: [FixtureCatalog(root: root)])
        let content = SessionsSidebarContent(library: library)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = content
        library.start(); content.activate()
        try waitUntil("condition") { library.loaded && !library.loading }
        for _ in 0..<3 {
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
            XCTAssertFalse(library.loading, "Returning focus to click a project must not start a catalog refresh")
            try waitUntil("condition") { !library.loading }
        }
    }
    func testProjectsCollapseAndSessionSearchAreIndependent() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("session-search-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SessionLibrary(fileURL: root.appendingPathComponent("catalog.json"),
            providers: [FixtureCatalog(root: root), FixtureCatalog(root: root, agent: .claude)])
        let sidebar = SessionsSidebarContent(library: library)
        library.start(); sidebar.activate()
        try waitUntil("condition") { library.organizationReady && !library.loading }
        library.updateOrganization { state in
            let project = SessionProject(name: "Mixed")
            state.projects = [project]
            for record in library.records { state.move(record, to: project.id) }
        }
        try waitUntil("condition") { !library.saving }
        let table = try XCTUnwrap(descendants(sidebar).compactMap { $0 as? NSTableView }.first)
        XCTAssertEqual(table.numberOfRows, 7)
        XCTAssertFalse(descendants(sidebar).contains { ($0 as? NSTextField)?.placeholderString == L("Search sessions…") })
        sidebar.toggleProjects()
        XCTAssertEqual(table.numberOfRows, 2, "Both section headers remain when projects collapse")
        sidebar.toggleProjects()
        XCTAssertEqual(table.numberOfRows, 7)
        XCTAssertFalse(library.loading, "Section disclosure must not query an Agent")
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertTrue(table.sendAction(table.action, to: table.target))
        XCTAssertFalse(library.loading, "Project disclosure must not query an Agent")
        try waitUntil("condition") { !library.saving }
        XCTAssertFalse(library.loading)
        XCTAssertTrue(library.organization.projects[0].collapsed)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertTrue(table.sendAction(table.action, to: table.target))
        try waitUntil("condition") { !library.saving }
        let search = SessionsSidebarContent(library: library, searchMode: true)
        let field = try XCTUnwrap(descendants(search).compactMap { $0 as? NSTextField }.first {
            $0.placeholderString == L("Search sessions…")
        })
        let results = try XCTUnwrap(descendants(search).compactMap { $0 as? NSTableView }.first)
        XCTAssertEqual(results.numberOfRows, 4)
        field.stringValue = "Claude Code"
        search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(results.numberOfRows, 2)
        XCTAssertEqual(table.numberOfRows, 7, "Palette queries must not filter the sidebar")
        var dismissed = false
        search.onRequestDismiss = { dismissed = true }
        XCTAssertTrue(search.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertTrue(dismissed)
        let palette = SessionSearchPalette(library: library)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = palette
        palette.layoutSubtreeIfNeeded()
        XCTAssertNotNil(descendants(palette).compactMap { $0 as? NSTextField }.first {
            $0.placeholderString == L("Search sessions…")
        }, "The palette hosts the same search field")
        if let path = ProcessInfo.processInfo.environment["LIGHTTY_UI_SNAPSHOT_DIR"],
           let bitmap = palette.bitmapImageRepForCachingDisplay(in: palette.bounds) {
            palette.cacheDisplay(in: palette.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: path).appendingPathComponent("session-search.png"))
        }
    }

    func testNewSessionUsesConfiguredAgentCommandAndDirectory() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("new-session-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        AppState.shared = AppState(taskDirectory: directory, sweepStalePanes: false)
        ensureTerminalRuntime()
        for agent in [LaunchAgent.codex, .claudeCode] {
            let pane = try AppState.shared.paneLauncher.makePane(
                for: .init(.agent(agent), workingDirectory: directory.path))
            let config = pane.terminal.launchConfiguration
            XCTAssertEqual(config.workingDirectory, directory.path)
            XCTAssertEqual(config.initialInput, AgentLaunchPreference.initialInput(for: agent))
        }
    }
    func testTabSidebarSharesEdgeRailAndKeepsScrollbarDraggable() throws {
        _ = NSApplication.shared
        let sidebar = TabSidebarView(topInset: 0)
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 500)
        let scroll = try XCTUnwrap(descendants(sidebar).compactMap { $0 as? SidebarListScrollView }.first)
        let document = try XCTUnwrap(scroll.documentView)
        let column = try XCTUnwrap(descendants(sidebar).compactMap { $0 as? TabColumnView }.first)
        column.reload(overview: (0..<100).map { (UUID(), "Tab \($0)", false, false, []) })
        scroll.autohidesScrollers = false
        for style in [NSScroller.Style.legacy, .overlay] {
            scroll.scrollerStyle = style
            sidebar.layoutSubtreeIfNeeded()
            scroll.tile()
            sidebar.layoutSubtreeIfNeeded()
            let scroller = try XCTUnwrap(scroll.verticalScroller)
            XCTAssertTrue(scroller is SidebarScroller)
            XCTAssertEqual(sidebar.bounds.maxX - sidebar.convert(scroll.bounds, from: scroll).maxX,
                           SidebarListScrollView.trailingMargin, accuracy: 0.5)
            XCTAssertLessThanOrEqual(document.frame.width, scroll.contentView.bounds.width + 0.5)
            XCTAssertLessThanOrEqual(scroll.contentView.frame.maxX, scroller.frame.minX)
            let point = sidebar.convert(NSPoint(x: scroller.bounds.midX, y: scroller.bounds.midY), from: scroller)
            let hit = sidebar.hitTest(point)
            XCTAssertTrue(hit === scroll || hit?.isDescendant(of: scroll) == true,
                          "The scroll view, not the edge resize strip, owns the rail")
            if style == .legacy {
                XCTAssertTrue(hit === scroller || hit?.isDescendant(of: scroller) == true)
            } // An idle overlay scroller deliberately defers hit testing to its scroll view.
        }
    }
    /// 会话行拖放的落点规则表：
    /// - 落进项目：分组标题不可落、无效数据拒绝、落进（折叠的）项目会把它展开、同项目再落为空动；
    /// - 落回最近：项目里的会话可落回「最近」标题行、最近的会话行、列表末尾的空白，
    ///   已在最近的再落为空动，磁盘上的 assignment 变 nil。
    /// 两个 agent 的会话都走一遍；分组从不改写 agent 自己的历史。
    func testSessionDropTargetsMoveBetweenRecentAndProjects() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("session-drop-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("organization.json")
        let library = SessionLibrary(fileURL: file,
            providers: [FixtureCatalog(root: root), FixtureCatalog(root: root, agent: .claude)])
        let content = SessionsSidebarContent(library: library)
        library.start(); content.activate()
        try waitUntil("condition") { library.organizationReady && !library.loading }
        var project = SessionProject(name: "Mixed project")
        project.collapsed = true
        library.updateOrganization { $0.projects = [project] }
        try waitUntil("condition") { !library.saving }
        let table = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first)
        XCTAssertNil(content.tableView(table, pasteboardWriterForRow: 0))
        XCTAssertNotNil(content.tableView(table, pasteboardWriterForRow: 3))
        let records = library.records

        // 落进项目
        for agent in SessionAgent.allCases {
            let record = try XCTUnwrap(records.first { $0.key.agent == agent })
            let data = try JSONEncoder().encode(record.key)
            XCTAssertFalse(content.acceptSessionDrop(data, at: 0), "A section is not a project")
            XCTAssertFalse(content.acceptSessionDrop(Data("invalid".utf8), at: 1))
            XCTAssertTrue(content.acceptSessionDrop(data, at: 1))
            try waitUntil("condition") { !library.saving }
            XCTAssertEqual(library.organization.projectID(for: record), project.id)
            XCTAssertFalse(library.organization.projects[0].collapsed)
            XCTAssertFalse(content.acceptSessionDrop(data, at: 1), "Same-project drops are no-ops")
        }
        XCTAssertEqual(library.records, records, "Grouping must not mutate source sessions")

        // 落回最近：先把两条都放回最近，下面的行号算法按「项目里只有一条」推
        library.updateOrganization { state in for record in records { state.move(record, to: nil) } }
        try waitUntil("condition") { !library.saving }
        for agent in SessionAgent.allCases {
            let record = try XCTUnwrap(records.first { $0.key.agent == agent })
            let data = try JSONEncoder().encode(record.key)
            for destination in 0..<3 {
                library.updateOrganization { $0.move(record, to: project.id) }
                try waitUntil("condition") { !library.saving }
                // 保存完不等于表格已刷新：等第 2 行真的变成项目里的会话（刷新前是「最近」标题）。
                try waitUntil("grouped session shown at row 2") {
                    table.numberOfRows > 2 && content.tableView(table, shouldSelectRow: 2)
                }
                // Projects heading, project, grouped session, recent heading, recent rows.
                let row = destination == 0 ? 3 : (destination == 1 ? 4 : table.numberOfRows)
                XCTAssertFalse(content.acceptSessionDrop(data, at: 2), "A grouped session is not a drop destination")
                guard content.acceptSessionDrop(data, at: row) else {
                    XCTFail("Cannot return \(agent) to recent destination \(destination)")
                    return
                }
                try waitUntil("condition") { !library.saving }
                XCTAssertNil(library.organization.projectID(for: record))
                try waitUntil("recent heading back at row 2") {
                    table.numberOfRows > 2 && !content.tableView(table, shouldSelectRow: 2)
                }
                XCTAssertFalse(content.acceptSessionDrop(data, at: 2), "Already-recent drops are no-ops")
                let saved = try JSONDecoder().decode(SessionOrganization.self, from: Data(contentsOf: file))
                XCTAssertNil(saved.projectID(for: record))
                XCTAssertTrue(saved.assignments.contains { $0.session == record.key && $0.projectID == nil })
            }
        }
        XCTAssertEqual(library.records, records, "Organizing must not mutate Agent history")
    }

    func testLocalArchiveFilterShowsBothAgentsInArchivedProject() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mixed-archive-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SessionLibrary(fileURL: root.appendingPathComponent("catalog.json"),
            providers: [FixtureCatalog(root: root), FixtureCatalog(root: root, agent: .claude)])
        let content = SessionsSidebarContent(library: library)
        content.frame = NSRect(x: 0, y: 0, width: 280, height: 720)
        library.start(); content.activate()
        try waitUntil("condition") { library.organizationReady && !library.loading }
        let project = SessionProject(name: "Mixed archive")
        library.updateOrganization { state in
            state.projects = [project]
            for record in library.records { state.move(record, to: project.id) }
            state.setArchived(true, projectID: project.id)
        }
        try waitUntil("condition") { !library.saving }
        let table = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first)
        XCTAssertEqual(table.numberOfRows, 3, "Projects heading, empty projects and recent heading")
        content.setArchiveFilter(true)
        XCTAssertEqual(table.numberOfRows, 7, "Two headings, project and four sessions")
        XCTAssertFalse(library.loading, "Local archive filtering must not query an Agent")
        library.updateOrganization { $0.setArchived(false, projectID: project.id) }
        try waitUntil("condition") { !library.saving }
        XCTAssertEqual(table.numberOfRows, 3)
        content.setArchiveFilter(false)
        XCTAssertEqual(table.numberOfRows, 7)
    }

    func testModeSwitchPreservesContentAndDoesNotCreateTerminal() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("primary-sidebar-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        AppState.shared = AppState(taskDirectory: root, sweepStalePanes: false)
        let panel = PrimarySidebar(headerCenterY: 20, mode: .handoff, library: AppState.shared.sessionLibrary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = panel
        let before = descendants(panel).first { $0 is HandoffSidebarContent }
        panel.selectMode(.sessions)
        panel.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.mode, .sessions)
        XCTAssertEqual(AppState.shared.windowControllers.count, 0)
        XCTAssertEqual(panel.frame.width, 280)
        XCTAssertNotNil(descendants(panel).first { $0 is SessionsSidebarContent })
        panel.selectMode(.handoff)
        XCTAssertTrue(descendants(panel).first { $0 is HandoffSidebarContent } === before)
        XCTAssertFalse(try XCTUnwrap(before).isHidden)
        let modeSwitch = try XCTUnwrap(descendants(panel).compactMap { $0 as? ModeSwitch }.first)
        XCTAssertEqual(modeSwitch.segments.map(\.title), ["Handoff", "Sessions"])
        XCTAssertEqual(modeSwitch.segments.map(\.state), [.on, .off])
        modeSwitch.segments[1].performClick(nil)
        XCTAssertEqual(panel.mode, .sessions)
        XCTAssertEqual(modeSwitch.segments.map(\.state), [.off, .on])
    }

    func testProjectWritesAreAtomicAndCorruptFileIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("session-project-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("library.json")
        let library = SessionLibrary(fileURL: file, providers: [])
        try waitUntil("condition") { library.organizationReady }
        library.updateOrganization { $0.projects.append(SessionProject(name: "Project")) }
        try waitUntil("condition") { !library.saving }
        XCTAssertEqual(try JSONDecoder().decode(SessionOrganization.self, from: Data(contentsOf: file)).projects.first?.name, "Project")
        let broken = Data("{broken".utf8)
        try broken.write(to: file)
        let corrupt = SessionLibrary(fileURL: file, providers: [])
        try waitUntil("condition") { corrupt.storageError != nil }
        corrupt.updateOrganization { $0.projects.append(SessionProject(name: "Do not overwrite")) }
        XCTAssertEqual(try Data(contentsOf: file), broken)
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
}

private struct FixtureCatalog: CatalogOnlyProvider {
    let root: URL
    var agent: SessionAgent = .codex
    /// 让读取真的占住一点时间。真实 provider 要起一个子进程（几百毫秒），
    /// 而瞬时返回的 fixture 会让「开始读」和「读完」落进同一拍——那样转圈根本不出现，
    /// 测不出「读的时候要有转圈」。只在需要这条覆盖的用例里传。
    var delay: TimeInterval = 0
    /// 需要一条长到能滚动的列表时传。默认两条，保持既有用例不变。
    var count: Int = 2
    var source: SessionCatalogSource { .init(agent: agent, root: root, executable: "/bin/false", configuration: .custom(root.path)) }
    func page(archived: Bool, cursor: String?, cancelled: () -> Bool) throws -> SessionCatalogPage {
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }  // 后台队列上，不挡主线程
        guard !archived else { return SessionCatalogPage(sessions: [], nextCursor: nil) }
        let titles = count == 2 ? ["修复全屏侧栏裁切", "整理 Handoff 任务与会话"]
            : (0..<count).map { "会话 \($0)" }
        let rows = titles.enumerated().map { index, title in
            AgentSession(key: .init(agent: agent, sourceRoot: root.path, nativeID: "fixture-\(index)"),
                         title: title, workingDirectory: root.path, updatedAt: Date())
        }
        return SessionCatalogPage(sessions: rows, nextCursor: nil)
    }
}

/// 截图只渲染菜单内容；玻璃与投影仍由应用窗口合成器验收。
private final class MenuPreviewBackdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        ShellStyle.raisedSurface.setFill()
        bounds.fill()
    }
}
