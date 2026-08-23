import AppKit
import LighttyCore

/// 恢复流程（HANDOVER 8.2）：休眠任务 → 摘要确认 → 开 shell + 预填充建议命令，回车即走。
/// 30 天内同工具有 session id 时预填 `<tool> --resume <id>`；否则预填注入 handoff 的新会话命令。
enum RestoreFlow {
    static func begin(fileURL: URL, task: TaskFile) {
        let alert = NSAlert()
        alert.messageText = "恢复任务：\(task.name)"
        alert.informativeText = summarize(task.body)
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let pane = PaneView()
        pane.bind(to: fileURL, name: task.name, status: task.status)
        AppState.shared.newWindow(initialPane: pane)

        // 预填充不带回车：用户过目后自己回车
        let command = suggestedCommand(for: task, fileURL: fileURL)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            pane.terminal.sendText(command)
        }
    }

    static func suggestedCommand(for task: TaskFile, fileURL: URL) -> String {
        if let session = task.sessions.last,
           Date().timeIntervalSince(task.updated) < 30 * 24 * 3600 {
            return "\(session.tool) --resume \(session.id)"
        }
        // 注入 handoff 的新会话命令；单引号包裹防 shell 展开
        let prompt = HandoffPrompt.resume(taskFilePath: fileURL.path)
            .replacingOccurrences(of: "'", with: "'\\''")
        let tool = task.tool ?? "claude"
        return "\(tool) '\(prompt)'"
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
