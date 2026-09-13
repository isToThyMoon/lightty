import AppKit
import LighttyCore

/// 新终端开到哪里：当前标签页分屏、新标签页、新窗口。启动浮层的三个单选、会话侧栏、
/// 原生选择器都用这一个值，不再各自用序号或另一套枚举。
enum TerminalLaunchDestination: CaseIterable, Equatable {
    case split, tab, window
}

/// 一次启动请求：启动什么、在哪个目录、挂不挂任务、开到哪里。
///
/// 它只是一个值。怎么检查、怎么拼命令、怎么关联、怎么放置，全部由 `PaneLauncher` 决定，
/// 调用方只描述意图，拿回结果再决定怎么提示用户。
struct TerminalLaunchRequest {
    enum Subject {
        /// 纯终端。`command` 是测试入口：让终端执行一条命令；产品路径一律传 nil。
        case shell(command: String?)
        /// 新 Agent 会话；`.terminal` 就是只开终端、不启动 Agent。
        case agent(LaunchAgent)
        /// 续接一段已有会话。已在本应用某个终端里开着时，改为聚焦那个终端。
        case resume(AgentSession, source: SessionCatalogSource)
        /// 打开 CLI 自带的会话选择器。它不指向任何会话。
        case sessionPicker(SessionCatalogSource)
        /// 按工作区快照重建（重启恢复）。目录、名字、任务、会话都取自快照，
        /// 请求里的目录与任务不参与。
        case snapshot(PaneSnapshot)
    }

    var subject: Subject
    /// 工作目录。续接时是对会话记录目录的覆盖（用户重新选过）；nil 表示用各自的默认值。
    var workingDirectory: String?
    /// 启动后绑定的任务，经 `TaskBindings` 建立。
    var task: BoundTask?
    var destination: TerminalLaunchDestination

    init(_ subject: Subject, workingDirectory: String? = nil, task: BoundTask? = nil,
         destination: TerminalLaunchDestination = .tab) {
        self.subject = subject
        self.workingDirectory = workingDirectory
        self.task = task
        self.destination = destination
    }
}

enum TerminalLaunchOutcome {
    /// 新终端已经装好并放到了指定去处。
    case launched(PaneView)
    /// 会话已在本应用某个终端里开着，聚焦了那个终端，没有新开。
    case focused(PaneView)
    case notLaunched(TerminalLaunchRefusal)
}

/// 没有启动的原因。怎么告诉用户（提示框、表单里一行红字、什么都不说）归调用方。
enum TerminalLaunchRefusal {
    /// 同一家 Agent 有会话正在删除。
    case deletingSession(SessionAgent)
    /// 同一段会话的上一次续接还在检查占用。
    case alreadyStarting
    /// 会话没有可用的工作目录，得让用户选一个再重新请求。
    case needsWorkingDirectory(message: String)
    /// 会话正开在别的终端里。
    case occupied(pid: Int32)
    /// CLI、配置来源或会话身份不可用，拼不出命令。
    case unavailable(Error)
    /// 没有地方放：分屏 / 标签页缺宿主窗口，或宿主窗口在检查期间关掉了。
    case noPlacement
}

/// 终端启动器：把「启动请求」变成装好并放到位的终端，或者一个没启动的原因。
///
/// 顺序固定：删除互斥 → 已打开则聚焦 → 恢复计划 → 占用检查 → surface 配置 → 会话关联
/// → 任务绑定 → 放置。以前这条路散在五处（启动浮层、续接、原生选择器、任务启动、
/// 重启恢复），各自拼命令、各自决定检查什么；现在它们只构造请求。
///
/// 模态界面不在这里：目录选择面板、占用提示框、错误框由调用方按结果呈现，
/// 所以整条链路可以脱离模态测试。
///
/// 主线程独占。占用检查会起子进程，放到 `occupancyQueue` 上做，结果回主线程。
final class PaneLauncher {
    typealias RunningPane = (controller: TerminalWindowController, pane: PaneView)

