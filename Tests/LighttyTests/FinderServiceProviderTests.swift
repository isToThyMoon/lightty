import AppKit
import Testing
@testable import lightty

/// 临时目录树：dir/、dir/file.txt、dir/nested/。用完即删。
private struct ServiceFixture {
    let root: URL
    let file: URL
    let nested: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("finder-service-\(UUID().uuidString)", isDirectory: true)
        nested = root.appendingPathComponent("nested", isDirectory: true)
        file = root.appendingPathComponent("file.txt")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
    }

    func tearDown() { try? FileManager.default.removeItem(at: root) }
}

@Test func serviceResolvesFilesToParentAndSkipsMissingPaths() throws {
    let fixture = try ServiceFixture()
    defer { fixture.tearDown() }
    let resolved = FinderServiceProvider.directories(fromPaths: [
        fixture.file.path,                       // 文件 → 父目录
        fixture.root.path,                       // 与上面重复，去重
        fixture.root.path + "/",                 // 尾斜杠也算重复
        fixture.nested.path,
        fixture.root.appendingPathComponent("missing").path,  // 不存在 → 跳过
        "relative/path",                         // 非绝对路径 → 跳过
        "   ",                                   // 空白 → 跳过
    ])
    #expect(resolved.map(\.path) == [
        fixture.root.standardizedFileURL.path,
        fixture.nested.standardizedFileURL.path,
    ])
}

@Test func serviceExpandsTildeInPlainTextPaths() throws {
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    #expect(FinderServiceProvider.directories(fromPaths: ["~"]).map(\.path) == [home])
}

@Test func serviceReadsFileURLsBeforeFallingBackToText() throws {
    let fixture = try ServiceFixture()
    defer { fixture.tearDown() }
    let pasteboard = NSPasteboard(name: .init("lightty.test.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }

    pasteboard.clearContents()
    pasteboard.writeObjects([fixture.file as NSURL, fixture.nested as NSURL])
    #expect(FinderServiceProvider.directories(from: pasteboard).map(\.path) == [
        fixture.root.standardizedFileURL.path,
        fixture.nested.standardizedFileURL.path,
    ])

    // 其它 app 经 Services 传纯文本路径（可多行）时也能用。
    pasteboard.clearContents()
    pasteboard.setString("\(fixture.nested.path)\n\(fixture.file.path)\n", forType: .string)
    #expect(FinderServiceProvider.directories(from: pasteboard).map(\.path) == [
        fixture.nested.standardizedFileURL.path,
        fixture.root.standardizedFileURL.path,
    ])

    pasteboard.clearContents()
    #expect(FinderServiceProvider.directories(from: pasteboard).isEmpty)
}

@MainActor
private func withTestAppState(_ body: (AppState) throws -> Void) rethrows {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let previousState = AppState.shared
    defer {
        AppState.shared = previousState
        try? FileManager.default.removeItem(at: directory)
    }
    AppState.shared = AppState(taskDirectory: directory, sweepStalePanes: false)
    if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }
    try body(AppState.shared)
}

@MainActor
@Test func serviceAddsOneTabPerDirectoryToTheKeyWindow() throws {
    let fixture = try ServiceFixture()
    defer { fixture.tearDown() }
    withTestAppState { state in
        let controller = TerminalWindowController()
        defer { controller.window?.close() }
        state.windowControllers = [controller]
        let before = controller.tabCount

        FinderServiceProvider().open([fixture.root, fixture.nested], target: .tab, in: state)

        #expect(state.windowControllers.count == 1)
        #expect(controller.tabCount == before + 2)
        let directories = controller.panes().suffix(2).map(\.terminal.launchConfiguration.workingDirectory)
        #expect(directories == [fixture.root.path, fixture.nested.path])
        // 最后加的 tab 成为活跃 tab，用户看到的就是刚打开的目录。
        #expect(controller.activePane?.terminal.launchConfiguration.workingDirectory == fixture.nested.path)
    }
}

@MainActor
@Test func serviceFallsBackToNewWindowWhenNoWindowCanHostATab() throws {
    let fixture = try ServiceFixture()
    defer { fixture.tearDown() }
    try withTestAppState { state in
        #expect(state.windowControllers.isEmpty)

        FinderServiceProvider().open([fixture.root, fixture.nested], target: .tab, in: state)
        defer { state.windowControllers.forEach { $0.window?.close() } }

        // 第一个目录撑起新窗口，第二个进同一窗口的 tab，而不是再开一个窗口。
        #expect(state.windowControllers.count == 1)
        let controller = try #require(state.windowControllers.first)
        #expect(controller.tabCount == 2)
        #expect(controller.panes().map(\.terminal.launchConfiguration.workingDirectory)
            == [fixture.root.path, fixture.nested.path])
    }
}

@MainActor
@Test func serviceOpensOneWindowPerDirectory() throws {
    let fixture = try ServiceFixture()
    defer { fixture.tearDown() }
    withTestAppState { state in
        FinderServiceProvider().open([fixture.root, fixture.nested], target: .window, in: state)
        defer { state.windowControllers.forEach { $0.window?.close() } }

        #expect(state.windowControllers.count == 2)
        #expect(state.windowControllers.map { $0.panes().first?.terminal.launchConfiguration.workingDirectory }
            == [fixture.root.path, fixture.nested.path])
    }
}
