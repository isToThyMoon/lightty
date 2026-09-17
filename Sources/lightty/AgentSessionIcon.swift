import AppKit
import LighttyCore

/// Bundled, cached logos: no network or repeated decoding during UI updates.
///
/// 每家用自己的标识色。Claude 的星芒是品牌橙（#D97757，写在 SVG 里），明暗底上都
/// 站得住，所以不做 template——它不跟随任何前景色。OpenAI 的标识本身就是单色，
/// 黑底反白、白底纯黑才是它的原样，所以只有它保持 template 由调用方着色。
enum AgentSessionIcon {
    /// 资源名写在各家的 spec 里；这里只负责加载与缓存，不认识任何一家的名字。
    private static let images: [SessionAgent: NSImage] = SessionAgent.allCases
        .reduce(into: [:]) { images, agent in
            images[agent] = load(agent.spec.iconAssetName)
        }

    static func image(for agent: SessionAgent) -> NSImage? { images[agent] }

    /// 没进 agent 的普通终端：取自应用图标左半的「>」提示符（lightty-icon.svg 的折线
    /// 角度与圆头），外形高度与 logo 相当。线宽比应用图标收细：12pt 下照搬原比例
    /// 显得太浓，收到与旁边标题文字笔画相近。template 由调用方着色。
    /// 不是哪一家 agent 的标识，只给固定留了图标位的地方补位，免得那一格空着。
    static let terminalPrompt: NSImage? = {
        guard let url = Bundle.module.url(forResource: "terminal-prompt", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.accessibilityDescription = "Terminal"
        return image
    }()

    private static func load(_ name: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: "agent-" + name, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = name != "claude"
        image.accessibilityDescription = name == "claude" ? "Claude" : "OpenAI Codex"
        return image
    }
}