    private let sessionLibrary: SessionLibrary
    private let taskBindings: TaskBindings
    private let runningPanes: () -> [RunningPane]
    private let openWindow: (PaneView) -> Void
    private let locateExecutable: (String) -> String?
    private let occupancyQueue: DispatchQueue

    /// 正在删除会话的 Agent。删除确认框开着的时候也算。只拦可能碰到被删会话的启动：
    /// 续接（可能正是那一段）和原生选择器（可能在里面选中它）。新会话写的是另一段会话，
    /// 放行；代价是它若恰好在检查那几秒起来、还没登记身份，删除会多问一次「身份不明的进程」。
    private var deletingAgents = Set<SessionAgent>()
    /// 正在检查占用的会话。只是主线程上的请求合流，不是 Agent 锁；每次有界检查后释放。
    private var checking = Set<AgentSessionKey>()

    init(sessionLibrary: SessionLibrary, taskBindings: TaskBindings,
         runningPanes: @escaping () -> [RunningPane],
         openWindow: @escaping (PaneView) -> Void,
         locateExecutable: @escaping (String) -> String? = HookInstaller.locateExecutable,
         occupancyQueue: DispatchQueue = .global(qos: .userInitiated)) {
        self.sessionLibrary = sessionLibrary
        self.taskBindings = taskBindings
        self.runningPanes = runningPanes
        self.openWindow = openWindow
        self.locateExecutable = locateExecutable
        self.occupancyQueue = occupancyQueue
    }

    // MARK: - 删除互斥

    /// 删除流程开始（确认框弹出时）。同一家已有删除在进行返回 false。
    @discardableResult
    func beginDeleting(_ agent: SessionAgent) -> Bool { deletingAgents.insert(agent).inserted }
    func endDeleting(_ agent: SessionAgent) { deletingAgents.remove(agent) }
    func isDeleting(_ agent: SessionAgent) -> Bool { deletingAgents.contains(agent) }
    /// 这段会话正在续接途中（占用检查未返回）。删除要避开它。
    func isStarting(_ key: AgentSessionKey) -> Bool { checking.contains(key) }

    // MARK: - 启动

    /// 走完整条链路。续接会话要异步检查占用，其余请求同步完成；`completion` 总在主线程调用。
    func launch(_ request: TerminalLaunchRequest, in host: TerminalWindowController?,
                completion: @escaping (TerminalLaunchOutcome) -> Void = { _ in }) {
        switch request.subject {
        case .resume(let session, let source):
            resume(session, source: source, request: request, host: host, completion: completion)
            return
        case .sessionPicker(let source):
            if deletingAgents.contains(source.agent) {
                return completion(.notLaunched(.deletingSession(source.agent)))
            }
        case .shell, .agent, .snapshot:
            break
        }
        guard request.destination == .window || host != nil else {
            return completion(.notLaunched(.noPlacement))
        }
        do {
            let pane = build(try resolve(request))
            place(pane, at: request.destination, in: host)
            completion(.launched(pane))
        } catch {
            completion(.notLaunched(.unavailable(error)))
        }
    }

    /// 只装配：surface 配置、会话关联、任务绑定。不做删除互斥与占用检查，也不放置。
    /// 目前只有测试用它检查装出来的终端；重启恢复走 `restoredPane(from:)`。
    func makePane(for request: TerminalLaunchRequest) throws -> PaneView {
        build(try resolve(request))
    }

    /// 重启恢复的装配。快照恢复不会失败：依赖缺失时保留意图、不启动 Agent。
    func restoredPane(from snapshot: PaneSnapshot) -> PaneView {
        build(restoring(snapshot))
    }

    /// 续接之前要不要让用户挑目录，以及挑之前该跟他说什么。返回 nil 表示直接能用。
    ///
    /// 两件不同的事说法也得不同：目录记下来了但现在不在，和**压根就没读出目录**。
    /// 后者说成「原会话目录不存在」是替用户下了一个我们并不知道的结论——目录多半
    /// 还好端端在那儿，只是这段会话的工作目录我们没拿到。
    static func folderPromptMessage(for path: String?) -> String? {
        guard let path else {
            return L("This session has no recorded folder. Choose a folder to continue.")
        }
        guard isDirectory(path) else {
            return L("The original session folder is missing. Choose a folder to continue.")
        }
        return nil
    }

