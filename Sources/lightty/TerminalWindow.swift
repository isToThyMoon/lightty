import AppKit
import GhosttyKit

/// 分隔线颜色来自 config（split-divider-color，未设时官方公式推导），厚度 1pt。
final class PaneSplitView: NSSplitView {
    override var dividerColor: NSColor { GhosttyRuntime.shared.configValues.splitDividerColor }
    override var dividerThickness: CGFloat { 1 }
}

/// 隐藏标题栏的终端窗口：pane header 取代标题栏（有意分叉，不读 macos-titlebar-style）。
final class TerminalWindow: NSWindow {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
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
        syncTitlebarHidden()
    }

    /// NSTitlebarContainerView 整体隐藏（HANDOVER 第 10 节）
    private func syncTitlebarHidden() {
        guard let themeFrame = contentView?.superview else { return }
        for child in themeFrame.subviews
        where String(describing: type(of: child)) == "NSTitlebarContainerView" {
            child.isHidden = true
        }
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        syncTitlebarHidden()
        // background-blur 走 libghostty 公开 API，窗口就绪后调用
        if GhosttyRuntime.shared.configValues.backgroundBlur > 0 {
            ghostty_set_window_background_blur(
                GhosttyRuntime.shared.app, Unmanaged.passUnretained(self).toOpaque())
        }
    }
}
