import AppKit
import LighttyCore
import Testing
@testable import lightty

@MainActor
struct StatusDotBreathTests {
    private func layer() -> CALayer { CALayer() }
    private let appearance = NSAppearance(named: .aqua)!

    private func apply(_ activity: PaneActivity?, to layer: CALayer, enabled: Bool = true) {
        StatusDotBreath.apply(to: layer, color: ShellStyle.dotColor(bound: true, activity: activity),
                              activity: activity, appearance: appearance, enabled: enabled)
    }

    /// 只有「还在跑」的两个状态呼吸；完成、等待、空闲是扫一眼就该认出的静止状态。
    @Test func onlyRunningStatesBreathe() {
        for activity in [PaneActivity.thinking, .tool] {
            let dot = layer()
            apply(activity, to: dot)
            #expect(dot.animation(forKey: StatusDotBreath.animationKey) != nil)
        }
        for activity in [PaneActivity.idle, .done, .attention] {
            let dot = layer()
            apply(activity, to: dot)
            #expect(dot.animation(forKey: StatusDotBreath.animationKey) == nil)
        }
        // 调用工具比思考更活跃：半程更短。
        let thinking = layer(), tool = layer()
        apply(.thinking, to: thinking)
        apply(.tool, to: tool)
        let slow = try? #require(thinking.animation(forKey: StatusDotBreath.animationKey))
        let fast = try? #require(tool.animation(forKey: StatusDotBreath.animationKey))
        #expect((fast?.duration ?? 0) < (slow?.duration ?? 0))
    }

    /// 相位对齐到公共时钟：同一时刻装上的两个点必须呼在同一口气上，否则一屏就是此起彼伏。
    @Test func dotsShareOnePhase() throws {
        let first = layer(), second = layer()
        apply(.thinking, to: first)
        apply(.thinking, to: second)
        let a = try #require(first.animation(forKey: StatusDotBreath.animationKey))
        let b = try #require(second.animation(forKey: StatusDotBreath.animationKey))
        #expect(abs(a.beginTime - b.beginTime) < 0.05)
        #expect(a.beginTime <= CACurrentMediaTime())
    }

    /// 重复装同一口气不重来：PreToolUse / PostToolUse 成对高频到达，重装会把相位掐回起点。
    @Test func reapplyingTheSameBreathKeepsItsPhase() throws {
        let dot = layer()
        apply(.thinking, to: dot)
        let first = try #require(dot.animation(forKey: StatusDotBreath.animationKey))
        apply(.thinking, to: dot)
        let again = try #require(dot.animation(forKey: StatusDotBreath.animationKey))
        #expect(first === again)
    }

    /// 看不见、或用户开了「减弱动态效果」时不呼吸，已经装上的要撤掉。
    @Test func invisibleOrReducedMotionStopsTheBreath() throws {
        let dot = layer()
        apply(.thinking, to: dot)
        #expect(dot.animation(forKey: StatusDotBreath.animationKey) != nil)
        apply(.thinking, to: dot, enabled: false)
        #expect(dot.animation(forKey: StatusDotBreath.animationKey) == nil)
    }

    /// 呼到最轻时仍是同一个色相的弱化版，不是消失：消失读起来像故障闪烁。
    @Test func theQuietPhaseKeepsTheStatusHue() {
        let color = ShellStyle.statusThinking
        let quiet = StatusDotBreath.quiet(color)
        #expect(quiet != color)
        appearance.performAsCurrentDrawingAppearance {
            let base = color.usingColorSpace(.sRGB)!
            let faded = quiet.usingColorSpace(.sRGB)!
            #expect(abs(base.hueComponent - faded.hueComponent) < 0.12)
            #expect(faded.saturationComponent < base.saturationComponent)
        }
    }
}
