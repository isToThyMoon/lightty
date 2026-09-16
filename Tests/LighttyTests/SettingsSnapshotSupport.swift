import AppKit
import QuartzCore
import Testing

/// cacheDisplay 漏掉 layer-backed 栏位；视觉验收从窗口服务器抓取合成后的像素。
@MainActor
func captureSettingsWindow(_ window: NSWindow, to url: URL) throws {
    guard ProcessInfo.processInfo.environment["LIGHTTY_UI_SNAPSHOT_DIR"] != nil else { return }
    window.makeKeyAndOrderFront(nil)
    window.contentView?.layoutSubtreeIfNeeded()
    window.display()
    CATransaction.flush()
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
    try capture.run()
    capture.waitUntilExit()
    #expect(capture.terminationStatus == 0)
}
