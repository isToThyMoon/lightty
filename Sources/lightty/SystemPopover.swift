import AppKit

extension NSPopover {
    /// 去掉气泡那个三角。
    ///
    /// 系统没有公开开关。`shouldHideAnchor` 是 AppKit 内部的属性，用键值路径写进去；
    /// 先问一句它认不认这个 setter，将来某个系统版本拿掉了也只是三角回来，不会崩。
    ///
    /// 为什么非得用 NSPopover：这一档玻璃是它的私有框架视图自己画的。我们照着它
    /// 运行时的参数（material 0、窗口后模糊、跟随窗口活跃态、无遮罩）用
    /// `NSVisualEffectView` 复刻过，15 种材质、5 种外观、子窗口与独立窗口、
    /// `.borderless` 与 `.titled` 都比过，没有一档对得上——差别不在任何公开属性里。
    func hideAnchorArrow() {
        let setter = NSSelectorFromString("setShouldHideAnchor:")
        guard responds(to: setter) else { return }
        setValue(true, forKey: "shouldHideAnchor")
    }
}
