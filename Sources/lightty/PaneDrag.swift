import AppKit

extension NSPasteboard.PasteboardType {
    /// 与 Ghostty `ghosttySurfaceId` 同一职责：只在 lightty 进程内搬运现有 pane。
    static let lighttyPaneID = NSPasteboard.PasteboardType("com.lightty.pane-id")
}

/// 对齐 vendored Ghostty `TerminalSplitDropZone`：落点离哪条边最近，就把被拖 pane
/// 组装到目标 pane 的哪一侧。
enum PaneDropZone: CaseIterable, Equatable {
    case top, bottom, left, right

    /// 与官方逐式对齐：先归一化再比距离（对角线切出四个等面积三角区）。
    /// 绝对距离在瘦高 pane 里会让左右区吞掉几乎全部面积，上下分无从落点。
    /// 判序也保持官方一致：left → right → top → bottom。
    static func calculate(at point: NSPoint, in bounds: NSRect) -> PaneDropZone {
        guard bounds.width > 0, bounds.height > 0 else { return .right }
        let relX = (point.x - bounds.minX) / bounds.width
        let relY = (point.y - bounds.minY) / bounds.height
        let distToLeft = relX
        let distToRight = 1 - relX
        // AppKit y 轴向上：minY 是底边
        let distToBottom = relY
        let distToTop = 1 - relY
        let minDist = min(distToLeft, distToRight, distToTop, distToBottom)
        if minDist == distToLeft { return .left }
        if minDist == distToRight { return .right }
        if minDist == distToTop { return .top }
        return .bottom
    }

    func frame(in bounds: NSRect) -> NSRect {
        switch self {
        case .top:
            return NSRect(x: bounds.minX, y: bounds.midY,
                          width: bounds.width, height: bounds.height / 2)
        case .bottom:
            return NSRect(x: bounds.minX, y: bounds.minY,
                          width: bounds.width, height: bounds.height / 2)
        case .left:
            return NSRect(x: bounds.minX, y: bounds.minY,
                          width: bounds.width / 2, height: bounds.height)
        case .right:
            return NSRect(x: bounds.midX, y: bounds.minY,
                          width: bounds.width / 2, height: bounds.height)
        }
    }
}

/// Ghostty drop overlay 的 AppKit 对应物；只绘制，不参与命中测试。
final class PaneDropOverlayView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.24).cgColor
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.65).cgColor
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
