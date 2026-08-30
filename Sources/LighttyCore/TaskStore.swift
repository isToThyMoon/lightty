import Darwin
import Foundation

public enum TaskStoreError: Error {
    /// rename(2) 失败（临时文件已清理）
    case atomicRenameFailed(path: String, errno: Int32)
}

/// 任务目录的读写入口。所有写入走「同目录临时文件 + rename(2)」原子替换。
public final class TaskStore {
    /// 已做符号链接解析的目录（macOS 临时目录 /var → /private/var 陷阱）
    public let directory: URL
    private let clock: () -> Date
    private let fm = FileManager.default

    /// 目录不存在时自动创建（尽力而为，失败推迟到首次写入时暴露）
    public init(directory: URL, clock: @escaping () -> Date = Date.init) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory.resolvingSymlinksInPath()
        self.clock = clock
    }

    /// 写盘时间为秒精度，此处截断以保证返回值与落盘内容一致
    private func now() -> Date {
        Date(timeIntervalSince1970: clock().timeIntervalSince1970.rounded(.down))
    }

    // MARK: - 读

    /// 扫描目录下 *.md（忽略点开头文件）；单个非法文件进失败清单，不中断
    public func list() -> (tasks: [(fileURL: URL, task: TaskFile)], failures: [(fileURL: URL, error: Error)]) {
        var tasks: [(fileURL: URL, task: TaskFile)] = []
        var failures: [(fileURL: URL, error: Error)] = []
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names.sorted() {
            guard !name.hasPrefix("."), name.hasSuffix(".md") else { continue }
            let url = directory.appendingPathComponent(name)
            do {
                tasks.append((fileURL: url, task: try load(at: url)))
            } catch {
                failures.append((fileURL: url, error: error))
            }
        }
        return (tasks: tasks, failures: failures)
    }

    public func load(at fileURL: URL) throws -> TaskFile {
        try TaskFile.parse(Data(contentsOf: fileURL))
    }

    // MARK: - 写

    @discardableResult
    public func create(name: String, workdir: String, tool: String? = nil) throws -> (fileURL: URL, task: TaskFile) {
        let timestamp = now()
        let task = TaskFile(
            name: name, status: "active", workdir: workdir, tool: tool,
            created: timestamp, updated: timestamp
        )
        let url = uniqueURL(for: name)
        try atomicWrite(task.serialize(), to: url)
        return (fileURL: url, task: task)
    }

    /// 整体写回调用方修改过的 TaskFile，updated 由 store 刷新
    @discardableResult
    public func update(at fileURL: URL, task: TaskFile) throws -> TaskFile {
        var task = task
        task.updated = now()
        try atomicWrite(task.serialize(), to: fileURL)
        return task
    }

    /// 改 name 并把文件移到新净化名；先写新文件再删旧文件。返回新路径。
    @discardableResult
    public func rename(at fileURL: URL, to newName: String) throws -> URL {
        var task = try load(at: fileURL)
        task.name = newName
        task.updated = now()
        let target = uniqueURL(for: newName, allowing: fileURL)
        try atomicWrite(task.serialize(), to: target)
        if target.path != fileURL.path {
            try fm.removeItem(at: fileURL)
        }
        return target
    }

    /// 归档：移入 archive/ 子目录。list() 只扫顶层，归档后自然从列表消失；
    /// md 文件原样保留，用户可自行翻阅或另行同步。返回归档后路径。
    @discardableResult
    public func archive(at fileURL: URL) throws -> URL {
        let archiveDir = directory.appendingPathComponent("archive", isDirectory: true)
        try fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        let base = fileURL.deletingPathExtension().lastPathComponent
        var target = archiveDir.appendingPathComponent(fileURL.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = archiveDir.appendingPathComponent("\(base)-\(n).md")
            n += 1
        }
        try fm.moveItem(at: fileURL, to: target)
        return target
    }

    /// 追加会话；tool+id 相同视为重复，去重且不写盘
    @discardableResult
    public func appendSession(at fileURL: URL, tool: String, id: String) throws -> TaskFile {
        var task = try load(at: fileURL)
        let session = TaskSession(tool: tool, id: id)
        if task.sessions.contains(session) {
            return task
        }
        task.sessions.append(session)
        task.updated = now()
        try atomicWrite(task.serialize(), to: fileURL)
        return task
    }

    // MARK: - 内部

    /// 净化名对应的首个不存在路径；allowing 指向的现有文件视为可复用（rename 原地）
    private func uniqueURL(for name: String, allowing existing: URL? = nil) -> URL {
        let base = TaskFileName.sanitize(name)
        var candidate = directory.appendingPathComponent("\(base).md")
        var n = 2
        while fm.fileExists(atPath: candidate.path), candidate.path != existing?.path {
            candidate = directory.appendingPathComponent("\(base)-\(n).md")
            n += 1
        }
        return candidate
    }

    private func atomicWrite(_ data: Data, to dest: URL) throws {
        let tmp = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try data.write(to: tmp)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        guard Darwin.rename(tmp.path, dest.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: tmp)
            throw TaskStoreError.atomicRenameFailed(path: dest.path, errno: code)
        }
    }
}
