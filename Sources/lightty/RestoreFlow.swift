import AppKit
import LighttyCore

/// 恢复流程（2026-08-24 简化定稿）：休眠任务 → 摘要确认 → 开一个绑定该任务的新窗口。
/// **不自动注入/预填任何命令**——多行命令预填在 shell 里易碎，且 pane header 已有
/// 「注入」按钮：用户自己起 agent 后点「注入」让它读 handoff 继续，职责不重叠。
enum RestoreFlow {
    static func begin(fileURL: URL, task: TaskFile) {
        let alert = NSAlert()
        alert.messageText = "恢复任务：\(task.name)"
        alert.informativeText = summarize(task.body)
            + "\n\n恢复后在 pane 里启动 claude/codex，点 header 的「注入」让它接手。"
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let pane = PaneView()
        pane.bind(to: fileURL, name: task.name, status: task.status)
        AppState.shared.newWindow(initialPane: pane)
    }

    /// 摘要 = 正文「下一步」「当前状态」两节（进展/卡点/下一步的最短可读集）
    private static func summarize(_ body: String) -> String {
        let interesting = ["## 下一步", "## 当前状态", "## 卡点与风险"]
        var lines: [String] = []
        var keeping = false
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                keeping = interesting.contains(where: { line.hasPrefix($0) })
            }
            if keeping { lines.append(String(line)) }
            if lines.count > 30 { break }
        }
        let result = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "（handoff 正文为空）" : result
    }
}
