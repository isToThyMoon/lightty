import AppKit

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
