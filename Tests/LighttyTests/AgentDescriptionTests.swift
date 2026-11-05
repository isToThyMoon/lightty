import Foundation
import LighttyCore
import Testing
@testable import lightty

/// 界面上的两个 Agent 枚举（启动选择、hook 安装）都从 `SessionAgent` 取描述，
/// 映射是穷举 switch。这里钉住往返和取值，映错一家就是静默失败，所以要测。
struct AgentDescriptionTests {
    @Test func launchChoiceRawValuesStayStableInUserPreferences() {
        // rawValue 写在用户偏好里，不能因为集中描述而变。
        #expect(LaunchAgent.allCases.map(\.rawValue) == ["claudeCode", "codex", "terminal"])
    }

    @Test func hookAgentRawValuesStayStableOnDisk() {
        #expect(HookAgent.allCases.map(\.rawValue) == ["claudeCode", "codex"])
    }
}
