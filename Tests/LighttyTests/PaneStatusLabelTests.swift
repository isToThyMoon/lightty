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

    /// 呼吸动画随挂载/隐藏/复用启停的状态机；已读（isUnread=false）停呼吸、
    /// 文字与颜色保留、重挂不重启——端到端的重挂场景另见 PaneReadInteractionTests。
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
        try await awaitUntil("the breath advances and recolors the text") {
            animation.currentProgress > 0 && label.textColor != color
        }
        #expect(animation.isAnimating)
        // Native completion callback must restart the next cycle, not stop after one breath.
        // 一口气是 3.2 秒；把正在呼的这口缩短，只看呼完会不会接着呼下一口。
        animation.duration = 0.3
        try await awaitUntil("the next breath starts") { label.breath != nil && label.breath !== animation }
        label.isHidden = true
        #expect(label.breath == nil)
        label.isHidden = false
        #expect(label.breath?.isAnimating == true)
        label.apply(.init(ts: .distantPast, state: .thinking), isUnread: false)
        #expect(label.breath == nil && label.textColor == ShellStyle.secondaryText)

        // 已读：呼吸停下，文字留着，颜色停在静息的强调色；摘掉再挂回去也不重新呼吸。
        label.apply(.init(ts: .distantPast, state: activity), isUnread: true)
        let text = label.stringValue
        let acknowledged = try #require(label.breath)
        label.apply(.init(ts: .distantPast, state: activity), isUnread: false)
        #expect(label.breath == nil && !acknowledged.isAnimating)
        #expect(label.stringValue == text && !label.isHidden)
        label.removeFromSuperview()
        host.addSubview(label)
        #expect(label.breath == nil)
        label.effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = activity == .done ? ShellStyle.statusDone : ShellStyle.statusAttention
            #expect(label.textColor == accent.blended(withFraction: 0, of: ShellStyle.secondaryText))
        }
        label.apply(.init(ts: .distantPast, state: .tool), isUnread: false)
        #expect(label.stringValue == L("Thinking") && label.textColor == ShellStyle.secondaryText)

        // 再次未读后摘掉：呼吸随之停下。
        label.apply(.init(ts: .distantPast, state: activity), isUnread: true)
        let detached = try #require(label.breath)
        label.removeFromSuperview()
        #expect(label.breath == nil && !detached.isAnimating)
    }
}
