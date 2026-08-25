import AppKit
import GhosttyKit

/// LIGHTTY_DEBUG_LAYOUT 专用：在 pane 上叠加彩色标尺线，可视化
/// "窗口顶 → 第一行字" 的每段构成（chrome / padding+balance / 行界）。
/// 只读不拦截事件；正式运行不创建。
final class DebugRulerView: NSView {
    private unowned let terminal: TerminalSurfaceView

    init(terminal: TerminalSurfaceView) {
        self.terminal = terminal
        super.init(frame: .zero)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 从 Ghostty 全局配置文本解析 padding-top 与 balance，仅调试用——正式代码
    /// 使用的 terminal config 始终由 libghostty 自己加载，不经过这条文本解析路径。
    private lazy var paddingConfig: (top: CGFloat, balance: Bool) = {
        var top: CGFloat = 2 // ghostty 默认
        var balance = false
        let home = FileManager.default.homeDirectoryForCurrentUser
        for path in [".config/ghostty/config"] {
            guard let text = try? String(contentsOf: home.appendingPathComponent(path), encoding: .utf8)
            else { continue }
            for rawLine in text.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if key == "window-padding-y" {
                    // "10" 或 "top,bottom"
                    if let first = value.split(separator: ",").first,
                       let v = Double(first.trimmingCharacters(in: .whitespaces)) {
                        top = CGFloat(v)
                    }
                } else if key == "window-padding-balance" {
                    balance = (value == "true")
                }
            }
        }
        return (top, balance)
    }()

    override func draw(_ dirtyRect: NSRect) {
        guard let surface = terminal.surface else { return }
        let size = ghostty_surface_size(surface)
        guard size.cell_height_px > 0, let window else { return }

        let scale = window.backingScaleFactor
        let cellH = CGFloat(size.cell_height_px) / scale
        let viewH = terminal.bounds.height
        let (padTop, balance) = paddingConfig
        // 对齐 core 公式：usable = 视图高 - 上下 padding；余数 balance 时对半摊
        let rows = CGFloat(size.rows)
        let leftover = viewH - 2 * padTop - rows * cellH
        let balanceShare = balance ? max(leftover, 0) / 2 : 0
        let topOffset = padTop + balanceShare

        let headerTop: CGFloat = 0 // pane 顶（其上是标题栏，画不进本视图）
        let terminalTop = terminal.frame.minY == 0
            ? PaneHeaderView.height
            : bounds.height - terminal.frame.maxY
        let row0Top = terminalTop + topOffset

        let width = bounds.width

        // —— 色块区带：这一段"是什么"直接染色可见 ——
        func band(_ from: CGFloat, _ to: CGFloat, _ color: NSColor, alpha: CGFloat) {
            color.withAlphaComponent(alpha).setFill()
            NSRect(x: 0, y: from, width: width, height: to - from).fill(using: .sourceOver)
        }
        band(headerTop, terminalTop, .systemRed, alpha: 0.14)      // header 条
        band(terminalTop, row0Top, .systemGreen, alpha: 0.22)      // padding + balance 空白
        band(row0Top, row0Top + cellH, .systemOrange, alpha: 0.10) // 第一行格子

        // —— 左侧尺寸括号：|← 高度值 →| ——
        func bracket(_ from: CGFloat, _ to: CGFloat, _ color: NSColor, _ label: String) {
            let x: CGFloat = 14
            color.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.move(to: NSPoint(x: x - 5, y: from + 0.5))
            path.line(to: NSPoint(x: x + 5, y: from + 0.5))
            path.move(to: NSPoint(x: x, y: from + 0.5))
            path.line(to: NSPoint(x: x, y: to - 0.5))
            path.move(to: NSPoint(x: x - 5, y: to - 0.5))
            path.line(to: NSPoint(x: x + 5, y: to - 0.5))
            path.stroke()

            // 标签片：深底白字，压在内容上也可读
            let text = NSAttributedString(string: label, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor.white,
            ])
            let textSize = text.size()
            let chip = NSRect(
                x: x + 12,
                y: min(max((from + to) / 2 - textSize.height / 2 - 3, 0), bounds.height - textSize.height - 6),
                width: textSize.width + 14,
                height: textSize.height + 6)
            color.withAlphaComponent(0.92).setFill()
            NSBezierPath(roundedRect: chip, xRadius: 5, yRadius: 5).fill()
            text.draw(at: NSPoint(x: chip.minX + 7, y: chip.minY + 3))
        }

        bracket(headerTop, terminalTop, .systemRed,
                String(format: "pane header  %.0fpt", terminalTop - headerTop))
        bracket(terminalTop, row0Top, .systemGreen,
                String(format: "空白 %.1fpt = padding %.0f + 余数 %.1f（ghostty 配置）",
                       topOffset, padTop, balanceShare))
        bracket(row0Top, row0Top + cellH, .systemOrange,
                String(format: "第一行字格  %.0fpt", cellH))

        // 行界虚线（第 1~3 行）辅助看 starship 空行占了哪一行
        NSColor.systemOrange.withAlphaComponent(0.6).setStroke()
        for k in 1...3 {
            let y = row0Top + CGFloat(k) * cellH
            let dash = NSBezierPath()
            dash.lineWidth = 1
            dash.setLineDash([4, 4], count: 2, phase: 0)
            dash.move(to: NSPoint(x: 0, y: y))
            dash.line(to: NSPoint(x: width, y: y))
            dash.stroke()
        }
    }
}
