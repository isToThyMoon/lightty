import AppKit
import LighttyCore

extension Notification.Name {
    /// 任务文件集合变化（创建/改名/绑定），已打开的侧边栏收到后 reload。
    static let lighttyTasksDidChange = Notification.Name("lighttyTasksDidChange")
}

/// pane 身份岛的 frame 规划：折叠胶囊与展开岛保持同一水平中点、同一顶边，
/// 因而展开只向左右等量延伸并向下生长。纯几何独立出来供回归测试锁住方向。
struct PaneIdentityMorphGeometry {
    static func panelFrame(around capsule: NSRect) -> NSRect {
        NSRect(
            x: capsule.midX - PaneIdentityPanel.panelWidth / 2,
            y: capsule.maxY - PaneIdentityPanel.maxHeight,
            width: PaneIdentityPanel.panelWidth,
            height: PaneIdentityPanel.maxHeight)
    }

    static func collapsedIslandFrame(capsule: NSRect, panelFrame: NSRect) -> NSRect {
        NSRect(
            x: capsule.minX - panelFrame.minX,
            y: capsule.minY - panelFrame.minY,
            width: capsule.width,
            height: capsule.height)
    }

    static func expandedIslandFrame(in panelBounds: NSRect, height: CGFloat) -> NSRect {
        NSRect(
            x: 0,
            y: panelBounds.height - height,
            width: PaneIdentityPanel.panelWidth,
            height: height)
    }
}

/// pane = 任务绑定点（HANDOVER 8.2）。header + 终端 surface。
/// 生命周期：新开 pane 不创建文件（未命名，内存态）；命名那一刻才经 TaskStore 落盘。
final class PaneView: NSView {
    /// Identity of a catalog launch; it is not a handoff task binding.
    var resumedSessionKey: AgentSessionKey?
    var resumedSessionConfiguration: SessionConfigurationLocation?
    /// 恢复出来的 pane 续接的 agent 会话身份。hook 只在**交互时**发状态：resume 后
    /// 用户若没继续聊，store 里就没有它的状态，`snapshot()` 会读到 nil、把它记成无
    /// agent，下次重启就丢了（实测 2026-09-07）。这三个字段让快照在实时状态缺席、
    /// 且 pane 进程仍活着时兜底续接身份；一旦 hook 发来实时状态，实时值优先。
    private var resumedAgent: String?
    private var resumedAgentSessionID: String?
    private var resumedAgentCWD: String?
    enum Binding {
        case unnamed                 // 灰点「未命名」
        case bound(fileURL: URL)     // 绿点，任务文件已存在
    }

    let header = PaneHeaderView()
    let terminal: TerminalSurfaceView
    let dragIdentifier: UUID
    private(set) var binding: Binding = .unnamed
    private var terminalSearchBar: TerminalSearchBar?
    private var searchSelected: Int?
    private var searchTotal: Int?
    private var dropOverlay: PaneDropOverlayView?

    /// pane 关闭请求（shell 退出，或 core 根据用户 Ghostty keybind 请求 close_surface）
    var onClose: ((PaneView) -> Void)?
    /// 标题或状态变化后，刷新窗口的衍生 metadata；标题栏不重复显示任务名。
    var onMetadataChange: ((PaneView) -> Void)?
    /// pane header 拖到目标四边时，由目标窗口控制器原位重组 split tree。
    var onMoveRequest: ((UUID, PaneView, PaneDropZone) -> Bool)?

    /// pane 名默认值的会话内计数器（编号比一排「未命名」可辨认）。
    private static var paneCounter = 0

