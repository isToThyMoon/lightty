import Foundation
import LighttyCore

enum LaunchAgent: String, CaseIterable {
    case claudeCode, codex, terminal

    var title: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .terminal: return L("Terminal only")
        }
    }

    /// 程序名而非路径：命令敲进用户自己的 shell，由 PATH 解析。
    var program: String {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        case .terminal: return ""
        }
    }

    /// 每家 CLI 表达「跳过权限确认」的原生写法。开关是一个而不是每家一个：
    /// 用户表达的是意图，具体参数是 lightty 对内部 Agent 的翻译。
    var bypassArguments: [String] {
        switch self {
        case .claudeCode: return ["--permission-mode", "bypassPermissions"]
        case .codex: return ["--yolo"]
        case .terminal: return []
        }
    }

    var launchTitle: String {
        self == .terminal ? L("Open terminal") : L("Launch %@", title)
    }
}

enum AgentLaunchPreference {
    private static let selectedKey = "lightty.agent.selected"
    private static let bypassKey = "lightty.agent.bypassPermissions"
    private static func argumentsKey(_ agent: LaunchAgent) -> String { "lightty.agent.arguments.\(agent.rawValue)" }
    private static func legacyCommandKey(_ agent: LaunchAgent) -> String { "lightty.agent.command.\(agent.rawValue)" }

    static func selected(in defaults: PreferenceStorage = FilePreferences.shared) -> LaunchAgent {
        defaults.string(forKey: selectedKey).flatMap(LaunchAgent.init(rawValue:)) ?? .codex
    }

    static func select(_ agent: LaunchAgent, in defaults: PreferenceStorage = FilePreferences.shared) {
        defaults.set(agent.rawValue, forKey: selectedKey)
    }

    /// 默认开启：这是 lightty 上线以来的既有行为，关掉是用户的显式选择。
    static func bypassEnabled(in defaults: PreferenceStorage = FilePreferences.shared) -> Bool {
        defaults.object(forKey: bypassKey) as? Bool ?? true
    }

    static func setBypass(_ enabled: Bool, in defaults: PreferenceStorage = FilePreferences.shared) {
        defaults.set(enabled, forKey: bypassKey)
    }

    /// 用户自己追加的参数，原样保存：这一行最终交给 shell，引号由用户掌握。
    static func customArguments(for agent: LaunchAgent,
                                in defaults: PreferenceStorage = FilePreferences.shared) -> String {
        agent == .terminal ? "" : defaults.string(forKey: argumentsKey(agent)) ?? ""
    }

    @discardableResult
    static func setCustomArguments(_ arguments: String, for agent: LaunchAgent,
                                   in defaults: PreferenceStorage = FilePreferences.shared) -> Bool {
        guard agent != .terminal,
              !arguments.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        let trimmed = arguments.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { defaults.removeObject(forKey: argumentsKey(agent)) }
        else { defaults.set(trimmed, forKey: argumentsKey(agent)) }
        return true
    }

    /// 新终端里敲的整行启动命令 = 程序 + 跳过权限参数 + 自定义参数。
    static func command(for agent: LaunchAgent, in defaults: PreferenceStorage = FilePreferences.shared) -> String {
        guard agent != .terminal else { return "" }
        let parts = [agent.program]
            + (bypassEnabled(in: defaults) ? agent.bypassArguments : [])
            + [customArguments(for: agent, in: defaults)]
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func initialInput(for agent: LaunchAgent, in defaults: PreferenceStorage = FilePreferences.shared) -> String? {
        agent == .terminal ? nil : command(for: agent, in: defaults) + "\n"
    }

    /// 恢复会话时随原生续接命令一起传的参数。可执行文件由会话自己的来源探测，
    /// 所以程序名不参与——只有参数需要跟着当前设置走。
    static func launchArguments(for agent: SessionAgent,
                                in defaults: PreferenceStorage = FilePreferences.shared) -> [String] {
        let launch: LaunchAgent = agent == .codex ? .codex : .claudeCode
        return (bypassEnabled(in: defaults) ? launch.bypassArguments : [])
            + tokenize(customArguments(for: launch, in: defaults))
    }

    static func reset(in defaults: PreferenceStorage = FilePreferences.shared) {
        defaults.removeObject(forKey: bypassKey)
        for agent in LaunchAgent.allCases { defaults.removeObject(forKey: argumentsKey(agent)) }
    }

    /// 0.1.x 存的是整条命令。拆回附加参数：程序名丢弃（现在不可改），认得出的 bypass
    /// 写法删掉——它已经由开关表达，留着会重复。开关一律用默认值（打开），不按旧命令
    /// 反推：一个开关表达不了「一家开一家关」，与其猜，不如给所有人同一个起点。
    static func migrateLegacyCommands(in defaults: PreferenceStorage = FilePreferences.shared) {
        for agent in LaunchAgent.allCases {
            guard let command = defaults.string(forKey: legacyCommandKey(agent)) else { continue }
            var rest = Array(tokenize(command).dropFirst())
            if let range = rest.firstRange(of: agent.bypassArguments) { rest.removeSubrange(range) }
            if defaults.object(forKey: argumentsKey(agent)) == nil, !rest.isEmpty {
                defaults.set(rest.joined(separator: " "), forKey: argumentsKey(agent))
            }
            defaults.removeObject(forKey: legacyCommandKey(agent))
        }
    }

    /// 按 shell 的引号规则切词。存下来的参数已经排除控制字符，切词只用于把
    /// 每个参数单独引用后交给恢复命令，不会把整行丢回 shell 重新解释。
    static func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var started = false
        var quote: Character?
        for character in command {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
                started = true
            } else if character == " " || character == "\t" {
                if started { tokens.append(current) }
                current = ""
                started = false
            } else {
                current.append(character)
                started = true
            }
        }
        if started { tokens.append(current) }
        return tokens
    }
}
