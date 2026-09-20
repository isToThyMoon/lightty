import Foundation

extension Notification.Name {
    /// 任务绑定变化。`object` 是发出变更的 `TaskBindings`，载荷由 `TaskBindingChange.from(_:)` 读取。
    ///
    /// 与 `lighttyTasksDidChange` 的分工：
    /// - 本通知：终端指向哪个任务变了——绑定 / 解绑 / 终端注销，经 `TaskBindings` 发起的
    ///   新建、改名、归档、删除，以及外部改了已绑定任务的名字。操作完成时同步发出。
    /// - `lighttyTasksDidChange`：任务目录里的文件变了，谁写的都算。
    ///   窗口结构变化另有 `lighttyWindowArrangementDidChange`。
    public static let lighttyTaskBindingsDidChange = Notification.Name("lighttyTaskBindingsDidChange")

    /// 任务目录里的文件变了（新建、改写、改名、移走），不论是 lightty 自己写的还是 Agent 按
    /// 交接协议写回的。`object` 是 `TaskBindings`，无载荷，收到的一方自己重读。
    ///
    /// 只由 `TaskBindings` 在主线程发出，来源是目录事件（防抖约 0.2 秒），所以 lightty 自己的
    /// 写入也要等这一拍才到；需要立刻看到结果的视图自己重读，不另发这条通知。
    public static let lighttyTasksDidChange = Notification.Name("lighttyTasksDidChange")
}

/// 终端绑着的任务：文件位置 + 绑定时（或最近一次改名后）的任务名。
public struct BoundTask: Equatable {
    public var fileURL: URL
    public var name: String

    public init(fileURL: URL, name: String) {
        self.fileURL = fileURL
        self.name = name
    }
}

/// 一次绑定操作的完整后果：为什么变、哪些终端从什么变成什么、涉及哪些任务文件。
public struct TaskBindingChange: Equatable {
    public enum Cause: Equatable {
        case bind, unbind, create, rename, archive, delete
        /// 终端本体释放。只丢映射，不是用户意义上的「解绑」。
        case paneRemoved
    }

    public struct Transition: Equatable {
        public let before: BoundTask?
        public let after: BoundTask?

        public init(before: BoundTask?, after: BoundTask?) {
            self.before = before
            self.after = after
        }
    }

    public let cause: Cause
    public let panes: [UUID: Transition]
    /// 涉及的任务文件（`standardizedFileURL`）：变更前后的绑定目标，加上操作对象本身
    /// ——没有终端绑着的任务被改名 / 归档也会出现在这里。
    public let tasks: Set<URL>

    public init(cause: Cause, panes: [UUID: Transition], tasks: Set<URL>) {
        self.cause = cause
        self.panes = panes
        self.tasks = tasks
    }

    static let userInfoKey = "change"

    public static func from(_ notification: Notification) -> TaskBindingChange? {
        notification.userInfo?[userInfoKey] as? TaskBindingChange
    }
}

/// 绑定表本身：纯值，没有磁盘、没有通知。每个修改返回受影响终端的前后值。
public struct TaskBindingTable: Equatable {
    public private(set) var byPane: [UUID: BoundTask] = [:]

    public init() {}

    public func task(for pane: UUID) -> BoundTask? { byPane[pane] }

    /// 同一文件的不同拼写（`./`、`..`）视为同一任务。
    public func panes(for fileURL: URL) -> Set<UUID> {
        let key = fileURL.standardizedFileURL
        return Set(byPane.compactMap { $0.value.fileURL.standardizedFileURL == key ? $0.key : nil })
    }

    public mutating func set(_ task: BoundTask?, for pane: UUID) -> TaskBindingChange.Transition {
        let before = byPane[pane]
        byPane[pane] = task
        return .init(before: before, after: task)
    }
}

/// 写给 agent hook 看的 handoff 指针（`~/.lightty/panes/<uuid>/task`）与它的去重标记。
/// hook 按这份文件把任务文档注入 agent 上下文，见 docs/hooks.md。
public protocol TaskPointerStore: AnyObject {
    /// 写指针：一行任务文件绝对路径。不动去重标记——路径变了 hook 自己会重注。
    func write(taskFile: URL, for pane: UUID)
    /// 删指针，连同 hook 的去重标记（`handoff.injected`）：否则同一会话里解绑再绑回
    /// 同一任务，hook 会以为已经注过而跳过。
    func clear(for pane: UUID)
}

