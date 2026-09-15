import AppKit
import ObjectiveC

/// 测试里需要窗口「在屏幕上」的语义（成为 key、first responder、field editor、
/// tracking area、按 windowNumber 投递的事件、`isVisible`）但不该真的弹到用户
/// 屏幕上的窗口，一律经这两个方法 order 出来，不要直接调 `orderFront` /
/// `makeKeyAndOrderFront`。
///
/// 做法是 alpha 0，不是把 frame 挪到所有屏幕之外。实测（macOS 26，xctest 进程）：
///
/// - 挪出屏幕对 titled 窗口无效：frame 放到屏外再 `orderFront`，AppKit 的
///   `constrainFrameRect` 把它拉回 (0, 0)；order 之后再 `setFrameOrigin` 也会被约束成
///   标题栏留在屏内（{-260, -80}）。只有 borderless 和覆写了 `constrainFrameRect` 的
///   `PaneIdentityWindow` 能留在屏外，而要改的 11 处里 6 处是 titled。
/// - alpha 0 对各种样式都成立：`isVisible` 为真（PaneLauncher 靠它确认宿主窗口还在）、
///   `makeFirstResponder` 正常、field editor 照常生成、`NSApp.sendEvent` 按
///   windowNumber 投递的按键照常到达、`PaneIdentityWindow` 照常成为 key。
/// - 生产代码会改 alpha：`TerminalWindowController` 收到 INITIAL_SIZE 或 0.6 秒兜底时
///   `revealWindowIfNeeded` 把 alpha 设回 1（实测 order 后 1 秒内触发一次）。所以这里
///   用 KVO 钉住：任何把 alpha 改成非 0 的写入，在同一次 setter 调用里就被改回 0，
///   窗口服务器看不到中间值。钉子挂在窗口的关联对象上，随窗口一起释放。
///
/// 唯一的例外是 `LIGHTTY_UI_SNAPSHOT_DIR` 快照分支：它要用 `screencapture -l` 抓窗口
/// 像素，alpha 0 和挪到屏外的窗口都截不到（实测静默不产出文件），只能真的上屏；
/// 普通 `swift test` 走不到那条分支。
///
/// 回归保护见 `InvisibleWindowTests`。
extension NSWindow {
    /// 对应 `orderFront(nil)`：进入窗口列表但不上屏。
    func orderFrontInvisibly() {
        pinAlphaToZero()
        orderFront(nil)
        assert(alphaValue == 0 && isVisible, "窗口应当已 order 出来且不可见")
    }

    /// 对应 `makeKeyAndOrderFront(nil)`：不上屏地成为 key。
    func makeKeyAndOrderFrontInvisibly() {
        pinAlphaToZero()
        makeKeyAndOrderFront(nil)
        assert(alphaValue == 0 && isVisible, "窗口应当已 order 出来且不可见")
    }

    /// 是否已被钉在 alpha 0。
    var isPinnedInvisible: Bool {
        objc_getAssociatedObject(self, &alphaPinKey) != nil
    }
    private func pinAlphaToZero() {
        alphaValue = 0
        guard !isPinnedInvisible else { return }
        let pin = observe(\.alphaValue, options: [.new]) { window, _ in
            if window.alphaValue != 0 { window.alphaValue = 0 }
        }
        objc_setAssociatedObject(self, &alphaPinKey, pin, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

private nonisolated(unsafe) var alphaPinKey: UInt8 = 0
