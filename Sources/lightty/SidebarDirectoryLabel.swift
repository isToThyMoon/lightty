import AppKit

/// 优先沿目录边界缩短路径；最末级目录本身放不下时才截断它。
final class SidebarDirectoryLabel: NSTextField {
    var path = "" {
        didSet {
            guard path != oldValue else { return }
            stringValue = path
            tailWidth.constant = width(of: Self.tail(of: path))
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    /// 缩到 `…/末级目录` 为止的宽度下限，优先级由使用方定：比相邻文字的抗压缩高，
    /// 空间不够时路径先缩到末级目录，再轮到邻居截断。
    private(set) lazy var tailWidth = widthAnchor.constraint(greaterThanOrEqualToConstant: 0)

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width = width(of: path)
        return size
    }

    private func width(of value: String) -> CGFloat {
        ceil((value as NSString).size(withAttributes: [.font: font ?? ShellStyle.Font.caption]).width) + 4
    }

    private static func tail(of path: String) -> String {
        let components = path.split(separator: "/")
        guard components.count > 1, let last = components.last else { return path }
        return "…/" + last
    }

    override func layout() {
        super.layout()
        let available = max(0, bounds.width - 4)
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? ShellStyle.Font.caption]
        func fits(_ value: String) -> Bool {
            (value as NSString).size(withAttributes: attributes).width <= available
        }
        var display = path
        if !fits(display) {
            let components = path.split(separator: "/")
            for offset in components.indices.dropFirst() {
                display = "…/" + components[offset...].joined(separator: "/")
                if fits(display) { break }
            }
        }
        if stringValue != display { stringValue = display }
    }
}
