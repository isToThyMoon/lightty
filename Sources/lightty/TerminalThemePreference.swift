import Foundation

/// Lightty 只选择 `theme` 的职权开关；其余 terminal 配置始终允许用户覆盖。
enum TerminalThemePreference {
    static let defaultsKey = "lightty.terminalTheme.useBuiltIn"

    static func usesBuiltInTheme(in defaults: UserDefaults = .standard) -> Bool {
        defaults.register(defaults: [defaultsKey: true])
        return defaults.bool(forKey: defaultsKey)
    }

    static func setUsesBuiltInTheme(
        _ enabled: Bool,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(enabled, forKey: defaultsKey)
    }
}
