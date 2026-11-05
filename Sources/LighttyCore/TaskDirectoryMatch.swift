import Foundation

/// 判断任务的创建目录与终端当前目录是否属于同一处工作现场，供任务选择器把相关任务排到前面。
public enum TaskDirectoryMatch {
    /// 相等或互为祖先即相关。家目录和根目录几乎是所有路径的祖先，只算精确相等，
    /// 否则在家目录开的终端会把所有任务都判成「此目录」。
    public static func isRelated(taskDirectory: String, terminalDirectory: String, home: String) -> Bool {
        let task = normalized(taskDirectory), terminal = normalized(terminalDirectory)
        guard !task.isEmpty, !terminal.isEmpty else { return false }
        if task == terminal { return true }
        let broad = ["/", normalized(home)]
        guard !broad.contains(task), !broad.contains(terminal) else { return false }
        return task.hasPrefix(terminal + "/") || terminal.hasPrefix(task + "/")
    }

    private static func normalized(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
