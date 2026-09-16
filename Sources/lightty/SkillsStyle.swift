import AppKit

/// Skills 的尺寸与排版；颜色、圆角和按钮复用 ShellStyle。
enum SkillsStyle {
    static let minimumWidth: CGFloat = 660
    static let minimumDetailWidth: CGFloat = 292
    static let compactBreakpoint: CGFloat = 1000
    static let sidebarWidth: CGFloat = 184
    static let compactSidebarWidth: CGFloat = 172
    static let listWidth: CGFloat = 232
    static let compactListWidth: CGFloat = 196
    static let topInset: CGFloat = 16
    static let inset: CGFloat = 16
    static let detailInset: CGFloat = 24
    static let navigationRowHeight: CGFloat = 32
    static let skillRowHeight: CGFloat = 64
    static let controlHeight: CGFloat = ShellStyle.chromeRowHeight
    static let titleFont = NSFont.systemFont(ofSize: 20, weight: .medium)
    static let nameFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let bodyFont = NSFont.systemFont(ofSize: 13)
    static let summaryFont = NSFont.systemFont(ofSize: 12)
    static let sectionFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    /// Version tags in the source tree; small enough to sit beside a name.
    static let captionFont = NSFont.systemFont(ofSize: 11)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
}

/// 保留 Markdown 原文结构的轻量阅读排版，不执行 HTML，也不加载远端图片。
enum SkillDocumentPresentation {
    static func text(_ source: String, raw: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        if raw {
            return NSAttributedString(string: source, attributes: [
                .font: SkillsStyle.codeFont, .foregroundColor: ShellStyle.primaryText,
                .paragraphStyle: paragraph,
            ])
        }
        var lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}"))
            .components(separatedBy: "\n")
        let result = NSMutableAttributedString(string: "")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { ["---", "..."].contains($0.trimmingCharacters(in: .whitespaces)) }) {
            let metadata = lines.prefix(end + 1).joined(separator: "\n") + "\n"
            result.append(NSAttributedString(string: metadata, attributes: [
                .font: SkillsStyle.codeFont, .foregroundColor: ShellStyle.secondaryText,
                .backgroundColor: ShellStyle.controlFill, .paragraphStyle: paragraph,
            ]))
            lines.removeFirst(end + 1)
        }
        var fence: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                if fence == nil { fence = marker; continue }
                if fence == marker { fence = nil; continue }
            }
            var display = line
            var font = fence == nil ? SkillsStyle.bodyFont : SkillsStyle.codeFont
            let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
            if fence == nil {
                let hashes = line.prefix(while: { $0 == "#" }).count
                if (1...6).contains(hashes), line.dropFirst(hashes).first == " " {
                    display = String(line.dropFirst(hashes + 1))
                    font = .systemFont(ofSize: hashes == 1 ? 18 : (hashes == 2 ? 15 : 13), weight: .semibold)
                    style.paragraphSpacingBefore = 8
                    style.paragraphSpacing = 4
                }
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: ShellStyle.primaryText, .paragraphStyle: style,
            ]
            if fence != nil { attributes[.backgroundColor] = ShellStyle.controlFill }
            if fence == nil,
               let parsed = try? AttributedString(markdown: display + "\n", options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)),
               let native = try? NSAttributedString(parsed, including: \.appKit) {
                let line = NSMutableAttributedString(attributedString: native)
                line.addAttributes(attributes, range: NSRange(location: 0, length: line.length))
                var offset = 0
                for run in parsed.runs {
                    let length = String(parsed[run.range].characters).utf16.count
                    let range = NSRange(location: offset, length: length)
                    var runFont = font
                    if let intent = run.inlinePresentationIntent {
                        if intent.contains(.code) {
                            runFont = SkillsStyle.codeFont
                            line.addAttribute(.backgroundColor, value: ShellStyle.controlFill, range: range)
                        } else {
                            if intent.contains(.stronglyEmphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask) }
                            if intent.contains(.emphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask) }
                        }
                    }
                    line.addAttribute(.font, value: runFont, range: range)
                    if let link = run.link, !["https", "http"].contains(link.scheme?.lowercased() ?? "") {
                        line.removeAttribute(.link, range: range)
                    }
                    offset += length
                }
                result.append(line)
            } else {
                result.append(NSAttributedString(string: display + "\n", attributes: attributes))
            }
        }
        return result
    }
}

/// 无可见分割线的列宽拖动区；保留七点命中宽度与调整光标，列之间由留白区分。
final class SkillsColumnDivider: NSView {
    var onDrag: ((CGFloat) -> Void)?
    private var grabOffset: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityOrientation(.vertical)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        guard let host = superview else { return }
        grabOffset = host.convert(event.locationInWindow, from: nil).x - frame.minX - 3
    }

    override func mouseDragged(with event: NSEvent) {
        guard let host = superview else { return }
        onDrag?(host.convert(event.locationInWindow, from: nil).x - grabOffset)
    }
}