    /// 会话恢复后把计数器抬到恢复出的默认名之上，新 pane 不与「终端 3」重名。
    static func seedDefaultNameCounter(from names: [String]) {
        let prefix = L("Terminal %d").replacingOccurrences(of: "%d", with: "")
        let numbers = names.compactMap { name -> Int? in
            guard name.hasPrefix(prefix) else { return nil }
            return Int(name.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces))
        }
        if let top = numbers.max() { paneCounter = max(paneCounter, top) }
    }

    init(surfaceConfiguration: TerminalSurfaceConfiguration = .init()) {
        let paneID = UUID()
        dragIdentifier = paneID
        // pane 身份下发给 shell：agent 的 hook 是 shell 的孙进程，环境变量沿进程树
        // 继承，hook 据此找到本 pane 的运行时目录（状态回写 + handoff 指针读取）。
        var configuration = surfaceConfiguration
        configuration.envVars["LIGHTTY_PANE_ID"] = paneID.uuidString
        // 状态走 datagram socket 推送，不落文件（状态是用完即弃的中间态）。
        // 路径按本实例 pid 命名，随 spawn 下发——多实例各收各的。
        configuration.envVars["LIGHTTY_SOCK"] = PaneRuntimeDirectory.socketPath().path
        terminal = TerminalSurfaceView(configuration: configuration)
        Self.paneCounter += 1
        super.init(frame: .zero)
        header.title = L("Terminal %d", Self.paneCounter)
        header.dot = .unnamed
        header.dragIdentifier = dragIdentifier
        header.onSelect = { [weak self] in self?.focusTerminal() }
        header.dragPreviewProvider = { [weak self] in self?.makeDragPreview() }
        registerForDraggedTypes([.lighttyPaneID])

        for v in [header, terminal] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminal.topAnchor.constraint(equalTo: header.bottomAnchor),
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // 调试标尺：可视化"窗口顶到第一行字"的每一段构成
        if ProcessInfo.processInfo.environment["LIGHTTY_DEBUG_LAYOUT"] != nil {
            let ruler = DebugRulerView(terminal: terminal)
            ruler.translatesAutoresizingMaskIntoConstraints = false
            addSubview(ruler)
            NSLayoutConstraint.activate([
                ruler.topAnchor.constraint(equalTo: topAnchor),
                ruler.bottomAnchor.constraint(equalTo: bottomAnchor),
                ruler.leadingAnchor.constraint(equalTo: leadingAnchor),
                ruler.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { ruler.needsDisplay = true }
        }

        header.onIdentityTapped = { [weak self] in self?.toggleIdentityPanel() }
        // ✕ 走内核关闭流程（与 cmd+W 同路），最终回到 close_surface_cb
        header.onCloseRequested = { [weak self] in self?.terminal.requestCloseFromUser() }
        terminal.onCloseRequest = { [weak self] in
            guard let self else { return }
            self.onClose?(self)
        }

        // 运行时目录 + 状态监听。放在 init 而不是各个关闭路径的对称位置，是因为
        // pane 的死法有好几种（✕、cmd+W、关 tab、关窗、shell 退出），deinit 是唯一
        // 能一网打尽的点；跨窗口拖动时 PaneView 本体存活，不会误触发。
        PaneStatusStore.shared.attach(paneID)
    }

    deinit {
        let paneID = dragIdentifier
        // deinit 不保证在主线程；store 是主线程独占的
        if Thread.isMainThread {
            PaneStatusStore.shared.detach(paneID)
        } else {
            DispatchQueue.main.async { PaneStatusStore.shared.detach(paneID) }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 绑定任务：只改 pane 指向与 pill 显示，不动 pane 名（pane 名是独立会话态标签）。
    func bind(to fileURL: URL, name: String) {
        binding = .bound(fileURL: fileURL)
        header.setTaskName(name)
        header.dot = .active
        syncTaskPointer()
        refreshIdentityPanel()
        onMetadataChange?(self)
        NotificationCenter.default.post(name: .lighttyTasksDidChange, object: nil)
    }

    /// 解除绑定：pane 回到无任务状态，pane 名保持不变。
    func unbind() {
        binding = .unnamed
        header.setTaskName(nil)
        header.dot = .unnamed
        syncTaskPointer()
        refreshIdentityPanel()
        onMetadataChange?(self)
        NotificationCenter.default.post(name: .lighttyTasksDidChange, object: nil)
    }

    /// 任务被（本 pane 或他处）重命名后的同步：更新指向与 pill，不发通知
    /// （由发起方统一广播）。
    func noteTaskRenamed(to newURL: URL, name: String) {
        guard case .bound = binding else { return }
        binding = .bound(fileURL: newURL)
        header.setTaskName(name)
        syncTaskPointer()
        refreshIdentityPanel()
    }

    /// 把当前绑定的任务文件路径写进 pane 运行时目录，供 agent hook 读取并注入上下文
    /// （docs/specs/pane-status.md §8）。hook 在 SessionStart 与 UserPromptSubmit 都会查，
    /// 所以先开 agent 再绑/新建/改名也能拿到。解绑时删掉指针，连同 hook 的去重标记：
    /// 否则同一会话里解绑再绑回同一任务，hook 会以为已经注过而跳过。
    ///
    /// 改名走 TaskStore 的移动语义，路径会变——所以 bind/unbind/rename 三处都要同步，
    /// 否则 hook 会读到一个已经不存在的路径。
    private func syncTaskPointer() {
        let paneID = dragIdentifier.uuidString
        let pointer = PaneRuntimeDirectory.taskPointerFile(for: paneID)
        guard let url = taskFileURL else {
            try? FileManager.default.removeItem(at: pointer)
            try? FileManager.default.removeItem(at: PaneRuntimeDirectory.handoffMarkerFile(for: paneID))
            return
        }
        try? PaneRuntimeDirectory.create(paneID: paneID)
        try? PaneRuntimeDirectory.atomicWrite(Data((url.path + "\n").utf8), to: pointer)
    }

    var taskFileURL: URL? {
        if case .bound(let url) = binding { return url }
        return nil
    }

    /// 建档写入的 `cwd` = 任务创建现场。首选 shell 的 OSC PWD：agent 全屏期间
    /// 它「停」在最后一次提示符的目录——正是用户敲 `claude` 的地方，即 agent
    /// 继承的出生目录，不是过期数据。刻意不优先 agent 上报的 cwd：那个值是
    /// agent 自己填的，探查/在别的目录跑命令时可能跟着漂，会记下瞬时的错误
    /// 目录；它只做 shell 没发 OSC 7（未配 shell-integration）时的兜底。
    /// 只有「新建任务」走这里：绑定已有任务不覆盖其 cwd（你可能在 home 的
    /// 临时 pane 里绑一个项目任务），改名/解绑/agent 写回也都不碰它。
    private func taskCreationWorkingDirectory() -> String {
        if let shellCWD = terminal.currentWorkingDirectory, !shellCWD.isEmpty {
            return shellCWD
        }
        if let agentCWD = PaneStatusStore.shared.status(for: dragIdentifier)?.cwd,
            !agentCWD.isEmpty {
            return agentCWD
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// 恢复任务用的 pane 工厂：新 shell 直接生在任务的 `cwd`（创建现场），
    /// agent 起来就在项目里，退出 agent 后 shell 也还在。目录已不存在则不传，
    /// 回退内核默认目录——不能让 spawn 失败。气泡三目的地与 ⇧⇧ 搜索共用。
    static func restoring(task: TaskFile, fileURL: URL, initialInput: String? = nil) -> PaneView {
        var configuration = TerminalSurfaceConfiguration()
        configuration.initialInput = initialInput
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: task.workdir, isDirectory: &isDirectory),
            isDirectory.boolValue {
            configuration.workingDirectory = task.workdir
        }
        let pane = PaneView(surfaceConfiguration: configuration)
        pane.bind(to: fileURL, name: task.name)
        return pane
    }

    // MARK: - 会话快照（重启恢复）

    /// 本 pane 的快照：名字、shell cwd、任务绑定、agent 会话（来自 hook 最后一发状态）。
    func snapshot() -> PaneSnapshot {
        let status = PaneStatusStore.shared.status(for: dragIdentifier)
        let identity = Self.resolveAgentIdentity(
            status: status, processExited: terminal.processExited,
            resumedAgent: resumedAgent, resumedSessionID: resumedAgentSessionID,
            resumedAgentCWD: resumedAgentCWD)
        let confirmed = resumedSessionKey.map {
            SessionResumeFlow.activity(for: $0, status: status, processExited: terminal.processExited) == .confirmed
        } ?? false
        return PaneSnapshot(
            name: header.title,
            workingDirectory: terminal.currentWorkingDirectory,
            taskFile: taskFileURL?.path,
            agent: identity.agent,
            sessionID: identity.sessionID,
            agentCWD: identity.agentCWD,
            agentAlive: identity.alive,
            catalogSession: confirmed ? resumedSessionKey : nil,
            catalogConfiguration: confirmed ? resumedSessionConfiguration : nil)
    }

    /// 决定写进快照的 agent 会话身份。纯函数便于测试。
    ///
    /// - 实时状态在场 → 一律以实时为准（含 SessionEnd：`alive=false`，不再续接）。
    /// - 实时状态缺席、进程仍活着、且有恢复时记下的续接身份 → 用它兜底
    ///   （resume 后用户没继续聊、hook 从没发状态的情形）。
    /// - 进程已退出且无实时状态 → 不带 agent，避免续接一个已结束的会话。
    static func resolveAgentIdentity(
        status: PaneStatus?, processExited: Bool,
        resumedAgent: String?, resumedSessionID: String?, resumedAgentCWD: String?
    ) -> (agent: String?, sessionID: String?, agentCWD: String?, alive: Bool) {
        if let status {
            // 收到 SessionEnd = 用户退出了 agent；其余任何事件（含旧 hook 不带 event）都视为会话还在。
            return (status.agent, status.sessionID, status.cwd, status.event != "SessionEnd")
        }
        let useFallback = !processExited && resumedAgent != nil
        guard useFallback else { return (nil, nil, nil, false) }
        return (resumedAgent, resumedSessionID, resumedAgentCWD, true)
    }

    /// 按快照重建 pane：shell 生在原目录；agent 会话还活着就把 `--resume` 作为首段
    /// 输入敲进去（此时 cwd 取 agent 自报目录——会话按项目目录归档，换目录找不到）；
    /// 任务文件还在就重新绑定；名字原样回填。目录/文件已不存在则各自退回默认。
    static func restored(from snapshot: PaneSnapshot) -> PaneView {
        var configuration = TerminalSurfaceConfiguration()
        let resume = AgentResume.command(
            agent: snapshot.agent, sessionID: snapshot.sessionID, alive: snapshot.agentAlive)
        let preferred = (resume != nil ? snapshot.agentCWD : nil) ?? snapshot.workingDirectory
        if let directory = preferred, Self.isDirectory(directory) {
            configuration.workingDirectory = directory
        }
        configuration.initialInput = resume
        // A catalog session must never fall back to the default CLI data root.
        if snapshot.catalogSession != nil { configuration.initialInput = nil }
        var restoredCatalogKey: AgentSessionKey?
        if resume != nil, let key = snapshot.catalogSession,
           let location = snapshot.catalogConfiguration,
           let cwd = preferred, Self.isDirectory(cwd),
           let executable = HookInstaller.locateExecutable(key.agent.rawValue) {
            let record = AgentSession(key: key, title: "", workingDirectory: cwd, updatedAt: nil)
            if let plan = try? SessionResumePlan(session: record, executable: executable, configuration: location) {
                configuration.initialInput = plan.shellInput
                restoredCatalogKey = key
            } else {
                configuration.initialInput = nil
            }
        }
        let pane = PaneView(surfaceConfiguration: configuration)
        pane.resumedSessionKey = restoredCatalogKey
        pane.resumedSessionConfiguration = restoredCatalogKey == nil ? nil : snapshot.catalogConfiguration
        // 续接身份：resume 命令已生成 → 记住它续接的会话，供 snapshot() 在 hook 尚未
        // 发来实时状态（用户没继续聊）时兜底，避免下次重启丢会话。
        if resume != nil {
            pane.resumedAgent = snapshot.agent
            pane.resumedAgentSessionID = snapshot.sessionID
            pane.resumedAgentCWD = snapshot.agentCWD ?? snapshot.workingDirectory
        }
        pane.header.title = snapshot.name
        if let path = snapshot.taskFile {
            let url = URL(fileURLWithPath: path)
            if let task = try? AppState.shared?.taskStore.load(at: url) {
                pane.bind(to: url, name: task.name)
            }
        }
        return pane
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    // MARK: - 身份面板（灵动岛式展开）

    private var identityPanel: PaneIdentityPanel?
    private var panelDismissMonitor: Any?

    /// pane 离窗（拖拽重组/关闭）时面板必须跟着收，否则悬浮在 contentView 上成孤儿。
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if identityPanel != nil { dismissIdentityPanel() }
    }

    private func toggleIdentityPanel() {
        if identityPanel != nil {
            dismissIdentityPanel()
        } else {
            showIdentityPanel()
        }
    }

    /// 形变展开（灵动岛式）：面板从胶囊 frame 生长到展开尺寸，内容渐显；
    /// 收起反向缩回。frame 驱动动画，不用 Auto Layout 钉面板位置。
    /// 岛体在面板内的 rect：顶边恒对齐面板顶边，高度 h（非翻转坐标）。
    private func islandRect(in panel: PaneIdentityPanel, height: CGFloat) -> NSRect {
        PaneIdentityMorphGeometry.expandedIslandFrame(in: panel.bounds, height: height)
    }

    private func showIdentityPanel() {
        let panel = PaneIdentityPanel()
        panel.onPaneNameCommit = { [weak self] name in self?.rename(to: name) }
        panel.taskProvider = { [weak self] in
            let running = AppState.shared.runningPanes()
            let current = self?.taskFileURL?.standardizedFileURL
            return AppState.shared.taskStore.list().tasks
                .sorted { $0.task.updated > $1.task.updated }
                .map { entry in
                    PaneIdentityPanel.TaskChoice(
                        name: entry.task.name,
                        fileURL: entry.fileURL,
                        running: running.contains {
                            $0.pane !== self && $0.pane.taskFileURL?.standardizedFileURL
                                == entry.fileURL.standardizedFileURL
                        },
                        current: current == entry.fileURL.standardizedFileURL)
                }
        }
        panel.onBindTask = { [weak self] url in
            guard let entry = AppState.shared.taskStore.list().tasks.first(where: {
                $0.fileURL.standardizedFileURL == url.standardizedFileURL
            }) else { return }
            self?.bind(to: entry.fileURL, name: entry.task.name)
        }
        panel.onCreateTask = { [weak self] name in
            guard let self else { return }
            do {
                let created = try AppState.shared.taskStore.create(
                    name: name,
                    workdir: self.taskCreationWorkingDirectory(),
                    tool: nil)
                self.bind(to: created.fileURL, name: name)
            } catch {
                NSSound.beep()
                NSLog("task create failed: \(error)")
            }
        }
        panel.onUnbindTask = { [weak self] in self?.unbind() }
        panel.onTaskRenameCommit = { [weak self] name in
            guard let self, case .bound(let url) = self.binding else { return }
            do {
                _ = try AppState.shared.renameTask(at: url, to: name)
                self.refreshIdentityPanel()
            } catch {
                NSSound.beep()
                NSLog("task rename failed: \(error)")
            }
        }
        panel.onDismiss = { [weak self] in
            self?.dismissIdentityPanel()
            self?.focusTerminal()
        }
        panel.onIslandHeightChange = { [weak self, weak panel] height in
            guard let self, let panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                panel.island.animator().frame = self.islandRect(in: panel, height: height)
            }
        }
        panel.applyTerminalTheme(
            background: GhosttyRuntime.shared.configValues.backgroundColor,
            foreground: header.terminalForeground)
        refresh(panel: panel)

        // 面板挂到窗口 contentView（所有 split 之上）：挂在 pane 里会被
        // clipsToBounds 和相邻 pane 的更高兄弟层级裁剪/遮盖。
        // 面板高度取上限（岛体在其中生长），本体静止、永不动画。
        guard let host = window?.contentView else { return }
        let start = host.convert(header.capsuleFrame, from: header)
        panel.frame = PaneIdentityMorphGeometry.panelFrame(around: start)
        let collapsedFrame = PaneIdentityMorphGeometry.collapsedIslandFrame(
            capsule: start, panelFrame: panel.frame)
        // 第一行不参与淡入且始终停在胶囊原位；所有扩展内容统一渐显。
        panel.setExpandedContentAlpha(0, animated: false)
        panel.setIdentityAnchorOffset(collapsedFrame.minX)
        panel.island.frame = collapsedFrame
        host.addSubview(panel)
        identityPanel = panel
        panel.layoutSubtreeIfNeeded()
        header.setCapsuleHidden(true) // 瞬时交接：面板第一行与胶囊逐像素同构

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            panel.island.animator().frame = islandRect(
                in: panel, height: PaneIdentityPanel.baseHeight)
            panel.setExpandedContentAlpha(1, animated: true)
        } completionHandler: { [weak panel] in
            panel?.focusNameField()
        }

        // 点击岛体与胶囊之外任意处收起（判定用岛体实际 frame，面板是透明容器）
        panelDismissMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.identityPanel,
                  event.window === self.window else { return event }
            let inIsland = panel.island.frame.contains(
                panel.convert(event.locationInWindow, from: nil))
            let inHeader = self.header.bounds.contains(
                self.header.convert(event.locationInWindow, from: nil))
            if !inIsland && !inHeader {
                self.dismissIdentityPanel()
            }
            return event
        }
    }

    private func dismissIdentityPanel() {
        guard let panel = identityPanel else { return }
        if let panelDismissMonitor { NSEvent.removeMonitor(panelDismissMonitor) }
        panelDismissMonitor = nil
        identityPanel = nil

        let end = (panel.superview ?? self).convert(header.capsuleFrame, from: header)
        let islandEnd = PaneIdentityMorphGeometry.collapsedIslandFrame(
            capsule: end, panelFrame: panel.frame)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            context.allowsImplicitAnimation = true
            // 岛体缩回中心；第一行通常原地不动，仅在 header 曾移动时跟到新锚点。
            panel.island.animator().frame = islandEnd
            panel.setIdentityAnchorOffset(islandEnd.minX)
            panel.animator().layoutSubtreeIfNeeded()
            panel.setExpandedContentAlpha(0, animated: true)
        } completionHandler: { [weak self, weak panel] in
            // 缩回到位后瞬时交接回胶囊（第一行同构，标题不闪）
            self?.header.setCapsuleHidden(false)
            panel?.removeFromSuperview()
        }
    }

    /// 绑定/改名等状态变化后同步面板显示（若展开中）。
    private func refreshIdentityPanel() {
        guard let panel = identityPanel else { return }
        refresh(panel: panel)
    }

    private func refresh(panel: PaneIdentityPanel) {
        panel.update(
            paneName: header.title,
            taskName: header.titleOfBoundTask,
            dot: header.dot.color)
    }



    // MARK: - pane 名（会话态标签，不落盘）

    private func rename(to name: String) {
        header.title = name
        onMetadataChange?(self)
        // 标签页列的 pane 行显示 pane 名，改名后需要活地图刷新
        NotificationCenter.default.post(name: .lighttyTasksDidChange, object: nil)
    }

    func focusTerminal() {
        window?.makeFirstResponder(terminal)
    }

    // MARK: - 跳转落点提示

    private var spotlightVeil: NSView?

    /// 从侧栏/菜单栏/搜索等处跳转到本 pane 后的落点提示。
    /// 不给目标加图形（圈线在终端画面里是异物），而是请控制器把同标签页
    /// 其余 pane 短暂压暗——视线本能落在唯一清晰的那块上。做减法的聚光灯，
    /// 与内核的 unfocused-split-opacity 同一门语言。
    func flashReveal() {
        (window?.windowController as? TerminalWindowController)?.spotlight(on: self)
    }

    /// 聚光灯的「暗」侧：盖一层终端背景色纱再淡出。用背景色而非黑色，
    /// 是把内容往各自底色方向压对比，明暗主题都成立（黑纱在浅色主题发脏）；
    /// 取本 pane 的实况背景（header 跟踪的 per-surface 值）而非全局 config，
    /// 明暗切换后、各 pane 主题不同时都各自取对。
    func dimForSpotlight() {
        spotlightVeil?.removeFromSuperview()
        let veil = ShellPassthroughView(frame: bounds)
        veil.autoresizingMask = [.width, .height]
        veil.wantsLayer = true
        veil.layer?.backgroundColor = header.terminalBackground
            .withAlphaComponent(0.6).cgColor
        addSubview(veil, positioned: .above, relativeTo: nil)
        spotlightVeil = veil
        // 纱先停住给视线定位，再收走；直接一条 ease 曲线会淡得太早，
        // 显式分成「停留 → 淡出」两拍。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self, weak veil] in
            guard let veil, veil.superview != nil else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.45
                context.timingFunction = ShellStyle.easeInOutCubic
                veil.animator().alphaValue = 0
            }, completionHandler: { [weak self, weak veil] in
                veil?.removeFromSuperview()
                if self?.spotlightVeil === veil { self?.spotlightVeil = nil }
            })
        }
    }

    // MARK: - Ghostty terminal search host

    func startTerminalSearch(needle: String?) {
        if let terminalSearchBar {
            if let needle, !needle.isEmpty {
                terminalSearchBar.setNeedle(needle)
            } else {
                terminalSearchBar.focus()
            }
            return
        }

        let bar = TerminalSearchBar(needle: needle)
        bar.terminal = terminal
        bar.onNeedleChange = { [weak terminal] needle in
            terminal?.performBindingAction("search:\(needle)")
        }
        bar.onNext = { [weak terminal] in
            terminal?.performBindingAction("navigate_search:next")
        }
        bar.onPrevious = { [weak terminal] in
            terminal?.performBindingAction("navigate_search:previous")
        }
        bar.onClose = { [weak self] in self?.endTerminalSearch(requestCore: true) }
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: terminal.topAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
        terminalSearchBar = bar
        bar.update(selected: searchSelected, total: searchTotal)
        DispatchQueue.main.async { [weak bar] in bar?.focus() }
    }

    func endTerminalSearch(requestCore: Bool) {
        guard let bar = terminalSearchBar else {
            if requestCore { terminal.performBindingAction("end_search") }
            return
        }
        terminalSearchBar = nil
        bar.removeFromSuperview()
        if requestCore { terminal.performBindingAction("end_search") }
        focusTerminal()
    }

    func updateTerminalSearchSelected(_ selected: Int?) {
        searchSelected = selected
        terminalSearchBar?.update(selected: searchSelected, total: searchTotal)
    }

    func updateTerminalSearchTotal(_ total: Int?) {
        searchTotal = total
        terminalSearchBar?.update(selected: searchSelected, total: searchTotal)
    }

    // MARK: - Ghostty-style pane drag/drop

    private func draggedPaneID(from sender: NSDraggingInfo) -> UUID? {
        guard let raw = sender.draggingPasteboard.string(forType: .lighttyPaneID) else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropOverlay(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropOverlay(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideDropOverlay()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let sourceID = draggedPaneID(from: sender) else { return false }
        return sourceID != dragIdentifier
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { hideDropOverlay() }
        guard let sourceID = draggedPaneID(from: sender), sourceID != dragIdentifier else {
            return false
        }
        let point = convert(sender.draggingLocation, from: nil)
        let zone = PaneDropZone.calculate(at: point, in: bounds)
        return onMoveRequest?(sourceID, self, zone) ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        hideDropOverlay()
    }

    private func updateDropOverlay(for sender: NSDraggingInfo) -> NSDragOperation {
        guard let sourceID = draggedPaneID(from: sender), sourceID != dragIdentifier else {
            hideDropOverlay()
            return []
        }
        let point = convert(sender.draggingLocation, from: nil)
        let zone = PaneDropZone.calculate(at: point, in: bounds)
        let overlay = dropOverlay ?? PaneDropOverlayView(frame: .zero)
        overlay.frame = zone.frame(in: bounds)
        overlay.autoresizingMask = []
        if overlay.superview == nil {
            addSubview(overlay, positioned: .above, relativeTo: nil)
        }
        dropOverlay = overlay
        return .move
    }

    private func hideDropOverlay() {
        dropOverlay?.removeFromSuperview()
        dropOverlay = nil
    }

    func clearDropPreview() {
        hideDropOverlay()
    }

    /// 与 vendor SurfaceDragSource 一样使用缩小的 pane snapshot；若 IOSurface 暂时
    /// 无法缓存，header 会自动退回到带标题的轻量 preview。
    private func makeDragPreview() -> NSImage? {
        guard bounds.width > 0, bounds.height > 0,
              let representation = bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        cacheDisplay(in: bounds, to: representation)
        let source = NSImage(size: bounds.size)
        source.addRepresentation(representation)

        let scale = min(0.2, 180 / bounds.width)
        let size = NSSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale))
        let preview = NSImage(size: size)
        preview.lockFocus()
        source.draw(
            in: NSRect(origin: .zero, size: size),
            from: bounds,
            operation: .copy,
            fraction: 0.9)
        preview.unlockFocus()
        return preview
    }
}
