import AppKit

/// 常用操作的 SF Symbols 语义入口。新场景可直接选择合适的 symbol；重复语义再收敛到这里。
/// 品牌图标由 AgentSessionIcon 提供；旋转/展开行为由 RefreshButton、SidebarDisclosureButton 提供。
enum ShellSymbol {
    static let rename = "pencil"
    static let archive = "archivebox"
    static let restore = "arrow.uturn.backward"
    static let delete = "trash"
    static let project = "folder"
    static let terminal = "terminal"
    static let newWindow = "macwindow.badge.plus"
    static let search = "magnifyingglass"
    static let create = "doc.badge.plus"
    static let sidebar = "sidebar.left"
    static let more = "ellipsis"
    static let close = "xmark"
    static let add = "plus"
    /// 刷新中要原地旋转。单箭头的箭头头部让墨迹质心偏离画布中心约 0.8pt，转起来画小圈、
    /// 看着发抖；两个箭头中心对称，质心几乎就在旋转中心上（约 0.08pt）。
    static let refresh = "arrow.triangle.2.circlepath"
    static let disclosure = "chevron.right"
    static let tab = "rectangle.on.rectangle"
    static let collapsedTab = "rectangle.fill.on.rectangle.fill"
    static let newTab = "plus.rectangle.on.rectangle"
    static let splitRight = "rectangle.split.2x1"
    static let splitDown = "rectangle.split.1x2"
}

/// SF Symbol 图像缓存。`NSImage` 是可共享的不可变对象，同名同配置的符号在
/// 所有行之间复用一份；侧栏滚动起手时 NSTableView 会一次建出十几行，每行
/// 都走 `NSImage(systemSymbolName:)` + `withSymbolConfiguration` 是那几帧里
/// 可观的开销。仅主线程使用。
enum SymbolImages {
    private static var cache: [String: NSImage] = [:]

    /// 带 pointSize/weight 配置的符号图。
    static func image(
        _ name: String, pointSize: CGFloat, weight: NSFont.Weight, description: String? = nil
    ) -> NSImage? {
        let key = "\(name)|\(pointSize)|\(weight.rawValue)|\(description ?? "")"
        if let cached = cache[key] { return cached }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
        cache[key] = image
        return image
    }

    /// 未配置尺寸的符号图（由控件自己的 `symbolConfiguration` 决定大小）。
    static func image(_ name: String, description: String? = nil) -> NSImage? {
        let key = "\(name)|-|-|\(description ?? "")"
        if let cached = cache[key] { return cached }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        cache[key] = image
        return image
    }
}
