import AppKit
import LighttyCore
import Testing
@testable import lightty

@MainActor
struct PaneStatusLabelTests {
    /// Supply window-server visibility without bringing a test window in front of the user.
    private final class VisibleWindow: NSWindow {
        override var occlusionState: NSWindow.OcclusionState { [.visible] }
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua], [PaneActivity.done, .attention])
    func breathChangesRenderedColorWithoutChangingTextGeometry(appearance: NSAppearance.Name, activity: PaneActivity) throws {
        _ = NSApplication.shared
        let label = PaneStatusLabel()
        label.appearance = NSAppearance(named: appearance)
        label.apply(.init(ts: .distantPast, state: activity), isUnread: true)
        #expect(label.stringValue == (activity == .done ? "✓ \(L("Finished"))" : L("Needs you")))
        label.sizeToFit()
        let window = VisibleWindow(contentRect: label.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = label
        let size = label.intrinsicContentSize, frame = label.frame
        // Step the production animation's native progress API for deterministic snapshots.
        let animation = StatusColorAnimation(label: label)
        animation.currentProgress = 0
        let bright = try render(label)
        animation.currentProgress = 0.5
        var expectedSubdued: NSColor?
        label.effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = activity == .done ? ShellStyle.statusDone : ShellStyle.statusAttention
            expectedSubdued = accent.blended(withFraction: 0.2, of: ShellStyle.secondaryText)
        }
        #expect(label.textColor == expectedSubdued, "The quiet phase retains 80% of the completion accent")
        let subdued = try render(label)
        animation.currentProgress = 1
        let returned = try render(label)
        // Native antialias coverage can differ by one pixel as foreground color changes.
        #expect(abs(bright.ink.width - subdued.ink.width) <= 1)
        #expect(abs(bright.ink.height - subdued.ink.height) <= 1)
        #expect(bright.ink == returned.ink)
        #expect(abs(bright.red - subdued.red) + abs(bright.green - subdued.green) > 0.03,
                "The native text's rendered pixels must change color, not just a model value")
        #expect(abs(bright.red - returned.red) < 0.01)
        #expect(abs(bright.green - returned.green) < 0.01)
        #expect(label.intrinsicContentSize == size && label.frame == frame)
        #expect(label.font == .systemFont(ofSize: 11.5, weight: .semibold))
        #expect(label.alphaValue == 1 && !label.drawsBackground)
    }

    @Test(arguments: [PaneActivity.done, .attention])
    func nativeAnimationRepeatsAndStopsWhenHiddenDetachedOrReused(activity: PaneActivity) async throws {
        _ = NSApplication.shared
        let label = PaneStatusLabel()
        label.apply(.init(ts: .distantPast, state: activity), isUnread: true)
        label.sizeToFit()
        #expect(label.breath == nil, "Detached labels must not animate")
        let window = VisibleWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 30),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = try #require(window.contentView)
        host.addSubview(label)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            #expect(label.breath == nil)
            #expect(label.textColor != ShellStyle.secondaryText)
            return
        }
        let animation = try #require(label.breath)
        let color = label.textColor
        try await Task.sleep(for: .milliseconds(400))
        #expect(animation.isAnimating && animation.currentProgress > 0)
        #expect(label.textColor != color)
        // Native completion callback must restart the next cycle, not stop after one breath.
        try await Task.sleep(for: .milliseconds(3100))
        #expect(label.breath != nil && label.breath !== animation)
        label.isHidden = true
        #expect(label.breath == nil)
        label.isHidden = false
        #expect(label.breath?.isAnimating == true)
        label.apply(.init(ts: .distantPast, state: .thinking), isUnread: false)
        #expect(label.breath == nil && label.textColor == ShellStyle.secondaryText)
        #expect(label.font == .systemFont(ofSize: 10.5, weight: .medium),
                "Reusing a completion label for a running state must restore the regular status style")
        label.apply(.init(ts: .distantPast, state: activity), isUnread: true)
        let detached = try #require(label.breath)
        label.removeFromSuperview()
        #expect(label.breath == nil && !detached.isAnimating)
    }

    @Test func acknowledgedAttentionRetainsTextAndColorWithoutBreathingAfterReattachment() throws {
        _ = NSApplication.shared
        let label = PaneStatusLabel()
        let status = PaneStatus(ts: .distantPast, state: .attention)
        let window = VisibleWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 30),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = try #require(window.contentView)
        host.addSubview(label)
        label.apply(status, isUnread: true)
        let animation = label.breath
        label.apply(status, isUnread: false)
        #expect(label.breath == nil && animation?.isAnimating != true)
        #expect(label.stringValue == L("Needs you") && !label.isHidden)
        #expect(label.font == .systemFont(ofSize: 11.5, weight: .semibold))
        label.removeFromSuperview()
        host.addSubview(label)
        #expect(label.breath == nil)
        label.effectiveAppearance.performAsCurrentDrawingAppearance {
            #expect(label.textColor == ShellStyle.statusAttention.blended(withFraction: 0, of: ShellStyle.secondaryText))
        }
        label.apply(.init(ts: .distantPast, state: .tool), isUnread: false)
        #expect(label.stringValue == L("Thinking") && label.textColor == ShellStyle.secondaryText)
    }

    private func render(_ label: NSTextField) throws -> (ink: CGRect, red: CGFloat, green: CGFloat) {
        label.displayIfNeeded()
        let bitmap = try #require(label.bitmapImageRepForCachingDisplay(in: label.bounds))
        label.cacheDisplay(in: label.bounds, to: bitmap)
        var ink = CGRect.null, red: CGFloat = 0, green: CGFloat = 0, count: CGFloat = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.5 else { continue }
                ink = ink.union(CGRect(x: x, y: y, width: 1, height: 1))
                red += color.redComponent; green += color.greenComponent; count += 1
            }
        }
        try #require(count > 10, "The label must actually draw readable text")
        return (ink, red / count, green / count)
    }
}
