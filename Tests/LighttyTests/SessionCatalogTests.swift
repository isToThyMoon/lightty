import AppKit
import XCTest
import LighttyCore
@testable import lightty

final class SessionCatalogTests: XCTestCase {
    func testCodexDecodeUsesThreadIDAndSecondsAndExcludesDesktop() throws {
        let source = SessionCatalogSource(agent: .codex, root: URL(fileURLWithPath: "/config"), executable: "/bin/codex")
        let page: [String: Any] = ["data": [
            ["id": "thread-1", "sessionId": "shared-tree", "source": "cli", "cwd": "/repo", "updatedAt": 1000.0, "preview": "Preview"],
            ["id": "desktop-1", "source": "appServer"],
            ["id": "ide-1", "source": "vscode"],
        ]]
        let rows = try CodexSessionCatalog.decode(page, source: source, archived: false)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.key.nativeID, "thread-1")
        XCTAssertEqual(rows.first?.updatedAt, Date(timeIntervalSince1970: 1000))
        XCTAssertThrowsError(try CodexSessionCatalog.decode([:], source: source, archived: false))
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
        let provider = CodexSessionCatalog(source: .init(agent: .codex, root: root, executable: executable))
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
        spin { library.organizationReady }
        let record = AgentSession(key: .init(agent: .claude, sourceRoot: root.path, nativeID: "fixture"),
                                  title: "Fixture", workingDirectory: root.path, updatedAt: nil)
        let title = L("Move to recent sessions")
        XCTAssertFalse(content.sessionMenuItems(record, anchor: NSView()).contains { $0.title == title })
        let project = SessionProject(name: "Project")
        library.updateOrganization {
            $0.projects = [project]
            $0.move(record, to: project.id)
        }
        spin { !library.saving }
        let item = try XCTUnwrap(content.sessionMenuItems(record, anchor: NSView()).first { $0.title == title })
        guard case .action(let action) = item.kind else { return XCTFail("Expected move action") }
        action()
        spin { !library.saving }
        XCTAssertNil(library.organization.projectID(for: record))
        XCTAssertFalse(content.sessionMenuItems(record, anchor: NSView()).contains { $0.title == title })
    }

    /// 筛选浮层是「同一件事的几种选择」：只用分组标题分段，不画线；
    /// 刷新是当场执行的动作，在标题行的按钮上，不在这里。
    func testFilterPopoverHasNoDividersAndNoRefreshAction() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SessionLibrary(fileURL: root.appendingPathComponent("organization.json"), providers: [])
        let content = SessionsSidebarContent(library: library)
        spin { library.organizationReady }
        let items = content.managementItems()
        XCTAssertFalse(items.contains { if case .separator = $0.kind { return true } else { return false } })
        for title in [L("Refresh"), L("Cancel")] {
            XCTAssertFalse(items.contains { $0.title == title })
        }
        // 分段仍然靠标题说清楚，别把线连着标题一起删掉了。
        for title in [L("Filter sessions"), L("Sort sessions"), L("Native resume picker…")] {
            XCTAssertTrue(items.contains { $0.title == title && {
                if case .header = $0.kind { return true } else { return false } }($0) }, title)
        }
    }

    /// 关着的会话也能改名——走官方接口，不需要先把会话开起来（见 `SessionRename`）。
    func testRenameIsOfferedForSessionsThatAreNotOpen() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SessionLibrary(fileURL: root.appendingPathComponent("organization.json"), providers: [])
        let content = SessionsSidebarContent(library: library)
        spin { library.organizationReady }
        let record = AgentSession(key: .init(agent: .claude, sourceRoot: root.path, nativeID: "fixture"),
                                  title: "Fixture", workingDirectory: root.path, updatedAt: nil)
        let items = content.sessionMenuItems(record, anchor: NSView())
        XCTAssertTrue(items.contains { $0.title == L("Rename session…") })
        // 没打开的会话给的是三个打开方式，不是「显示终端」。
        XCTAssertTrue(items.contains { $0.title == L("Continue in new tab") })
        XCTAssertFalse(items.contains { $0.title == L("Show terminal") })
    }

    func testRecentDropFeedbackUsesAppAccentInsteadOfNativeBlue() throws {
        _ = NSApplication.shared
        let prior = AccentPreference.current()
        AccentPreference.set(.pink)
        defer { AccentPreference.set(prior) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("drop-style-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SessionLibrary(fileURL: root.appendingPathComponent("organization.json"), providers: [FixtureCatalog(root: root)])
        let content = SessionsSidebarContent(library: library)
        library.start(); content.activate()
        spin { library.organizationReady && !library.loading }
        let table = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first)
        let row = try XCTUnwrap(content.tableView(table, rowViewForRow: 2))
        row.frame = NSRect(x: 0, y: 0, width: 240, height: 32)
        row.appearance = NSAppearance(named: .aqua)
        row.draggingDestinationFeedbackStyle = .regular
        row.isEmphasized = true
        row.selectionHighlightStyle = .regular
        row.isSelected = true
        row.isTargetForDropOperation = true
        let image = NSImage(size: row.frame.size)
        image.lockFocus()
        NSColor.white.setFill(); NSBezierPath(rect: row.bounds).fill()
        // Exercise the complete row paint: AppKit also paints drop feedback in drawBackground.
        row.drawBackground(in: row.bounds)
        row.drawSelection(in: row.bounds)
        row.drawDraggingDestinationFeedback(in: row.bounds)
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(color.redComponent, color.blueComponent, "Drop feedback should use the pink app accent, not native blue")
        XCTAssertGreaterThan(color.greenComponent, 0.7, "Drop fill must remain subtle behind the heading")
        XCTAssertEqual(row.interiorBackgroundStyle, .normal)
        row.isTargetForDropOperation = false
        let cell = try XCTUnwrap(content.tableView(table, viewFor: nil, row: 3) as? NSTableCellView)
        let components = cell.draggingImageComponents
        XCTAssertEqual(components.count, 1, "Drag preview is one opaque card, not floating labels")
        XCTAssertTrue(components.first?.contents is NSImage)
        XCTAssertEqual(components.first?.frame.height, 40)
        if let path = ProcessInfo.processInfo.environment["LIGHTTY_UI_SNAPSHOT_DIR"],
           let preview = components.first?.contents as? NSImage,
           let data = preview.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: data) {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + "/session-drag-card.png"))
            try NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?
                .representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + "/session-drop-target.png"))
        }
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
        spin { library.organizationReady && !library.loading }
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
        spin { library.organizationReady && !library.loading }
        library.updateOrganization { $0.projects = [SessionProject(name: "Project")] }
        spin { !library.saving }
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
            spin { !library.saving }
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
        spin { library.organizationReady && !library.loading }
        library.updateOrganization { $0.projects = [SessionProject(name: "Empty project")] }
        spin { !library.saving }
        content.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first)
        let recentCell = try XCTUnwrap(table.view(atColumn: 0, row: 3, makeIfNecessary: true))
        table.selectRowIndexes([1], byExtendingSelection: false)
        XCTAssertTrue(table.sendAction(table.action, to: table.target))
        XCTAssertTrue(table.view(atColumn: 0, row: 3, makeIfNecessary: true) === recentCell,
                      "Saving state must not tear down unrelated visible cells")
        spin { !library.saving }
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
        spin { library.organizationReady && !library.loading }
        library.updateOrganization { state in
            let project = SessionProject(name: "Project")
            state.projects = [project]
            for record in library.records { state.move(record, to: project.id) }
        }
        spin { !library.saving }
        content.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first)
        let button = try XCTUnwrap(descendants(content).compactMap { $0 as? SidebarDisclosureButton }.first)
        XCTAssertEqual(table.numberOfRows, 5)
        for index in 0..<12 {
            content.toggleProjects()
            let expanded = index % 2 == 1
            XCTAssertEqual(button.expanded, expanded)
            XCTAssertEqual(table.numberOfRows, expanded ? 5 : 2)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let animation = try XCTUnwrap(button.disclosureLayer?.animation(forKey: "disclosure") as? CABasicAnimation)
                XCTAssertEqual(animation.duration, ShellStyle.animationDuration)
                XCTAssertEqual(animation.toValue as? CGFloat, expanded ? CGFloat.pi / 2 : 0)
            }
            XCTAssertFalse(library.loading)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(ShellStyle.animationDuration + 0.05))
        XCTAssertTrue(button.expanded)
        XCTAssertEqual(table.numberOfRows, 5)
        if let path = ProcessInfo.processInfo.environment["LIGHTTY_UI_SNAPSHOT_DIR"] {
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
        spin { !library.saving }
        XCTAssertEqual(table.numberOfRows, 3)
        XCTAssertTrue(button.expanded)
    }

    /// 「在读」由刷新按钮自己表达——它变成取消。标题行不再放转圈，两个一起是重复的。
    /// 仍然盯住原来那两条：不出现「正在载入」这类文字，列表不因此位移。
    func testLoadingIsShownByTheRefreshButtonWithoutLoadingTextOrLayoutShift() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("session-spinner-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SessionLibrary(fileURL: root.appendingPathComponent("organization.json"),
            providers: [FixtureCatalog(root: root, delay: 0.2),
                        FixtureCatalog(root: root, agent: .claude, delay: 0.2)])
        let content = SessionsSidebarContent(library: library)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        let list = try XCTUnwrap(descendants(content).compactMap { $0 as? SidebarListScrollView }.first)
        let before = list.frame
        let heading = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == L("Recent sessions") })
        let header = try XCTUnwrap(heading.superview?.superview)
        let refresh = try XCTUnwrap(descendants(header).compactMap { $0 as? NSButton }
            .first { [L("Refresh"), L("Cancel")].contains($0.toolTip ?? "") })
        XCTAssertEqual(refresh.toolTip, L("Refresh"))
        let iconAtRest = refresh.image
        XCTAssertTrue(descendants(header).compactMap { $0 as? NSProgressIndicator }.isEmpty,
                      "标题行不再放转圈：刷新按钮已经表达了在读")

        library.start(); content.activate()
        // 会话库通知合流到下一拍再重算（见 `Coalescer`），所以按钮晚一拍翻。
        // 顺序是确定的：`refresh()` 先把重算排进主队列，provider 的完成回调排在它后面。
        // 真实 app 里主 runloop 一直在转，这一拍是几微秒，看不出来。
        spin { refresh.toolTip == L("Cancel") }
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(refresh.toolTip, L("Cancel"), "在读时这个按钮就是取消")
        // 图标不许换：换成 ✕ 会让按钮在光标底下变身。读取时靠它自己旋转来表达。
        XCTAssertTrue(refresh.image === iconAtRest, "读取时不该换图标")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertNotNil(refreshRotationLayer(in: refresh.layer), "读取时图标要转起来")
        }
        XCTAssertEqual(list.frame, before, "读取不该让列表位移")
        XCTAssertFalse(descendants(content).compactMap { $0 as? NSTextField }
            .contains { !$0.isHidden && $0.stringValue.contains(L("Loading local sessions…")) })

        spin { !library.loading }
        spin { refresh.toolTip == L("Refresh") }
        XCTAssertEqual(refresh.toolTip, L("Refresh"))
        XCTAssertTrue(refresh.image === iconAtRest)
        // 收尾会等当前这一圈走完再摘，所以最少转满一圈；这里等它自己停。
        spin { refreshRotationLayer(in: refresh.layer) == nil }
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(list.frame, before)
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
        spin { library.organizationReady }
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
        spin { !library.loading }
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
        spin { library.loaded && !library.loading }
        spin { content.makeState().rows.count > 10 }
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
        spin { !library.loading }
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.bounds.origin.y, scrolled, accuracy: 1,
                       "刷新不该把列表弹回顶部")

        // 开一个终端会广播这几条：它们会把已建单元格整批重配一遍。
        library.updateWindow(UUID(), panes: [], selected: nil)
        for name: Notification.Name in [.lighttyTasksDidChange, .lighttyPaneStatusDidChange] {
            NotificationCenter.default.post(name: name, object: nil)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
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
        spin { library.organizationReady }
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
        spin { library.organizationReady }

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

    /// 搜索面板里根本不显示标题行——那边的行只有会话。
    func testSearchPaletteNeverVendsTheHeaderRows() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("session-header-search-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SessionLibrary(fileURL: root.appendingPathComponent("organization.json"),
                                     providers: [FixtureCatalog(root: root)])
        let content = SessionsSidebarContent(library: library, searchMode: true)
        library.start(); content.activate()
        spin { library.organizationReady && !library.loading }
        content.layoutSubtreeIfNeeded()
        XCTAssertFalse(descendants(content).contains { $0 is NSButton
            && ($0 as? NSButton)?.toolTip == L("Filter sessions") })
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
        spin { library.loaded && !library.loading }
        for _ in 0..<3 {
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
            XCTAssertFalse(library.loading, "Returning focus to click a project must not start a catalog refresh")
            spin { !library.loading }
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
        spin { library.organizationReady && !library.loading }
        library.updateOrganization { state in
            let project = SessionProject(name: "Mixed")
            state.projects = [project]
            for record in library.records { state.move(record, to: project.id) }
        }
        spin { !library.saving }
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
        spin { !library.saving }
        XCTAssertFalse(library.loading)
        XCTAssertTrue(library.organization.projects[0].collapsed)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertTrue(table.sendAction(table.action, to: table.target))
        spin { !library.saving }
        let search = SessionsSidebarContent(library: library, searchMode: true)
        let field = try XCTUnwrap(descendants(search).compactMap { $0 as? NSTextField }.first {
            $0.placeholderString == L("Search sessions…")
        })
        XCTAssertFalse(field.isBezeled)
        XCTAssertEqual(field.focusRingType, .none)
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
        let paletteField = try XCTUnwrap(descendants(palette).compactMap { $0 as? NSTextField }.first {
            $0.placeholderString == L("Search sessions…")
        })
        XCTAssertGreaterThan(paletteField.frame.width, 200)
        if let path = ProcessInfo.processInfo.environment["LIGHTTY_UI_SNAPSHOT_DIR"],
           let bitmap = palette.bitmapImageRepForCachingDisplay(in: palette.bounds) {
            palette.cacheDisplay(in: palette.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: path).appendingPathComponent("session-search.png"))
        }
    }

    func testRefreshKeepsListTopStableAndPresentationDoesNotReloadCatalog() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("session-layout-refresh-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SessionLibrary(fileURL: root.appendingPathComponent("catalog.json"),
            providers: [FixtureCatalog(root: root), FixtureCatalog(root: root, agent: .claude)])
        let content = SessionsSidebarContent(library: library)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = content
        library.start(); content.activate()
        spin { library.loaded && !library.loading }
        content.layoutSubtreeIfNeeded()
        let list = try XCTUnwrap(descendants(content).compactMap { $0 as? SidebarListScrollView }.first)
        let frame = list.frame
        let records = library.records
        let search = SessionsSidebarContent(library: library, searchMode: true)
        library.start(); search.activate()
        XCTAssertFalse(library.loading, "Search should reuse the already loaded catalog")
        library.refresh()
        XCTAssertTrue(library.loading)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(list.frame, frame, "A loading status must not move or resize the list")
        XCTAssertEqual(content.frame.width, 280, "Status text must not expand the sidebar/window")
        XCTAssertEqual(library.records, records, "Cached rows remain visible during refresh")
        spin { !library.loading }
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(list.frame, frame)
        let reopened = SessionsSidebarContent(library: library)
        library.start(); reopened.activate()
        XCTAssertFalse(library.loading, "Reopening a view must not drive the model's synchronization")
        spin { !library.loading }
    }

    func testProjectFolderResourcesAreDistinctTemplateVectors() throws {
        let closed = ProjectFolderIcons.image(expanded: false)
        let open = ProjectFolderIcons.image(expanded: true)
        XCTAssertEqual(closed.size, open.size)
        XCTAssertTrue(closed.isTemplate && open.isTemplate)
        XCTAssertTrue(closed.representations.first is NSPDFImageRep)
        XCTAssertTrue(open.representations.first is NSPDFImageRep)
        XCTAssertNotEqual(closed.tiffRepresentation, open.tiffRepresentation)
    }

    func testNewSessionUsesConfiguredAgentCommandAndDirectory() {
        for agent in [LaunchAgent.codex, .claudeCode] {
            let config = SessionResumeFlow.newSessionConfiguration(agent: agent, workingDirectory: "/tmp")
            XCTAssertEqual(config.workingDirectory, "/tmp")
            XCTAssertEqual(config.initialInput, AgentLaunchPreference.initialInput(for: agent))
        }
    }
    func testSidebarScrollbarRailNeverOverlapsContent() throws {
        _ = NSApplication.shared
        let scroll = SidebarListScrollView(frame: NSRect(x: 0, y: 0, width: 266, height: 400))
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 2000))
        scroll.autohidesScrollers = false
        for style in [NSScroller.Style.overlay, .legacy] {
            scroll.scrollerStyle = style
            scroll.tile()
            let scroller = try XCTUnwrap(scroll.verticalScroller)
            XCTAssertTrue(scroller is SidebarScroller, "Both sidebar modes use the quiet native scroller")
            XCTAssertLessThanOrEqual(scroll.contentView.frame.maxX, scroller.frame.minX)
            let width = scroll.contentView.frame.width
            for _ in 0..<5 { scroll.tile() }
            XCTAssertEqual(scroll.contentView.frame.width, width, "Layout must not shrink on repeated tiling")
            scroll.autohidesScrollers = true
            scroll.tile()
            XCTAssertEqual(scroll.contentView.frame.width, width)
        }
    }
    func testTabSidebarSharesEdgeRailAndKeepsScrollbarDraggable() throws {
        _ = NSApplication.shared
        let sidebar = TabSidebarView(topInset: 0)
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 500)
        let scroll = try XCTUnwrap(descendants(sidebar).compactMap { $0 as? SidebarListScrollView }.first)
        let document = try XCTUnwrap(scroll.documentView)
        let column = try XCTUnwrap(descendants(sidebar).compactMap { $0 as? TabColumnView }.first)
        column.reload(overview: (0..<100).map { (UUID(), $0, "Tab \($0)", false, false, []) })
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
    func testSessionDropMovesBothAgentsIntoConcreteProjectOnly() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("session-drop-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SessionLibrary(fileURL: root.appendingPathComponent("catalog.json"),
            providers: [FixtureCatalog(root: root), FixtureCatalog(root: root, agent: .claude)])
        let content = SessionsSidebarContent(library: library)
        library.start(); content.activate()
        spin { library.organizationReady && !library.loading }
        var project = SessionProject(name: "Mixed project")
        project.collapsed = true
        library.updateOrganization { $0.projects = [project] }
        spin { !library.saving }
        let table = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first)
        XCTAssertNil(content.tableView(table, pasteboardWriterForRow: 0))
        XCTAssertNotNil(content.tableView(table, pasteboardWriterForRow: 3))
        let records = library.records
        for agent in SessionAgent.allCases {
            let record = try XCTUnwrap(records.first { $0.key.agent == agent })
            let data = try JSONEncoder().encode(record.key)
            XCTAssertFalse(content.acceptSessionDrop(data, at: 0), "A section is not a project")
            XCTAssertFalse(content.acceptSessionDrop(Data("invalid".utf8), at: 1))
            XCTAssertTrue(content.acceptSessionDrop(data, at: 1))
            spin { !library.saving }
            XCTAssertEqual(library.organization.projectID(for: record), project.id)
            XCTAssertFalse(library.organization.projects[0].collapsed)
            XCTAssertFalse(content.acceptSessionDrop(data, at: 1), "Same-project drops are no-ops")
        }
        XCTAssertEqual(library.records, records, "Grouping must not mutate source sessions")
    }
    func testProjectSessionsCanDropBackToRecentHeadingRowsAndEmptyTail() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("session-return-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("organization.json")
        let library = SessionLibrary(fileURL: file,
            providers: [FixtureCatalog(root: root), FixtureCatalog(root: root, agent: .claude)])
        let content = SessionsSidebarContent(library: library)
        library.start(); content.activate()
        spin { library.organizationReady && !library.loading }
        let project = SessionProject(name: "Mixed project")
        library.updateOrganization { $0.projects = [project] }
        spin { !library.saving }
        let records = library.records
        let table = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first)
        for agent in SessionAgent.allCases {
            let record = try XCTUnwrap(records.first { $0.key.agent == agent })
            let data = try JSONEncoder().encode(record.key)
            for destination in 0..<3 {
                library.updateOrganization { $0.move(record, to: project.id) }
                spin { !library.saving }
                // Projects heading, project, grouped session, recent heading, recent rows.
                let row = destination == 0 ? 3 : (destination == 1 ? 4 : table.numberOfRows)
                XCTAssertFalse(content.acceptSessionDrop(data, at: 2), "A grouped session is not a drop destination")
                guard content.acceptSessionDrop(data, at: row) else {
                    XCTFail("Cannot return \(agent) to recent destination \(destination)")
                    return
                }
                spin { !library.saving }
                XCTAssertNil(library.organization.projectID(for: record))
                XCTAssertFalse(content.acceptSessionDrop(data, at: 2), "Already-recent drops are no-ops")
                let saved = try JSONDecoder().decode(SessionOrganization.self, from: Data(contentsOf: file))
                XCTAssertNil(saved.projectID(for: record))
                XCTAssertTrue(saved.assignments.contains { $0.session == record.key && $0.projectID == nil })
            }
        }
        XCTAssertEqual(library.records, records, "Organizing must not mutate Agent history")
    }

    func testScrollingHoveredRowOutOfViewClearsHover() throws {
        _ = NSApplication.shared
        let scroll = SidebarListScrollView(frame: NSRect(x: 0, y: 0, width: 280, height: 100))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 1000))
        let row = ShellTableRowView(frame: NSRect(x: 0, y: 0, width: 280, height: 48))
        document.addSubview(row); scroll.documentView = document
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        ShellHoverGate.release(in: nil)
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil))
        row.mouseEntered(with: event)
        XCTAssertTrue(Mirror(reflecting: row).children.first { $0.label == "isHovered" }?.value as? Bool ?? false)
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 500))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        XCTAssertFalse(Mirror(reflecting: row).children.first { $0.label == "isHovered" }?.value as? Bool ?? false,
                       "Scrolling must clear hover even without mouseExited")
    }
    func testEnteringAnotherRowClearsPreviousHoverWithoutExitEvent() throws {
        _ = NSApplication.shared
        let table = NSTableView()
        let scroll = SidebarListScrollView(frame: NSRect(x: 0, y: 0, width: 280, height: 100))
        scroll.documentView = table
        let first = ShellTableRowView(), second = ShellTableRowView()
        table.addSubview(first); table.addSubview(second)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        ShellHoverGate.release(in: nil)
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil))
        first.mouseEntered(with: event)
        second.mouseEntered(with: event)
        func hovered(_ row: ShellTableRowView) -> Bool {
            Mirror(reflecting: row).children.first { $0.label == "isHovered" }?.value as? Bool ?? false
        }
        XCTAssertFalse(hovered(first), "Fast row transitions must not leave multiple hover backgrounds")
        XCTAssertTrue(hovered(second))
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
        spin { library.organizationReady && !library.loading }
        let project = SessionProject(name: "Mixed archive")
        library.updateOrganization { state in
            state.projects = [project]
            for record in library.records { state.move(record, to: project.id) }
            state.setArchived(true, projectID: project.id)
        }
        spin { !library.saving }
        let table = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first)
        XCTAssertEqual(table.numberOfRows, 3, "Projects heading, empty projects and recent heading")
        XCTAssertFalse(content.tableView(table, rowViewForRow: 0) is ShellTableRowView,
                       "Section headers must not inherit interactive row hover")
        let emptyCell = try XCTUnwrap(content.tableView(table, viewFor: nil, row: 1))
        let emptyLabel = try XCTUnwrap(descendants(emptyCell).compactMap { $0 as? NSTextField }.first { $0.stringValue == L("No projects") })
        XCTAssertEqual(emptyLabel.font?.pointSize, 11)
        let headingCell = try XCTUnwrap(content.tableView(table, viewFor: nil, row: 2))
        let headingLabel = try XCTUnwrap(descendants(headingCell).compactMap { $0 as? NSTextField }.first { $0.stringValue == L("Recent sessions") })
        XCTAssertEqual(headingLabel.textColor, ShellStyle.primaryText)
        content.setArchiveFilter(true)
        XCTAssertEqual(table.numberOfRows, 7, "Two headings, project and four sessions")
        XCTAssertFalse(library.loading, "Local archive filtering must not query an Agent")
        library.updateOrganization { $0.setArchived(false, projectID: project.id) }
        spin { !library.saving }
        XCTAssertEqual(table.numberOfRows, 3)
        content.setArchiveFilter(false)
        XCTAssertEqual(table.numberOfRows, 7)
    }

    func testBothModesFitNarrowPanelWithWrappedDescriptions() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-layout-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        AppState.shared = AppState(taskDirectory: root, sweepStalePanes: false)
        let library = SessionLibrary(fileURL: root.appendingPathComponent("catalog.json"), providers: [FixtureCatalog(root: root), FixtureCatalog(root: root, agent: .claude)])
        spin { library.organizationReady }
        library.updateOrganization { $0.projects.append(SessionProject(name: "lightty")) }
        spin { !library.saving }
        let panel = PrimarySidebar(headerCenterY: 20, mode: .sessions, library: library)
        library.start()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 270, height: 720),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = panel
        spin { library.loaded && !library.loading }
        for mode in PrimarySidebarMode.allCases {
            panel.selectMode(mode)
            spin { !library.loading }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                panel.appearance = NSAppearance(named: appearance)
                panel.layoutSubtreeIfNeeded()
                let list = try XCTUnwrap(descendants(panel).compactMap { $0 as? SidebarListScrollView }
                    .first { !$0.isHiddenOrHasHiddenAncestor })
                let listFrame = panel.convert(list.bounds, from: list)
                if let content = descendants(panel).first(where: { $0 is SessionsSidebarContent && !$0.isHiddenOrHasHiddenAncestor }) {
                    let contentFrame = panel.convert(content.bounds, from: content)
                    XCTAssertEqual(listFrame.maxY, contentFrame.maxY, accuracy: 0.5,
                                   "Sessions must not reserve space for the removed inline search field")
                }
                XCTAssertEqual(listFrame.minX, SidebarListScrollView.leadingMargin, accuracy: 0.5)
                XCTAssertEqual(panel.bounds.maxX - listFrame.maxX, SidebarListScrollView.trailingMargin, accuracy: 0.5)
                let texts = descendants(panel).compactMap { $0 as? NSTextField }.filter { !$0.isHiddenOrHasHiddenAncestor }
                let hint = try XCTUnwrap(texts.first { $0.stringValue == mode.hint })
                let title = try XCTUnwrap(panel.subviews.compactMap { $0 as? NSButton }.first { $0.title == mode.title })
                XCTAssertEqual(title.frame.minY - hint.frame.maxY, 4, accuracy: 0.5)
                XCTAssertGreaterThan(hint.frame.height, 0)
                if let path = ProcessInfo.processInfo.environment["LIGHTTY_UI_SNAPSHOT_DIR"],
                   let bitmap = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) {
                    panel.cacheDisplay(in: panel.bounds, to: bitmap)
                    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: URL(fileURLWithPath: path).appendingPathComponent("\(mode.rawValue)-\(appearance.rawValue).png"))
                }
            }
        }
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
        XCTAssertTrue(descendants(panel).compactMap { $0 as? NSButton }.contains { $0.title.contains(L("Handoff tasks")) })
    }

    func testOldWindowSnapshotDefaultsToHandoffCompatibleNil() throws {
        let data = Data("{\"activeTabIndex\":0,\"tabs\":[],\"taskPanelOpen\":true,\"tabSidebarOpen\":false}".utf8)
        let decoded = try JSONDecoder().decode(WindowSnapshot.self, from: data)
        XCTAssertNil(decoded.primarySidebarMode)
    }

    func testProjectWritesAreAtomicAndCorruptFileIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("session-project-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("library.json")
        let library = SessionLibrary(fileURL: file, providers: [])
        spin { library.organizationReady }
        library.updateOrganization { $0.projects.append(SessionProject(name: "Project")) }
        spin { !library.saving }
        XCTAssertEqual(try JSONDecoder().decode(SessionOrganization.self, from: Data(contentsOf: file)).projects.first?.name, "Project")
        let broken = Data("{broken".utf8)
        try broken.write(to: file)
        let corrupt = SessionLibrary(fileURL: file, providers: [])
        spin { corrupt.storageError != nil }
        corrupt.updateOrganization { $0.projects.append(SessionProject(name: "Do not overwrite")) }
        XCTAssertEqual(try Data(contentsOf: file), broken)
    }

    private func spin(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition())
    }
    private func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
}

private struct FixtureCatalog: SessionCatalogProvider {
    let root: URL
    var agent: SessionAgent = .codex
    /// 让读取真的占住一点时间。真实 provider 要起一个子进程（几百毫秒），
    /// 而瞬时返回的 fixture 会让「开始读」和「读完」落进同一拍——那样转圈根本不出现，
    /// 测不出「读的时候要有转圈」。只在需要这条覆盖的用例里传。
    var delay: TimeInterval = 0
    /// 需要一条长到能滚动的列表时传。默认两条，保持既有用例不变。
    var count: Int = 2
    var source: SessionCatalogSource { .init(agent: agent, root: root, executable: "/bin/false") }
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
