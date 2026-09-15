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
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    let resolved = FinderServiceProvider.directories(fromPaths: [
        fixture.file.path,                       // 文件 → 父目录
        fixture.root.path,                       // 与上面重复，去重
        fixture.root.path + "/",                 // 尾斜杠也算重复
        fixture.nested.path,
        fixture.root.appendingPathComponent("missing").path,  // 不存在 → 跳过
        "relative/path",                         // 非绝对路径 → 跳过
        "   ",                                   // 空白 → 跳过
        "~",                                     // 纯文本路径里的 ~ 展开成家目录
    ])
    #expect(resolved.map(\.path) == [
        fixture.root.standardizedFileURL.path,
        fixture.nested.standardizedFileURL.path,
        home,
    ])
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
    ensureTerminalRuntime()
    try body(AppState.shared)
}

/// `open(_:target:in:)` 的落点规则：宿主窗口有无 × target。
struct FinderOpenTarget: CustomTestStringConvertible {
    let testDescription: String
    let hasHostWindow: Bool
    let target: FinderServiceProvider.Target
    /// 打开两个目录后应有的窗口数。
    let expectedWindows: Int

    static let all = [
        // 有窗口时每个目录一个 tab，都进这个窗口。
        FinderOpenTarget(testDescription: "key window hosts one tab per directory",
                         hasHostWindow: true, target: .tab, expectedWindows: 1),
        // 没有窗口可放 tab：第一个目录撑起新窗口，第二个进同一窗口的 tab，而不是再开一个窗口。
        FinderOpenTarget(testDescription: "no window falls back to one new window with tabs",
                         hasHostWindow: false, target: .tab, expectedWindows: 1),
        // target = .window 时每个目录各开一个窗口。
        FinderOpenTarget(testDescription: "window target opens one window per directory",
                         hasHostWindow: false, target: .window, expectedWindows: 2),
    ]
}

@MainActor
@Test(arguments: FinderOpenTarget.all)
func serviceOpensDirectoriesAtTheRequestedTarget(_ c: FinderOpenTarget) throws {
    let fixture = try ServiceFixture()
    defer { fixture.tearDown() }
    try withTestAppState { state in
        var host: TerminalWindowController?
        var before = 0
        if c.hasHostWindow {
            let controller = TerminalWindowController()
            state.windowControllers = [controller]
            host = controller
            before = controller.tabCount
        } else {
            #expect(state.windowControllers.isEmpty)
        }

        FinderServiceProvider().open([fixture.root, fixture.nested], target: c.target, in: state)
        defer { state.windowControllers.forEach { $0.window?.close() } }

        #expect(state.windowControllers.count == c.expectedWindows, "\(c)")
        switch c.target {
        case .tab:
            let controller = try #require(host ?? state.windowControllers.first, "\(c)")
            #expect(controller.tabCount == before + 2, "\(c)")
            let directories = controller.panes().suffix(2).map(\.terminal.launchConfiguration.workingDirectory)
            #expect(directories == [fixture.root.path, fixture.nested.path], "\(c)")
            // 最后加的 tab 成为活跃 tab，用户看到的就是刚打开的目录。
            #expect(controller.activePane?.terminal.launchConfiguration.workingDirectory == fixture.nested.path, "\(c)")
        case .window:
            #expect(state.windowControllers.map { $0.panes().first?.terminal.launchConfiguration.workingDirectory }
                == [fixture.root.path, fixture.nested.path], "\(c)")
        }
    }
}