/// 生产 adapter：真实的 pane 运行时目录。写入尽力而为——建不了目录只是这个终端没法注入。
public final class DiskTaskPointerStore: TaskPointerStore {
    private let root: URL

    public init(root: URL = PaneRuntimeDirectory.root) {
        self.root = root
    }

    public func write(taskFile: URL, for pane: UUID) {
        let id = pane.uuidString
        try? PaneRuntimeDirectory.create(paneID: id, root: root)
        try? PaneRuntimeDirectory.atomicWrite(Data((taskFile.path + "\n").utf8),
                                              to: PaneRuntimeDirectory.taskPointerFile(for: id, root: root))
    }

    public func clear(for pane: UUID) {
        let id = pane.uuidString
        try? FileManager.default.removeItem(at: PaneRuntimeDirectory.taskPointerFile(for: id, root: root))
        try? FileManager.default.removeItem(at: PaneRuntimeDirectory.handoffMarkerFile(for: id, root: root))
    }
}

/// 任务绑定的唯一所有者：终端（pane UUID）↔ 任务文件。
///
/// 任务文件的生命周期操作（新建、改名、归档、删除）也从这里发起，因为它们都要传导到
/// 绑着该任务的每个终端：改名换指针、归档 / 删除解绑。视图只读查询、只订阅变更，
/// 不再各自扫窗口比对 URL，也不自己写指针文件。
///
/// 终端「已打开」的范围就是存活的 `PaneView`：终端释放时调 `removePane`。
/// 主线程独占；变更同步发出，收到时查询已经是新值。
///
/// 任务目录的监听也归它：创建时开始、释放时结束。目录一变就发 `lighttyTasksDidChange`，
/// 并重读已绑定任务的名字，外部改了名就发 `rename` 绑定变更。
public final class TaskBindings {
    public let store: TaskStore
    private let pointers: TaskPointerStore
    private let center: NotificationCenter
    public private(set) var table = TaskBindingTable()
    /// 监听凭据；目录打不开时为 nil，行为同没有监听。
    private var folderWatch: AnyObject?

    public init(store: TaskStore, pointers: TaskPointerStore = DiskTaskPointerStore(),
                notificationCenter: NotificationCenter = .default,
                folderChanges: PathChangeSource = PathWatcher.changeSource) {
        self.store = store
        self.pointers = pointers
        self.center = notificationCenter
        do {
            // 弱引用：凭据由自己持有，回调再强引用自己就成环，监听永远停不下来。
            folderWatch = try folderChanges(store.directory) { [weak self] in
                guard Thread.isMainThread else {
                    DispatchQueue.main.async { self?.taskFolderDidChange() }
                    return
                }
                self?.taskFolderDidChange()
            }
        } catch {
            NSLog("task folder is not watched: \(error)")
        }
    }

    // MARK: - 查询

    public func task(for pane: UUID) -> BoundTask? { table.task(for: pane) }
    public func panes(for fileURL: URL) -> Set<UUID> { table.panes(for: fileURL) }
    public func isOpen(_ fileURL: URL) -> Bool { !panes(for: fileURL).isEmpty }

    // MARK: - 绑定

    /// 绑定（或换绑）任务：只改终端指向，不动终端名与 Agent 会话。
    public func bind(_ pane: UUID, to fileURL: URL, name: String) {
        let transition = attach(pane, to: BoundTask(fileURL: fileURL, name: name))
        publish(.bind, [pane: transition], subjects: [])
    }

    /// 解绑：没绑也照样清指针（与旧行为一致，保证 hook 那边没有残留）。
    public func unbind(_ pane: UUID) {
        let transition = detach(pane)
        publish(.unbind, [pane: transition], subjects: [])
    }

    /// 终端释放。运行时目录随终端注销整体删除，这里不重复动磁盘。
    public func removePane(_ pane: UUID) {
        guard table.task(for: pane) != nil else { return }
        let transition = table.set(nil, for: pane)
        publish(.paneRemoved, [pane: transition], subjects: [])
    }

