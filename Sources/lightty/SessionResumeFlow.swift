import AppKit
import LighttyCore

enum TerminalLaunchDestination { case split, tab, window }

enum SessionResumeFlow {
    // Main-thread request coalescing, not an Agent lock. Released after each bounded check.
    private static var checking = Set<AgentSessionKey>()
    static func isStarting(_ key: AgentSessionKey) -> Bool { checking.contains(key) }
    static func startNew(agent: LaunchAgent, in controller: TerminalWindowController) {
        guard agent != .terminal else { return }
        guard !SessionDeletion.busyAgents.contains(agent == .codex ? .codex : .claude) else { return }
        let configuration = newSessionConfiguration(agent: agent,
            workingDirectory: controller.activePane?.terminal.currentWorkingDirectory)
        controller.addTab(initialPane: PaneView(surfaceConfiguration: configuration))
    }

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
        if let existing = AppState.shared.runningPanes().first(where: {
            $0.pane.displayedSessionKey == session.key
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
        var isDirectory: ObjCBool = false
        if cwd == nil || !FileManager.default.fileExists(atPath: cwd ?? "", isDirectory: &isDirectory) || !isDirectory.boolValue {
            let picker = NSOpenPanel()
            picker.message = L("The original session folder is missing. Choose a folder to continue.")
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
                let occupancy = SessionOccupancy.check(session.key)
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
                    let pane = PaneView(surfaceConfiguration: configuration)
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
