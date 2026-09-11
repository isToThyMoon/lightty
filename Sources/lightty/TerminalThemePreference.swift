import Foundation

/// 控制整套随包终端配置是否独立使用。保留原存储键以延续用户的开关选择。
enum TerminalThemePreference {
    static let defaultsKey = "lightty.terminalTheme.useBuiltIn"

    static func usesBuiltInTheme(in defaults: PreferenceStorage = FilePreferences.shared) -> Bool {
        defaults.register(defaults: [defaultsKey: true])
        return defaults.bool(forKey: defaultsKey)
    }

    static func setUsesBuiltInTheme(
        _ enabled: Bool,
        in defaults: PreferenceStorage = FilePreferences.shared
    ) {
        defaults.set(enabled, forKey: defaultsKey)
    }
}