    // MARK: - 任务文件生命周期

    /// 新建任务，可顺手绑到一个终端（身份面板里「新建并绑定」）。
    @discardableResult
    public func createTask(name: String, workdir: String, tool: String? = nil, body: String = "",
                           bindingTo pane: UUID? = nil) throws -> (fileURL: URL, task: TaskFile) {
        let created = try store.create(name: name, workdir: workdir, tool: tool, body: body)
        var transitions: [UUID: TaskBindingChange.Transition] = [:]
        if let pane {
            transitions[pane] = attach(pane, to: BoundTask(fileURL: created.fileURL, name: name))
        }
        publish(.create, transitions, subjects: [created.fileURL])
        return created
    }

    /// 改名走移动语义，路径会变：所有绑着它的终端换到新路径与新名字，指针跟着改。
    @discardableResult
    public func renameTask(at fileURL: URL, to name: String) throws -> URL {
        let renamed = try store.rename(at: fileURL, to: name)
        var transitions: [UUID: TaskBindingChange.Transition] = [:]
        for pane in table.panes(for: fileURL) {
            transitions[pane] = attach(pane, to: BoundTask(fileURL: renamed, name: name))
        }
        publish(.rename, transitions, subjects: [fileURL, renamed])
        return renamed
    }

    /// 归档（移入 archive/，文件保留）；绑着它的终端全部解绑。
    @discardableResult
    public func archiveTask(at fileURL: URL) throws -> URL {
        let archived = try store.archive(at: fileURL)
        publish(.archive, detachAll(from: fileURL), subjects: [fileURL])
        return archived
    }

    /// 删除（移到废纸篓，可恢复）；绑着它的终端全部解绑。
    public func deleteTask(at fileURL: URL) throws {
        try store.trash(at: fileURL)
        publish(.delete, detachAll(from: fileURL), subjects: [fileURL])
    }

    // MARK: - 任务目录变更

    /// 先同步绑定（外部改名），再通知列表重读：收到列表通知时终端标题已经是新名字。
    ///
    /// 只比较已绑定的任务。文件读不出来（交接协议的临时文件加 mv 之间可能短暂不在，或内容
    /// 写坏了）不算改名，也不解绑，保留现状。路径不变，指针文件不动。
    private func taskFolderDidChange() {
        var transitions: [UUID: TaskBindingChange.Transition] = [:]
        for (pane, bound) in table.byPane {
            guard let name = try? store.load(at: bound.fileURL).name, name != bound.name else { continue }
            transitions[pane] = table.set(BoundTask(fileURL: bound.fileURL, name: name), for: pane)
        }
        if !transitions.isEmpty { publish(.rename, transitions, subjects: []) }
        center.post(name: .lighttyTasksDidChange, object: self)
    }

    // MARK: - 内部

    private func attach(_ pane: UUID, to task: BoundTask) -> TaskBindingChange.Transition {
        let transition = table.set(task, for: pane)
        pointers.write(taskFile: task.fileURL, for: pane)
        return transition
    }

    private func detach(_ pane: UUID) -> TaskBindingChange.Transition {
        let transition = table.set(nil, for: pane)
        pointers.clear(for: pane)
        return transition
    }

    private func detachAll(from fileURL: URL) -> [UUID: TaskBindingChange.Transition] {
        var transitions: [UUID: TaskBindingChange.Transition] = [:]
        for pane in table.panes(for: fileURL) { transitions[pane] = detach(pane) }
        return transitions
    }

    private func publish(_ cause: TaskBindingChange.Cause, _ panes: [UUID: TaskBindingChange.Transition],
                         subjects: [URL]) {
        var tasks = Set(subjects.map(\.standardizedFileURL))
        for transition in panes.values {
            for task in [transition.before, transition.after].compactMap({ $0 }) {
                tasks.insert(task.fileURL.standardizedFileURL)
            }
        }
        let change = TaskBindingChange(cause: cause, panes: panes, tasks: tasks)
        center.post(name: .lighttyTaskBindingsDidChange, object: self,
                    userInfo: [TaskBindingChange.userInfoKey: change])
    }
}
