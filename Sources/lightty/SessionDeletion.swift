import AppKit
import LighttyCore

/// Provider-owned permanent deletion. No transcript paths or database schemas live here.
enum SessionDeletion {
    // Main-thread exclusion also covers resume/picker launches while confirmation is open.
    private(set) static var busyAgents = Set<SessionAgent>()

    static func confirm(_ session: AgentSession, library: SessionLibrary, window: NSWindow) {
        guard !busyAgents.contains(session.key.agent), !library.saving,
              library.organizationReady, library.storageError == nil,
              let source = library.source(for: session.key.agent) else { return }
        for entry in AppState.shared.runningPanes() { entry.pane.reconcileSessionProcess() }
        guard library.openPaneIDs(for: session.key).isEmpty, !SessionResumeFlow.isStarting(session.key) else {
            show(Failure.occupied.localizedDescription, window: window)
            return
        }
        busyAgents.insert(session.key.agent)
        let alert = SessionDeletionConfirmation()
        alert.messageText = L("Permanently delete this session?")
        alert.informativeText = session.title + "\n\n" + L("Includes child conversations. This cannot be undone.")
        alert.addButton(withTitle: L("Cancel"))
        alert.addButton(withTitle: L("Permanently delete"))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertSecondButtonReturn else {
                busyAgents.remove(session.key.agent); return
            }
            perform(session, source: source, library: library, window: window)
        }
    }

    private static func perform(_ session: AgentSession, source: SessionCatalogSource,
                                library: SessionLibrary, window: NSWindow,
                                acceptingUnknownOccupancy: Bool = false) {
            // Recheck after either confirmation; consent never overrides a known active session.
            for entry in AppState.shared.runningPanes() { entry.pane.reconcileSessionProcess() }
            guard library.openPaneIDs(for: session.key).isEmpty,
                  !SessionResumeFlow.isStarting(session.key) else {
                busyAgents.remove(session.key.agent)
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
                let result = Result { try delete(session.key, source: source,
                    acceptingUnknownOccupancy: acceptingUnknownOccupancy,
                    checkProcesses: { try requireClaudeSessionAvailable(session.key, known: associations,
                                                                       executable: source.executable) }) }
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        busyAgents.remove(session.key.agent)
                        library.didDelete(session.key)
                    case .failure(Failure.unknownOccupancy(let pid)):
                        let alert = unknownOccupancyAlert(session: session, pid: pid)
                        alert.beginSheetModal(for: window) { response in
                            guard response == .alertSecondButtonReturn else {
                                busyAgents.remove(session.key.agent); return
                            }
                            perform(session, source: source, library: library, window: window,
                                    acceptingUnknownOccupancy: true)
                        }
                    case .failure(let error):
                        busyAgents.remove(session.key.agent)
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

    static func delete(_ key: AgentSessionKey, source: SessionCatalogSource,
                       helperDirectory: URL = ClaudeSessionCatalog.installedHelper,
                       acceptingUnknownOccupancy: Bool = false,
                       checkProcesses: (() throws -> Void)? = nil) throws {
        guard UUID(uuidString: key.nativeID) != nil, key.agent == source.agent,
              source.root.standardizedFileURL.path == key.sourceRoot,
              source.root.path != "/" else { throw Failure.invalidSource }
        if case .inUse(let pid) = SessionOccupancy.check(key, executable: source.executable) {
            throw Failure.occupiedProcess(pid)
        }
        var environment = ProcessInfo.processInfo.environment
        for name in environment.keys where name.hasPrefix("LIGHTTY_") { environment.removeValue(forKey: name) }
        environment["PATH"] = HookInstaller.searchPath().joined(separator: ":")
        do {
            switch key.agent {
            case .codex:
                environment["CODEX_HOME"] = source.root.path
                _ = try SessionHelperProcess.readPage(executable: URL(fileURLWithPath: source.executable),
                    arguments: ["delete", "--force", key.nativeID], directory: source.root,
                    environment: environment, cancelled: { false }, timeout: 45)
            case .claude:
                do {
                    if let checkProcesses { try checkProcesses() }
                    else { try requireClaudeSessionAvailable(key, known: [:], executable: source.executable) }
                } catch Failure.unknownOccupancy where acceptingUnknownOccupancy {
                    // Explicit consent for this request only. Occupied and other failures still throw.
                }
                #if arch(arm64)
                let runtime = "runtime-arm64/node"
                #else
                let runtime = "runtime-x64/node"
                #endif
                // SDK helper is a local filesystem operation, not a Claude Agent invocation.
                let data = try SessionHelperProcess.readPage(executable: helperDirectory.appendingPathComponent(runtime),
                    arguments: [helperDirectory.appendingPathComponent("delete-session.mjs").path, key.nativeID],
                    directory: helperDirectory,
                    environment: ["PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": source.root.path],
                    cancelled: { false })
                guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      value["deleted"] as? String == key.nativeID else { throw Failure.failed }
            }
        } catch let error as Failure { throw error }
        catch { throw Failure.failed }
    }

    static func requireClaudeSessionAvailable(_ target: AgentSessionKey,
                                              known: [AgentProcessIdentity: AgentSessionKey],
                                              executable: String? = nil) throws {
        // lsof alone misses Claude, which need not keep its transcript descriptor open.
        guard let data = try? SessionHelperProcess.readPage(executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "pid=,comm="], directory: URL(fileURLWithPath: "/"),
            environment: ["PATH": "/usr/bin:/bin"], cancelled: { false }, timeout: 3) else {
            throw Failure.unknownOccupancy(nil)
        }
        var live: [Int32: AgentSessionKey] = [:]
        // Claude 自己就知道每个活着的进程在跑哪段会话。以前只认 lightty 自己开的 pane，
        // 用户在别处开着的 claude 一律算「说不清」，于是删除几乎每次都要弹一次警告。
        if let executable,
           let registry = SessionOccupancy.liveClaudeSessions(executable: executable, root: target.sourceRoot) {
            for (pid, id) in registry {
                live[pid] = AgentSessionKey(agent: .claude, sourceRoot: target.sourceRoot, nativeID: id)
            }
        }
        // PID reuse must never inherit the previous process's session identity.
        // 自己的 pane 后合并：这份身份是核对过进程标识的，比问来的更可信。
        for (identity, key) in known where AgentProcessIdentity.read(identity.pid) == identity {
            live[identity.pid] = key
        }
        try inspectClaudeProcesses(data, target: target, known: live)
    }

    static func inspectClaudeProcesses(_ data: Data, target: AgentSessionKey,
                                      known: [Int32: AgentSessionKey]) throws {
        guard !data.isEmpty else { throw Failure.unknownOccupancy(nil) }
        var unknown: Int32?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, let pid = Int32(fields[0]) else { throw Failure.unknownOccupancy(nil) }
            let name = fields[1].trimmingCharacters(in: .whitespaces)
            guard name == "claude" || name.hasSuffix("/claude") else { continue }
            guard let key = known[pid] else { unknown = pid; continue }
            // Native IDs alone are not enough: custom configuration roots are independent.
            if key == target { throw Failure.occupiedProcess(pid) }
        }
        if let unknown { throw Failure.unknownOccupancy(unknown) }
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
