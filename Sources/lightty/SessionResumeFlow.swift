import AppKit
import LighttyCore

enum TerminalLaunchDestination { case split, tab, window }

enum SessionResumeFlow {
    // Main-thread request coalescing, not an Agent lock. Released after each bounded check.
    private static var checking = Set<AgentSessionKey>()
    enum Activity: Equatable { case confirmed, unconfirmed, ended }

    static func activity(for key: AgentSessionKey, status: PaneStatus?, processExited: Bool) -> Activity {
        guard !processExited else { return .ended }
        guard let status else { return .unconfirmed }
        guard status.agent == key.agent.rawValue, status.sessionID == key.nativeID else { return .ended }
        return status.event == "SessionEnd" ? .ended : .confirmed
    }

    static func startNew(agent: LaunchAgent, in controller: TerminalWindowController) {
        guard agent != .terminal else { return }
        let configuration = newSessionConfiguration(agent: agent,
            workingDirectory: controller.activePane?.terminal.currentWorkingDirectory)
        controller.addTab(initialPane: PaneView(surfaceConfiguration: configuration))
    }

    static func newSessionConfiguration(agent: LaunchAgent, workingDirectory: String?) -> TerminalSurfaceConfiguration {
        var configuration = TerminalSurfaceConfiguration()
        configuration.workingDirectory = workingDirectory ?? NSHomeDirectory()
        configuration.initialInput = AgentLaunchPreference.initialInput(for: agent)
        return configuration
    }

    static func open(_ session: AgentSession, source: SessionCatalogSource,
                     in controller: TerminalWindowController, destination: TerminalLaunchDestination = .tab,
                     preferExisting: Bool = true) {
        guard !checking.contains(session.key) else { return }
        if let existing = AppState.shared.runningPanes().first(where: {
            let pane = $0.pane
            guard pane.resumedSessionKey == session.key,
                  pane.resumedSessionConfiguration == source.configuration else { return false }
            return activity(for: session.key, status: PaneStatusStore.shared.status(for: pane.dragIdentifier),
                            processExited: pane.terminal.processExited) != .ended
        }) {
            let state = activity(for: session.key,
                                 status: PaneStatusStore.shared.status(for: existing.pane.dragIdentifier),
                                 processExited: existing.pane.terminal.processExited)
            if state == .unconfirmed {
                let alert = NSAlert()
                alert.messageText = L("Session resume is not confirmed.")
                alert.informativeText = L("Check the previous terminal before retrying. The Agent may still be starting, or may have reported an error. Retrying does not stop the previous process.")
                alert.addButton(withTitle: L("Show terminal"))
                alert.addButton(withTitle: L("Retry in a new terminal"))
                alert.addButton(withTitle: L("Cancel"))
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    existing.controller.window?.makeKeyAndOrderFront(nil)
                    existing.controller.reveal(pane: existing.pane)
                    return
                case .alertSecondButtonReturn: break
                default: return
                }
            } else if preferExisting || session.key.agent == .codex {
                // Codex requires one writer; an explicit destination is not permission to steal it.
                existing.controller.window?.makeKeyAndOrderFront(nil)
                existing.controller.reveal(pane: existing.pane)
                return
            }
        }
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
            let plan = try SessionResumePlan(session: session, executable: source.executable,
                                            configuration: source.configuration, workingDirectory: cwd)
            guard checking.insert(session.key).inserted else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let occupancy = SessionOccupancy.check(session.key)
                DispatchQueue.main.async { [weak controller] in
                    checking.remove(session.key)
                    guard let controller, let window = controller.window, window.isVisible else { return }
                    if case .inUse(let pid) = occupancy {
                        let alert = NSAlert()
                        alert.messageText = L("This session is already open in another terminal.")
                        alert.informativeText = L("Continue in the original terminal, or exit the Agent there before resuming here. lightty will not stop it or remove its lock.") + "\nPID: \(pid)"
                        alert.beginSheetModal(for: window)
                        return
                    }
                    // Absence of evidence is not a lock guarantee. The native CLI remains authoritative.
                    var configuration = TerminalSurfaceConfiguration()
                    configuration.workingDirectory = plan.workingDirectory
                    configuration.initialInput = plan.shellInput
                    let pane = PaneView(surfaceConfiguration: configuration)
                    pane.resumedSessionKey = session.key
                    pane.resumedSessionConfiguration = source.configuration
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
        // Constant arguments only; no untrusted session text is inserted into the shell.
        let placeholder = AgentSession(key: .init(agent: source.agent, sourceRoot: source.root.path, nativeID: "placeholder"),
                                       title: "", workingDirectory: NSHomeDirectory(), updatedAt: nil)
        do {
            let plan = try SessionResumePlan(session: placeholder, executable: source.executable,
                                            configuration: source.configuration)
            var configuration = TerminalSurfaceConfiguration()
            configuration.workingDirectory = plan.workingDirectory
            configuration.initialInput = plan.nativePickerInput
            controller.addTab(initialPane: PaneView(surfaceConfiguration: configuration))
        } catch { showError(error, in: controller.window) }
    }

    private static func showError(_ error: Error, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = L("Could not resume this session.")
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? L("Check the CLI and session folder, then try again.")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
