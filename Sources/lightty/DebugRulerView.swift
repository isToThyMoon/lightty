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
        let topOffset = padTop + (balance ? max(leftover, 0) / 2 : 0)

        let terminalTop = terminal.frame.minY == 0
            ? PaneHeaderView.height // flipped 坐标下 terminal 顶 = header 底
            : bounds.height - terminal.frame.maxY

        func line(_ y: CGFloat, _ color: NSColor, _ label: String, dashed: Bool = false) {
            guard y >= 0, y <= bounds.height else { return }
            color.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1
            if dashed { path.setLineDash([4, 4], count: 2, phase: 0) }
            path.move(to: NSPoint(x: 0, y: y))
            path.line(to: NSPoint(x: bounds.width, y: y))
            path.stroke()

            let text = NSAttributedString(string: label, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .bold),
                .foregroundColor: color,
                .backgroundColor: NSColor.black.withAlphaComponent(0.55),
            ])
            text.draw(at: NSPoint(x: bounds.width - text.size().width - 8, y: y + 1))
        }

        // pane 顶 = contentView 顶 = 标题栏底（标题栏 28pt 在本视图之上，画不进来）
        line(0, .systemBlue, "标题栏底 / pane 顶（上方为标题栏 28pt）")
        line(terminalTop, .systemRed, "header 底 = 终端视图顶（header \(Int(PaneHeaderView.height))pt）")
        line(terminalTop + topOffset, .systemGreen,
             String(format: "grid row0 顶（padding %.0f + balance %.1f = %.1fpt）",
                    padTop, balance ? max(leftover, 0) / 2 : 0, topOffset))
        for k in 1...3 {
            line(terminalTop + topOffset + CGFloat(k) * cellH, .systemOrange,
                 "row\(k) 顶（cell \(String(format: "%.0f", cellH))pt）", dashed: true)
        }
    }
}
