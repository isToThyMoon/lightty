import AppKit
import GhosttyKit
import LighttyCore
import XCTest
@testable import lightty

/// 真实 spawn 一个 pane 的 shell，验证 `LIGHTTY_PANE_ID` / `LIGHTTY_SOCK` 到达了
/// shell 环境——无论 core 当前的明暗条件态是什么。
///
/// 背景：libghostty 在 `Surface.init` 里发现 app 级条件态（`ghostty_app_set_color_scheme`
/// 上报的 light/dark）与 config 自带的条件态不一致时，会按 replay 重建一份 config，
/// 只显式保留 working-directory；per-surface 注入的 env 不在 replay 里，会被整份丢掉。
/// 宿主用 `theme = light:X,dark:Y`，所以只要明暗变化先于 spawn 到达、而 config 还没
/// 同步跟上，pane 的 hook 就永远收不到自己的身份。`GhosttyRuntime.setColorScheme`
/// 负责把这段空窗关掉；`settle: false` 的用例就是在盯这个空窗。
@MainActor
final class SurfaceEnvironmentTests: XCTestCase {
    private var directory: URL!
    private var previousAppState: AppState?

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        previousAppState = AppState.shared
        AppState.shared = AppState(taskDirectory: directory, sweepStalePanes: false)
        if GhosttyRuntime.shared == nil { GhosttyRuntime.shared = GhosttyRuntime() }
    }

    override func tearDown() {
        GhosttyRuntime.shared.setColorScheme(GHOSTTY_COLOR_SCHEME_LIGHT)
        AppState.shared = previousAppState ?? AppState.shared
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testPaneEnvReachesShellUnderLightScheme() throws {
        let env = try spawnAndDumpEnvironment(scheme: GHOSTTY_COLOR_SCHEME_LIGHT)
        XCTAssertTrue(env.hasPaneID, "light: env=\(env.summary)")
        XCTAssertTrue(env.hasSocket, "light: env=\(env.summary)")
    }

    func testPaneEnvReachesShellUnderDarkScheme() throws {
        let env = try spawnAndDumpEnvironment(scheme: GHOSTTY_COLOR_SCHEME_DARK)
        XCTAssertTrue(env.hasPaneID, "dark: env=\(env.summary)")
        XCTAssertTrue(env.hasSocket, "dark: env=\(env.summary)")
    }

    func testPaneEnvReachesShellWhenSpawnedRightAfterDarkScheme() throws {
        let env = try spawnAndDumpEnvironment(scheme: GHOSTTY_COLOR_SCHEME_DARK, settle: false)
        XCTAssertTrue(env.hasPaneID, "dark/no-settle: env=\(env.summary)")
        XCTAssertTrue(env.hasSocket, "dark/no-settle: env=\(env.summary)")
    }

    private struct DumpedEnvironment {
        let paneID: UUID
        let lines: [String]
        var hasPaneID: Bool { lines.contains("LIGHTTY_PANE_ID=\(paneID.uuidString)") }
        var hasSocket: Bool { lines.contains { $0.hasPrefix("LIGHTTY_SOCK=") } }
        var summary: String {
            lines.filter { $0.hasPrefix("LIGHTTY_") || $0.hasPrefix("GHOSTTY_") || $0.hasPrefix("TERM") }
                .joined(separator: " ")
        }
    }

    private func spawnAndDumpEnvironment(scheme: ghostty_color_scheme_e, settle: Bool = true) throws -> DumpedEnvironment {
        GhosttyRuntime.shared.setColorScheme(scheme)
        // 明暗切换还会让 core 请求一次 async 的 soft reload；settle 时先把它跑完，
        // 否则模拟启动时「上报明暗后立刻恢复 pane」的时序。
        if settle { pump(0.5) }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let pane = PaneView()
        pane.frame = window.contentView!.bounds
        window.contentView?.addSubview(pane)
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            pane.removeFromSuperview()
            PaneRuntimeDirectory.destroy(paneID: pane.dragIdentifier.uuidString)
        }
        XCTAssertNotNil(pane.terminal.surface, "surface should spawn once the pane is in a window")

        // shell 就绪 = shell 集成报了首个 OSC 7（与恢复会话敲 --resume 的时机一致）。
        try wait(15, "shell ready") { pane.terminal.currentWorkingDirectory != nil }

        let output = directory.appendingPathComponent("env-\(pane.dragIdentifier.uuidString).txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pane.terminal.sendText("env > '\(output.path)'; touch '\(output.path).done'")
        _ = pane.terminal.sendReturn()
        try wait(10, "env dump") { FileManager.default.fileExists(atPath: output.path + ".done") }

        let lines = try String(contentsOf: output, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        return DumpedEnvironment(paneID: pane.dragIdentifier, lines: lines)
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func wait(_ timeout: TimeInterval, _ what: String, until condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for \(what)"); throw CancellationError() }
            pump(0.05)
        }
    }
}
