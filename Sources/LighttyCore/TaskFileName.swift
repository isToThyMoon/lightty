import Foundation

/// 任务名 → 文件名净化，规则见 docs/task-format.md
public enum TaskFileName {
    /// 删 `/` 与 `:`，连续空白折叠为单空格并去首尾，空结果回退为 "task"
    public static func sanitize(_ name: String) -> String {
        let stripped = name.filter { $0 != "/" && $0 != ":" }
        let collapsed = stripped
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return collapsed.isEmpty ? "task" : collapsed
    }
}