    // MARK: - 续接

    private func resume(_ session: AgentSession, source: SessionCatalogSource, request: TerminalLaunchRequest,
                        host: TerminalWindowController?, completion: @escaping (TerminalLaunchOutcome) -> Void) {
        let key = session.key
        guard !deletingAgents.contains(key.agent) else {
            return completion(.notLaunched(.deletingSession(key.agent)))
        }
        if let existing = openPane(for: key) {
            // Internal navigation does not require a hook-confirmed resume or another Agent process.
            focus(existing)
            return completion(.focused(existing.pane))
        }
        guard !checking.contains(key) else { return completion(.notLaunched(.alreadyStarting)) }
        let directory = request.workingDirectory ?? session.workingDirectory
        if let message = Self.folderPromptMessage(for: directory) {
            return completion(.notLaunched(.needsWorkingDirectory(message: message)))
        }
        let assembly: Assembly
        do { assembly = try resuming(session, source: source, workingDirectory: directory, task: request.task) }
        catch { return completion(.notLaunched(.unavailable(error))) }

        checking.insert(key)
        let provider = sessionLibrary.provider(for: key.agent) ?? source.makeProvider()
        occupancyQueue.async { [weak self, weak host] in
            let occupancy = provider.occupancy(of: key)
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking.remove(key)
                // 检查期间宿主窗口关了：没有地方提示，也不该凭空冒出一个终端。
                guard let host, let window = host.window, window.isVisible else {
                    return completion(.notLaunched(.noPlacement))
                }
                if case .inUse(let pid) = occupancy {
                    return completion(.notLaunched(.occupied(pid: pid)))
                }
                // Absence of evidence is not a lock guarantee. The native CLI remains authoritative.
                let pane = self.build(assembly)
                self.place(pane, at: request.destination, in: host)
                completion(.launched(pane))
            }
        }
    }

    /// 点击已打开会话聚焦已有终端；一对多时取窗口树遍历中的第一个。
    /// 先复核已知进程，覆盖退出通知还在主队列等待的窗口。
    private func openPane(for key: AgentSessionKey) -> RunningPane? {
        for entry in runningPanes() { entry.pane.reconcileSessionProcess() }
        let ids = sessionLibrary.openPaneIDs(for: key)
        return runningPanes().first { ids.contains($0.pane.dragIdentifier) }
    }

    private func focus(_ entry: RunningPane) {
        NSApp.activate(ignoringOtherApps: true)
        entry.controller.window?.deminiaturize(nil)
        entry.controller.window?.makeKeyAndOrderFront(nil)
        entry.controller.hideSettings()
        entry.controller.reveal(pane: entry.pane)
    }

    // MARK: - 装配

    /// 装配所需的全部决定，已经算完、校验完。`build` 只照做，不会失败。
    private struct Assembly {
        enum Identity {
            case fresh
            /// 本次启动确立的会话（续接）。
            case attached(PaneSessionAssociation)
            /// 重启恢复：恢复意图（可能为 `.none`）加原来的终端名。
            case restored(PaneSessionState.Binding, name: String)
        }
        var configuration = TerminalSurfaceConfiguration()
        var identity = Identity.fresh
        var task: BoundTask?
    }

    private func resolve(_ request: TerminalLaunchRequest) throws -> Assembly {
        switch request.subject {
        case .shell(let command):
            return fresh(command.map(AgentCommand.shell) ?? .none, request: request)
        case .agent(let agent):
            return fresh(.start(agent), request: request)
        case .resume(let session, let source):
            return try resuming(session, source: source,
                                workingDirectory: request.workingDirectory ?? session.workingDirectory,
                                task: request.task)
        case .sessionPicker(let source):
            // Constant arguments only; no untrusted session text is inserted into the shell.
            let plan = try SessionPickerPlan(opening: source,
                                             workingDirectory: request.workingDirectory ?? NSHomeDirectory())
            var assembly = Assembly(task: request.task)
            assembly.configuration.workingDirectory = plan.context.workingDirectory
            assembly.configuration.command = .sessionPicker(plan)
            return assembly
        case .snapshot(let snapshot):
            return restoring(snapshot)
        }
    }

    /// 新终端生在给定目录；目录不在就不传，回退内核默认目录——不能让 spawn 失败。
    private func fresh(_ command: AgentCommand, request: TerminalLaunchRequest) -> Assembly {
        var assembly = Assembly(task: request.task)
        assembly.configuration.command = command
        if let directory = request.workingDirectory, Self.isDirectory(directory) {
            assembly.configuration.workingDirectory = directory
        }
        return assembly
    }

    private func resuming(_ session: AgentSession, source: SessionCatalogSource,
                          workingDirectory: String?, task: BoundTask?) throws -> Assembly {
        guard FileManager.default.isExecutableFile(atPath: source.executable),
              source.root.standardizedFileURL.path == session.key.sourceRoot else {
            throw SessionCatalogError.unavailable(L("This CLI session source is no longer available."))
        }
        let plan = try SessionResumePlan(resuming: session, executable: source.executable,
                                         configuration: source.configuration, workingDirectory: workingDirectory)
        var assembly = Assembly(task: task)
        assembly.configuration.workingDirectory = plan.context.workingDirectory
        assembly.configuration.command = .resume(plan)
        assembly.identity = .attached(.init(key: session.key, configuration: source.configuration,
                                            workingDirectory: plan.context.workingDirectory))
        return assembly
    }

    /// 按快照重建：shell 生在原目录；Agent 会话还活着就续接（此时 cwd 取 Agent 自报目录——
    /// 会话按项目目录归档，换目录找不到）；任务文件还在就重新绑定；名字原样回填。
    /// 恢复依赖（目录、CLI）缺失时保留意图但不启动 Agent，关联记为无法恢复。
    private func restoring(_ snapshot: PaneSnapshot) -> Assembly {
        var assembly = Assembly()
        let association = PaneSessionAssociation(snapshot: snapshot, home: FileManager.default.homeDirectoryForCurrentUser)
        if let directory = association?.workingDirectory ?? snapshot.workingDirectory, Self.isDirectory(directory) {
            assembly.configuration.workingDirectory = directory
        }
        var intent = PaneSessionState.Binding.none
        if let association {
            if Self.isDirectory(association.workingDirectory),
               let executable = locateExecutable(association.key.agent.rawValue),
               let plan = try? association.resumePlan(executable: executable) {
                assembly.configuration.command = .resume(plan)
                intent = .restoring(association)
            } else {
                intent = .unavailable(association)
            }
        }
        assembly.identity = .restored(intent, name: snapshot.name)
        if let path = snapshot.taskFile {
            let url = URL(fileURLWithPath: path)
            if let task = try? taskBindings.store.load(at: url) {
                assembly.task = BoundTask(fileURL: url, name: task.name)
            }
        }
        return assembly
    }

    /// 身份在装进窗口之前原子确立，任务绑定随后，二者互不影响。
    private func build(_ assembly: Assembly) -> PaneView {
        let pane = PaneView(surfaceConfiguration: assembly.configuration,
                            sessionLibrary: sessionLibrary, taskBindings: taskBindings)
        switch assembly.identity {
        case .fresh: break
        case .attached(let association): pane.associateSession(association)
        case .restored(let intent, let name): pane.restore(sessionIntent: intent, name: name)
        }
        if let task = assembly.task {
            taskBindings.bind(pane.dragIdentifier, to: task.fileURL, name: task.name)
        }
        return pane
    }

    // MARK: - 放置

    private func place(_ pane: PaneView, at destination: TerminalLaunchDestination,
                       in host: TerminalWindowController?) {
        switch destination {
        case .split: host?.addPaneToActiveTab(pane)
        case .tab: host?.addTab(initialPane: pane)
        case .window: openWindow(pane)
        }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
