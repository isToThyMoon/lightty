import AppKit
import LighttyCore

/// Provider-owned permanent deletion. No transcript paths or database schemas live here.
///
/// 这里只有确认界面、应用内占用复核；原生删除、外部占用与各家特有的进程核查都在
/// `AgentSessionProvider` 里。删除期间的互斥由 `PaneLauncher` 持有：确认框开着时，
/// 同家的续接与原生选择器由它拦下（它们可能碰到正被删的会话）；新会话写的是另一段会话，放行。
enum SessionDeletion {
    private static var launcher: PaneLauncher { AppState.shared.paneLauncher }

    static func confirm(_ session: AgentSession, library: SessionLibrary, window: NSWindow) {
        guard !launcher.isDeleting(session.key.agent), !library.saving,
              library.organizationReady, library.storageError == nil,
              let provider = library.provider(for: session.key.agent) else { return }
        for entry in AppState.shared.runningPanes() { entry.pane.reconcileSessionProcess() }
        guard library.openPaneIDs(for: session.key).isEmpty, !launcher.isStarting(session.key) else {
            show(Failure.occupied.localizedDescription, window: window)
            return
        }
        launcher.beginDeleting(session.key.agent)
        let alert = SessionDeletionConfirmation()
        alert.messageText = L("Permanently delete this session?")
        alert.informativeText = session.title + "\n\n" + L("Includes child conversations. This cannot be undone.")
        alert.addButton(withTitle: L("Cancel"))
        alert.addButton(withTitle: L("Permanently delete"))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertSecondButtonReturn else {
                launcher.endDeleting(session.key.agent); return
            }
            perform(session, provider: provider, library: library, window: window)
        }
    }

    private static func perform(_ session: AgentSession, provider: AgentSessionProvider,
                                library: SessionLibrary, window: NSWindow,
                                acceptingUnknownOccupancy: Bool = false) {
            // Recheck after either confirmation; consent never overrides a known active session.
            for entry in AppState.shared.runningPanes() { entry.pane.reconcileSessionProcess() }
            guard library.openPaneIDs(for: session.key).isEmpty,
                  !launcher.isStarting(session.key) else {
                launcher.endDeleting(session.key.agent)
                show(Failure.occupied.localizedDescription, window: window)
                return
            }
            var known: [AgentProcessIdentity: AgentSessionKey] = [:]
            for entry in AppState.shared.runningPanes() {
                entry.pane.reconcileSessionProcess()
                if let key = entry.pane.displayedSessionKey,
                   let identity = entry.pane.sessionProcessIdentity {
                    known[identity] = key
                }
            }
            let associations = known
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try delete(session.key, provider: provider,
                    acceptingUnknownOccupancy: acceptingUnknownOccupancy, known: associations) }
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        launcher.endDeleting(session.key.agent)
                        library.didDelete(session.key)
                    case .failure(Failure.unknownOccupancy(let pid)):
                        let alert = unknownOccupancyAlert(session: session, pid: pid)
                        alert.beginSheetModal(for: window) { response in
                            guard response == .alertSecondButtonReturn else {
                                launcher.endDeleting(session.key.agent); return
                            }
                            perform(session, provider: provider, library: library, window: window,
                                    acceptingUnknownOccupancy: true)
                        }
                    case .failure(let error):
                        launcher.endDeleting(session.key.agent)
                        // Native operations may fail after a partial mutation. Always reconcile.
                        library.refresh()
                        show(error.localizedDescription, window: window)
                    }
                }
            }
    }

    static func unknownOccupancyAlert(session: AgentSession, pid: Int32?) -> SessionDeletionConfirmation {
        let alert = SessionDeletionConfirmation()
        alert.messageText = L("Delete despite unknown external usage?")
        alert.informativeText = session.title + "\n\n"
            + L("This session may be in use elsewhere. Delete only if it is idle. This cannot be undone.")
        alert.addButton(withTitle: L("Cancel"))
        alert.addButton(withTitle: L("Permanently delete anyway"))
        return alert
    }

    /// 删除一段会话：身份核对 → 外部占用 → 该 Agent 的额外核查 → 原生删除。
    /// 用户对「说不清谁在用」的明确同意只压掉 `unknownOccupancy`，确认有人在用、
    /// 原生写锁拒绝照样失败。
    static func delete(_ key: AgentSessionKey, provider: AgentSessionProvider,
                       acceptingUnknownOccupancy: Bool = false,
                       known: [AgentProcessIdentity: AgentSessionKey] = [:]) throws {
        guard provider.source.owns(key) else { throw Failure.invalidSource }
        if case .inUse(let pid) = provider.occupancy(of: key) {
            throw Failure.occupiedProcess(pid)
        }
        do {
            do { try provider.checkDeletable(key, known: known) }
            catch Failure.unknownOccupancy where acceptingUnknownOccupancy {
                // Explicit consent for this request only. Occupied and other failures still throw.
            }
            try provider.delete(key)
        } catch let error as Failure { throw error }
        catch { throw Failure.failed }
    }

    enum Failure: LocalizedError {
        case invalidSource, occupied, occupiedProcess(Int32), unknownOccupancy(Int32?), failed
        var errorDescription: String? {
            switch self {
            case .invalidSource: return L("This CLI session source is no longer available.")
            case .occupied: return L("This session is still running or starting. Exit its Agent before deleting; the idle terminal can stay open.")
            case .occupiedProcess(let pid): return L("This session is still running or starting. Exit its Agent before deleting; the idle terminal can stay open.") + "\nPID: \(pid)"
            case .unknownOccupancy(let pid): return L("Could not confirm which session an external or unassociated Claude process is using. Deletion was not performed. Check that process before retrying.") + (pid.map { "\nPID: \($0)" } ?? "")
            case .failed: return L("The Agent could not complete deletion. It may be in use, missing, or unsupported by this CLI version. The list will refresh; deletion may have partially completed.")
            }
        }
    }
    private static func show(_ message: String, window: NSWindow) {
        let alert = AppBranding.makeAlert()
        alert.messageText = L("Session deletion")
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }
}
