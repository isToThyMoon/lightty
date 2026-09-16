import AppKit

/// 优先沿目录边界缩短路径；最末级目录本身放不下时才截断它。
final class SidebarDirectoryLabel: NSTextField {
    var path = "" {
        didSet {
            guard path != oldValue else { return }
            stringValue = path
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width = ceil((path as NSString).size(withAttributes: [.font: font ?? ShellStyle.Font.caption]).width) + 4
        return size
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
