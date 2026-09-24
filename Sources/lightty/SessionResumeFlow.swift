import AppKit
import LighttyCore

/// 续接会话与原生选择器的呈现层：把请求交给 `PaneLauncher`，再按结果弹目录选择面板、
/// 占用提示或错误框。检查什么、按什么顺序检查都不在这里。
enum SessionResumeFlow {
    static func open(_ session: AgentSession, source: SessionCatalogSource,
                     in controller: TerminalWindowController, destination: TerminalLaunchDestination = .tab) {
        open(TerminalLaunchRequest(.resume(session, source: source), destination: destination), in: controller)
    }

    /// 已经组好的续接请求（启动浮层选了去处）。拒绝原因的呈现与上面一致。
    static func open(_ request: TerminalLaunchRequest, in controller: TerminalWindowController) {
        AppState.shared.paneLauncher.launch(request, in: controller) { [weak controller] outcome in
            guard let controller, case .notLaunched(let refusal) = outcome else { return }
            switch refusal {
            case .needsWorkingDirectory(let message):
                let picker = NSOpenPanel()
                picker.message = message
                picker.canChooseFiles = false
                picker.canChooseDirectories = true
                guard picker.runModal() == .OK, let path = picker.url?.path else { return }
                var retry = request
                retry.workingDirectory = path
                open(retry, in: controller)
            case .occupied(let pid):
                guard let window = controller.window else { return }
                let alert = AppBranding.makeAlert()
                alert.messageText = L("This session is already open in another terminal.")
                alert.informativeText = L("Continue in the original terminal, or exit the Agent there before resuming here. lightty will not stop it or remove its lock.") + "\nPID: \(pid)"
                alert.beginSheetModal(for: window)
            case .unavailable(let error):
                showError(error, in: controller.window)
            case .deletingSession, .alreadyStarting, .noPlacement:
                break
            }
        }
    }

    static func nativePicker(source: SessionCatalogSource, in controller: TerminalWindowController) {
        AppState.shared.paneLauncher.launch(.init(.sessionPicker(source), destination: .tab), in: controller) {
            [weak controller] outcome in
            if case .notLaunched(.unavailable(let error)) = outcome { showError(error, in: controller?.window) }
        }
    }

    private static func showError(_ error: Error, in window: NSWindow?) {
        let alert = AppBranding.makeAlert()
        alert.messageText = L("Could not resume this session.")
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? L("Check the CLI and session folder, then try again.")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
