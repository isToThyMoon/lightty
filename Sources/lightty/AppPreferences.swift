import AppKit

extension Notification.Name {
    /// 设置页改了任何偏好（外观 / 语言 / 终端主题）。userInfo["kind"] 为
    /// PreferenceKind 的 rawValue；菜单每次都重建，壳层 chrome 只在语言变更时重建。
    static let lighttyPreferencesDidChange = Notification.Name("lighttyPreferencesDidChange")
}

enum PreferenceKind: String {
    case appearance, language, terminalTheme, accent

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

/// 重点色：用户可选的命名色（ChatGPT 桌面版同款菜单），出厂粉色。驱动 ShellStyle.accent；
/// 带色相的档位同时接管导航色（标签页侧栏活跃态），默认/白两档无色相时导航色
/// 退回内置蔚蓝，保证「你在哪」始终扫得到。
enum AccentPreference: String, CaseIterable {
    case `default`, blue, green, yellow, pink, orange, purple, white

    static let defaultsKey = "lightty.accent"

    /// 未设置时的出厂值：粉色
    static let factory: AccentPreference = .pink

    static func current(in defaults: UserDefaults = .standard) -> AccentPreference {
        defaults.string(forKey: defaultsKey).flatMap(AccentPreference.init(rawValue:)) ?? factory
    }

    static func set(_ value: AccentPreference, in defaults: UserDefaults = .standard) {
        defaults.set(value.rawValue, forKey: defaultsKey)
        PreferenceKind.accent.post()
    }

    var title: String {
        switch self {
        case .default: return L("Default")
        case .blue: return L("Blue")
        case .green: return L("Green")
        case .yellow: return L("Yellow")
        case .pink: return L("Pink")
        case .orange: return L("Orange")
        case .purple: return L("Purple")
        case .white: return L("White")
        }
    }

    /// 有色相 = 可以充当导航色
    var hasHue: Bool { self != .default && self != .white }

    /// 重点色本体（明暗各一档，深色下提亮一档保证在深底上可读）
    var color: NSColor {
        switch self {
        case .default: return NSColor.shellDynamic(light: 0x353331, dark: 0xE9E7EC)
        case .blue: return NSColor.shellDynamic(light: 0x2563EB, dark: 0x60A5FA)
        case .green: return NSColor.shellDynamic(light: 0x16A34A, dark: 0x4ADE80)
        case .yellow: return NSColor.shellDynamic(light: 0xCA8A04, dark: 0xFACC15)
        case .pink: return NSColor.shellDynamic(light: 0xF077AF, dark: 0xF077AF)
        case .orange: return NSColor.shellDynamic(light: 0xEA580C, dark: 0xFB923C)
        case .purple: return NSColor.shellDynamic(light: 0x7C3AED, dark: 0xA78BFA)
        // 白：浅色下没法用白，退回中性深；深色下才是真白
        case .white: return NSColor.shellDynamic(light: 0x353331, dark: 0xFFFFFF)
        }
    }

    /// 压在重点色上的前景（开关滑块、勾）
    var foreground: NSColor {
        switch self {
        case .default, .white: return NSColor.shellDynamic(light: 0xFFFFFF, dark: 0x26242B)
        default: return NSColor.shellDynamic(light: 0xFFFFFF, dark: 0x1C1B1F)
        }
    }

    /// 菜单里的色点
    var swatch: NSColor {
        switch self {
        case .default: return NSColor.shellDynamic(light: 0xFFFFFF, dark: 0x3B3841)
        case .white: return NSColor.shellDynamic(light: 0xFFFFFF, dark: 0xFFFFFF)
        default: return color
        }
    }
}
