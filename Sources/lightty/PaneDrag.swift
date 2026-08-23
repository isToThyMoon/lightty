import AppKit

extension NSPasteboard.PasteboardType {
    /// 与 Ghostty `ghosttySurfaceId` 同一职责：只在 lightty 进程内搬运现有 pane。
    static let lighttyPaneID = NSPasteboard.PasteboardType("com.lightty.pane-id")
}

/// 对齐 vendored Ghostty `TerminalSplitDropZone`：落点离哪条边最近，就把被拖 pane
/// 组装到目标 pane 的哪一侧。
enum PaneDropZone: CaseIterable, Equatable {
    case top, bottom, left, right

    static func calculate(at point: NSPoint, in bounds: NSRect) -> PaneDropZone {
        let distances: [(PaneDropZone, CGFloat)] = [
            (.left, max(0, point.x - bounds.minX)),
            (.right, max(0, bounds.maxX - point.x)),
            (.bottom, max(0, point.y - bounds.minY)),
            (.top, max(0, bounds.maxY - point.y)),
        ]
        return distances.min { $0.1 < $1.1 }?.0 ?? .right
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
