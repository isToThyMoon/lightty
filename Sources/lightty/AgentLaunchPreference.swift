import Foundation

enum LaunchAgent: String, CaseIterable {
    case claudeCode, codex, terminal

    var title: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .terminal: return L("Terminal only")
        }
    }

    var defaultCommand: String {
        switch self {
        case .claudeCode: return "claude --permission-mode bypassPermissions"
        case .codex: return "codex --yolo"
        case .terminal: return ""
        }
    }

    var launchTitle: String {
        self == .terminal ? L("Open terminal") : L("Launch %@", title)
    }
}

enum AgentLaunchPreference {
    private static let selectedKey = "lightty.agent.selected"
    private static func commandKey(_ agent: LaunchAgent) -> String { "lightty.agent.command.\(agent.rawValue)" }

    static func selected(in defaults: PreferenceStorage = FilePreferences.shared) -> LaunchAgent {
        defaults.string(forKey: selectedKey).flatMap(LaunchAgent.init(rawValue:)) ?? .codex
    }

    static func select(_ agent: LaunchAgent, in defaults: PreferenceStorage = FilePreferences.shared) {
        defaults.set(agent.rawValue, forKey: selectedKey)
    }

    static func command(for agent: LaunchAgent, in defaults: PreferenceStorage = FilePreferences.shared) -> String {
        guard agent != .terminal else { return "" }
        return defaults.string(forKey: commandKey(agent)) ?? agent.defaultCommand
    }

    @discardableResult
    static func setCommand(_ command: String, for agent: LaunchAgent,
                           in defaults: PreferenceStorage = FilePreferences.shared) -> Bool {
        guard agent != .terminal,
              !command.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { defaults.removeObject(forKey: commandKey(agent)) }
        else { defaults.set(trimmed, forKey: commandKey(agent)) }
        return true
    }

    static func initialInput(for agent: LaunchAgent, in defaults: PreferenceStorage = FilePreferences.shared) -> String? {
        agent == .terminal ? nil : command(for: agent, in: defaults) + "\n"
    }

    static func resetCommands(in defaults: PreferenceStorage = FilePreferences.shared) {
        for agent in LaunchAgent.allCases { defaults.removeObject(forKey: commandKey(agent)) }
    }
}
