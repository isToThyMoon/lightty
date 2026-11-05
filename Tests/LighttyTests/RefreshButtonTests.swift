import AppKit
import QuartzCore
import Testing
@testable import lightty

@MainActor
struct RefreshButtonTests {
    @Test func refreshCanRestartDuringItsFinishingRevolution() async throws {
        _ = NSApplication.shared
        let button = RefreshButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        let window = NSWindow(contentRect: button.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = button
        button.layoutSubtreeIfNeeded()
        let image = button.image, frame = button.frame
        #expect(button.toolTip == L("Refresh"))
        button.isRefreshing = true
        #expect(button.accessibilityLabel() == L("Cancel"))
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            #expect(button.alphaValue == 0.45)
            button.isRefreshing = false
            #expect(button.alphaValue == 1)
            return
        }
        let layer = try #require(refreshRotationLayer(in: button.layer))
        let animation = try #require(layer.animation(forKey: "refresh.spin"))
        button.isRefreshing = false
        #expect(button.accessibilityLabel() == L("Refresh"))
        #expect(refreshRotationLayer(in: button.layer) === layer)
        button.isRefreshing = true
        try await Task.sleep(for: .seconds(1))
        #expect(layer.animation(forKey: "refresh.spin")?.beginTime == animation.beginTime,
                "A new load cancels the pending stop without restarting the rotation")
        button.isRefreshing = false
        // 上限就是契约：最多转完当前一圈（0.9 秒）就停，不能放宽。
        try await awaitUntil("rotation stops within one revolution", timeout: .milliseconds(1500)) {
            refreshRotationLayer(in: button.layer) == nil
        }
        #expect(button.image === image)
        #expect(button.frame == frame)
        #expect(CATransform3DIsIdentity(layer.transform))
    }
}

func refreshRotationLayer(in layer: CALayer?) -> CALayer? {
    guard let layer else { return nil }
    if layer.animation(forKey: "refresh.spin") != nil { return layer }
    return layer.sublayers?.lazy.compactMap { refreshRotationLayer(in: $0) }.first
}
