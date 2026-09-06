import AppKit
import LighttyCore

enum TerminalLaunchDestination { case split, tab, window }

enum SessionResumeFlow {
    // Main-thread request coalescing, not an Agent lock. Released after each bounded check.
    private static var checking = Set<AgentSessionKey>()
    static func isStarting(_ key: AgentSessionKey) -> Bool { checking.contains(key) }
    /// 新会话的第一行命令与落脚目录。目录由启动浮层给定；给 nil 只在没有更好答案时
    /// 才发生，那时落在家目录。
    static func newSessionConfiguration(agent: LaunchAgent, workingDirectory: String?) -> TerminalSurfaceConfiguration {
        var configuration = TerminalSurfaceConfiguration()
        configuration.workingDirectory = workingDirectory ?? NSHomeDirectory()
        configuration.command = .start(agent)
        return configuration
    }

    static func open(_ session: AgentSession, source: SessionCatalogSource,
                     in controller: TerminalWindowController, destination: TerminalLaunchDestination = .tab) {
        guard !SessionDeletion.busyAgents.contains(session.key.agent) else { return }
        for entry in AppState.shared.runningPanes() { entry.pane.reconcileSessionProcess() }
        let paneIDs = controller.sessionLibrary.openPaneIDs(for: session.key)
        if let existing = AppState.shared.runningPanes().first(where: {
            paneIDs.contains($0.pane.dragIdentifier)
        }) {
            // Internal navigation does not require a hook-confirmed resume or another Agent process.
            NSApp.activate(ignoringOtherApps: true)
            existing.controller.window?.deminiaturize(nil)
            existing.controller.window?.makeKeyAndOrderFront(nil)
            existing.controller.hideSettings()
            existing.controller.reveal(pane: existing.pane)
            return
        }
        guard !checking.contains(session.key) else { return }
        var cwd = session.workingDirectory
        if let message = folderPromptMessage(for: cwd) {
            let picker = NSOpenPanel()
            picker.message = message
            picker.canChooseFiles = false
            picker.canChooseDirectories = true
            guard picker.runModal() == .OK else { return }
            cwd = picker.url?.path
        }
        do {
            guard FileManager.default.isExecutableFile(atPath: source.executable),
                  source.root.standardizedFileURL.path == session.key.sourceRoot else {
                throw SessionCatalogError.unavailable(L("This CLI session source is no longer available."))
            }
            let plan = try SessionResumePlan(resuming: session, executable: source.executable,
                                             configuration: source.configuration, workingDirectory: cwd)
            guard checking.insert(session.key).inserted else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let occupancy = SessionOccupancy.check(session.key, executable: source.executable)
                DispatchQueue.main.async { [weak controller] in
                    checking.remove(session.key)
                    guard let controller, let window = controller.window, window.isVisible else { return }
                    if case .inUse(let pid) = occupancy {
                        let alert = AppBranding.makeAlert()
                        alert.messageText = L("This session is already open in another terminal.")
                        alert.informativeText = L("Continue in the original terminal, or exit the Agent there before resuming here. lightty will not stop it or remove its lock.") + "\nPID: \(pid)"
                        alert.beginSheetModal(for: window)
                        return
                    }
                    // Absence of evidence is not a lock guarantee. The native CLI remains authoritative.
                    var configuration = TerminalSurfaceConfiguration()
                    configuration.workingDirectory = plan.workingDirectory
                    configuration.command = .resume(plan)
                    let pane = PaneView(surfaceConfiguration: configuration, sessionLibrary: controller.sessionLibrary)
                    pane.associateSession(.init(key: session.key, configuration: source.configuration,
                                                workingDirectory: plan.workingDirectory))
                    switch destination {
                    case .split: controller.addPaneToActiveTab(pane)
                    case .tab: controller.addTab(initialPane: pane)
                    case .window: AppState.shared.newWindow(initialPane: pane)
                    }
                }
            }
        } catch { showError(error, in: controller.window) }
    }

    /// 恢复之前要不要让用户挑目录，以及挑之前该跟他说什么。返回 nil 表示直接能用。
    ///
    /// 两件不同的事说法也得不同：目录记下来了但现在不在，和**压根就没读出目录**。
    /// 后者说成「原会话目录不存在」是替用户下了一个我们并不知道的结论——目录多半
    /// 还好端端在那儿，只是这段会话的工作目录我们没拿到。
    ///
    /// 抽成函数是因为 `open` 里紧接着就是模态框，那一段测不了。
    static func folderPromptMessage(for path: String?) -> String? {
        guard let path else {
            return L("This session has no recorded folder. Choose a folder to continue.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return L("The original session folder is missing. Choose a folder to continue.")
        }
        return nil
    }

    static func nativePicker(source: SessionCatalogSource, in controller: TerminalWindowController) {
        guard !SessionDeletion.busyAgents.contains(source.agent) else { return }
        // Constant arguments only; no untrusted session text is inserted into the shell.
        let placeholder = AgentSession(key: .init(agent: source.agent, sourceRoot: source.root.path, nativeID: "placeholder"),
                                       title: "", workingDirectory: NSHomeDirectory(), updatedAt: nil)
        do {
            let plan = try SessionResumePlan(resuming: placeholder, executable: source.executable,
                                             configuration: source.configuration)
            var configuration = TerminalSurfaceConfiguration()
            configuration.workingDirectory = plan.workingDirectory
            configuration.command = .sessionPicker(plan)
            controller.addTab(initialPane: PaneView(surfaceConfiguration: configuration))
        } catch { showError(error, in: controller.window) }
    }

    private static func showError(_ error: Error, in window: NSWindow?) {
        let alert = AppBranding.makeAlert()
        alert.messageText = L("Could not resume this session.")
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? L("Check the CLI and session folder, then try again.")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
