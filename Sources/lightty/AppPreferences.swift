import AppKit

extension Notification.Name {
    /// 设置页改了任何偏好（外观 / 语言 / 终端主题）。userInfo["kind"] 为
    /// PreferenceKind 的 rawValue；菜单每次都重建，壳层 chrome 只在语言变更时重建。
    static let lighttyPreferencesDidChange = Notification.Name("lighttyPreferencesDidChange")
}

enum PreferenceKind: String {
    case appearance, language, terminalTheme

    static let userInfoKey = "kind"

    func post() {
        NotificationCenter.default.post(
            name: .lighttyPreferencesDidChange, object: nil,
            userInfo: [PreferenceKind.userInfoKey: rawValue])
    }

    static func from(_ notification: Notification) -> PreferenceKind? {
        (notification.userInfo?[userInfoKey] as? String).flatMap(PreferenceKind.init(rawValue:))
    }
}

/// 应用外观：跟随系统 / 浅色 / 深色。作用于 NSApp.appearance，壳层的动态色随之
/// 切换；terminal surface 经 TerminalSurfaceView 的 effectiveAppearance 回调把
/// 明暗告诉 libghostty，config 里的 light:/dark: 主题对也跟着走。
enum AppearancePreference: String, CaseIterable {
    case system, light, dark

    static let defaultsKey = "lightty.appearance"

    static func current(in defaults: UserDefaults = .standard) -> AppearancePreference {
        defaults.string(forKey: defaultsKey).flatMap(AppearancePreference.init(rawValue:)) ?? .system
    }

    static func set(_ value: AppearancePreference, in defaults: UserDefaults = .standard) {
        defaults.set(value.rawValue, forKey: defaultsKey)
        apply(value)
        PreferenceKind.appearance.post()
    }

    /// 启动时与切换时调用。
    static func apply(_ value: AppearancePreference = current()) {
        NSApp.appearance = value.appearance
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    var title: String {
        switch self {
        case .system: return L("System")
        case .light: return L("Light")
        case .dark: return L("Dark")
        }
    }
}

/// 界面语言：跟随系统 / English / 简体中文。L() 按这里选定的 lproj 查表，
/// 切换后新建的界面即刻生效；已在屏上的 chrome 由 controller 收到通知后重建。
enum LanguagePreference: String, CaseIterable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    static let defaultsKey = "lightty.language"

    /// L() 查表用的 bundle。system → Bundle.module（按系统语言偏好解析）；
    /// 指定语言 → 对应 lproj 子 bundle（找不到时退回 Bundle.module）。
    private(set) static var bundle: Bundle = resolveBundle(for: current())

    static func current(in defaults: UserDefaults = .standard) -> LanguagePreference {
        defaults.string(forKey: defaultsKey).flatMap(LanguagePreference.init(rawValue:)) ?? .system
    }

    static func set(_ value: LanguagePreference, in defaults: UserDefaults = .standard) {
        defaults.set(value.rawValue, forKey: defaultsKey)
        bundle = resolveBundle(for: value)
        PreferenceKind.language.post()
    }

    /// SwiftPM 资源包（swift build 下是平铺目录，打包后在 Contents/Resources）里的
    /// lproj 不走 path(forResource:ofType:)——它对 .lproj 按本地化目录处理而非普通
    /// 资源，会查不到。直接拼路径。
    private static func resolveBundle(for value: LanguagePreference) -> Bundle {
        guard value != .system else { return Bundle.module }
        let root = Bundle.module.bundleURL
        let candidates = [
            root.appendingPathComponent("\(value.rawValue).lproj"),
            root.appendingPathComponent("Contents/Resources/\(value.rawValue).lproj"),
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let bundle = Bundle(url: url) { return bundle }
        }
        return Bundle.module
    }

    var title: String {
        switch self {
        case .system: return L("System language")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }
}
