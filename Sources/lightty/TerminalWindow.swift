import AppKit
import GhosttyKit

/// 分隔线颜色来自 config（split-divider-color，未设时官方公式推导），厚度 1pt。
final class PaneSplitView: NSSplitView {
    override var dividerColor: NSColor { GhosttyRuntime.shared.configValues.splitDividerColor }
    override var dividerThickness: CGFloat { 1 }
}

/// 终端窗口：原生标题栏只承载红黄绿三键与侧栏按钮，content 以 full-size
/// 铺到窗口四边。工作区侧栏自行避让标题栏高度；右侧 terminal 则延伸到顶边。
/// 标题栏无系统标题文字，terminal surface 仍完整遵守 Ghostty config。
final class TerminalWindow: NSWindow {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        // lightty 的 tab 是窗口内自绘概念（一窗一侧栏 + N 个 pane 树容器）。
        // 原生 tab group 是多 NSWindow 结组、tab bar 横跨全窗宽，与侧栏语义冲突，禁用。
        tabbingMode = .disallowed
        // 窗口尺寸由 core 的 INITIAL_SIZE 决定（window-width/height × cell），
        // 系统状态恢复会用上次的旧框架覆盖它，禁用
        isRestorable = false

        // 不在 NSWindow 层设置 appearance：窗口同时承载 libghostty surface，壳层的
        // 浅色外观必须局限在自己的标题栏/侧边栏视图，不能扩散进 terminal host。

        let cfg = GhosttyRuntime.shared.configValues
        if cfg.isTransparent {
            // 官方 TerminalWindow.syncAppearance 同式：非不透明 + 近全透明白底
            isOpaque = false
            backgroundColor = NSColor.white.withAlphaComponent(0.001)
        } else {
            backgroundColor = cfg.backgroundColor
        }
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        // background-blur 走 libghostty 公开 API，窗口就绪后调用
        if GhosttyRuntime.shared.configValues.backgroundBlur > 0 {
            ghostty_set_window_background_blur(
                GhosttyRuntime.shared.app, Unmanaged.passUnretained(self).toOpaque())
        }
    }
}
