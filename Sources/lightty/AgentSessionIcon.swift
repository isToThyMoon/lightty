import AppKit
import LighttyCore

/// Bundled, cached template logos: no network or repeated decoding during UI updates.
enum AgentSessionIcon {
    private static let claude = load("claude")
    private static let openAI = load("openai")

    static func image(for agent: SessionAgent) -> NSImage? {
        switch agent {
        case .claude: return claude
        case .codex: return openAI
        }
    }

    private static func load(_ name: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: "agent-" + name, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.accessibilityDescription = name == "claude" ? "Claude" : "OpenAI Codex"
        return image
    }
}
