import AppKit
import LighttyCore

/// 指示点的颜色呼吸：只给「还在跑」的两个状态（thinking / tool）。
///
/// 为什么是颜色，不是透明度或缩放：6pt 的点上，透明度变化落在察觉阈值边缘，看久了也注意不到；
/// 缩放让轮廓动起来，一屏十几行各跳各的就是杂乱。颜色在同一块面积里换深浅，安静但看得见，
/// 而且不占任何额外宽度——侧栏的宽度很紧。
///
/// 所有点共用一个时钟：相位一致时，多行一起呼吸读起来是一次心跳；各自从进入该状态那一刻
/// 起拍，才是此起彼伏。
enum StatusDotBreath {
    static let animationKey = "lightty.statusDot.breath"

    /// 半程时长沿用 `ShellStyle` 里调好的那两个：思考 1.5 秒，工具 1.0 秒（更活跃一点）。
    static func halfPeriod(for activity: PaneActivity?) -> TimeInterval? {
        switch activity {
        case .thinking: return ShellStyle.statusBreathDuration
        case .tool: return ShellStyle.statusToolBreathDuration
        default: return nil
        }
    }

    /// 呼到最轻时混进多少点后面的底色。0.55 是下限：再少就回到「根本注意不到」，
    /// 再多就接近整点消失，像故障闪烁。`surface` 是点所在表面的底色——侧栏是行底色，
    /// 终端头部是终端自己的背景色，混错了呼吸会朝着一个并不存在的颜色去。
    static func quiet(_ color: NSColor, into surface: NSColor = ShellStyle.sidebarBackground) -> NSColor {
        color.blended(withFraction: 0.55, of: surface) ?? color
    }

    /// 公共时钟的起点。进程内取一次，不随行的创建销毁变化。
    private static let epoch = CACurrentMediaTime()

    /// 装上或撤掉呼吸。`enabled` 由调用方判断：隐藏、窗口不可见、开了「减弱动态效果」
    /// 都不该跑。`color` 是这一刻圆点的静止色，呼吸在它和它的弱化版之间往返。
    static func apply(to layer: CALayer, color: NSColor, activity: PaneActivity?,
                      appearance: NSAppearance, enabled: Bool,
                      into surface: NSColor = ShellStyle.sidebarBackground) {
        guard enabled, let half = halfPeriod(for: activity) else {
            layer.removeAnimation(forKey: animationKey)
            return
        }
        let from = color.shellResolvedCGColor(for: appearance)
        let to = quiet(color, into: surface).shellResolvedCGColor(for: appearance)
        // 同一口气不重装：重装会把相位掐回起点，而 PreToolUse / PostToolUse 是成对高频来的，
        // 那样会变成一顿抽搐。颜色或节奏真的变了才换。
        if let existing = layer.animation(forKey: animationKey) as? CABasicAnimation,
           existing.duration == half,
           let existingFrom = existing.fromValue, CFEqual(existingFrom as CFTypeRef, from),
           let existingTo = existing.toValue, CFEqual(existingTo as CFTypeRef, to) {
            return
        }
        let animation = CABasicAnimation(keyPath: "backgroundColor")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = half
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = ShellStyle.easeInOutCubic
        // 接到公共时钟上：从本轮周期已经走过的位置起，而不是从头。一口气是半程的两倍。
        let elapsed = (CACurrentMediaTime() - epoch).truncatingRemainder(dividingBy: half * 2)
        animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - elapsed
        layer.add(animation, forKey: animationKey)
    }
}
