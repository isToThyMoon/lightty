import AppKit
import LighttyCore
@testable import lightty

extension LaunchComposerController {
    /// 按浮层当前的选择装配终端：走和启动一样的请求，但不检查、不放置。
    func makePane() -> PaneView? {
        guard let request = makeRequest() else { return nil }
        return try? AppState.shared.paneLauncher.makePane(for: request)
    }
}

/// 重启恢复的装配，可替换会话模型与 CLI 查找——测试不调用用户的 Agent。
@MainActor
func restoredPane(from snapshot: PaneSnapshot,
                  sessionLibrary: SessionLibrary = AppState.shared.sessionLibrary,
                  locateExecutable: @escaping (String) -> String?) -> PaneView {
    PaneLauncher(sessionLibrary: sessionLibrary, taskBindings: AppState.shared.taskBindings,
                 runningPanes: { AppState.shared.runningPanes() },
                 openWindow: { AppState.shared.newWindow(initialPane: $0) },
                 locateExecutable: locateExecutable)
        .restoredPane(from: snapshot)
}
