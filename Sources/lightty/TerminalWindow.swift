import AppKit
import GhosttyKit

/// 分隔线颜色来自 config（split-divider-color，未设时官方公式推导），厚度 1pt。
final class PaneSplitView: NSSplitView {
    override var dividerColor: NSColor { GhosttyRuntime.shared.configValues.splitDividerColor }
    override var dividerThickness: CGFloat { 1 }
}

/// 终端窗口：保留一条原生标题栏作顶部操作栏（红黄绿三键 + 侧边栏按钮，
/// 2026-08-23 用户定稿，推翻此前的整体隐藏方案）。标题栏透明化、无标题文字，
/// 底色随 config；仍不读 macos-titlebar-style（有意分叉）。
final class TerminalWindow: NSWindow {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false

        let cfg = GhosttyRuntime.shared.configValues
        if let appearance = cfg.appearance { self.appearance = appearance }
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
