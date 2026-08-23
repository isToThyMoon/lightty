import AppKit
import GhosttyKit

/// 启动时从 ghostty 配置读出的壳层所需值。
/// 视觉铁律（HANDOVER 8.2.1）：一切视觉参数以 ~/.config/ghostty/config 为唯一来源，
/// 取值方式与推导公式对齐官方壳（docs/libghostty-embedding.md 配置对齐清单）。
struct GhosttyConfigValues {
    var backgroundColor: NSColor = .windowBackgroundColor
    var foregroundColor: NSColor = .textColor
    var backgroundOpacity: Double = 1
    var backgroundBlur: Int16 = 0
    var windowTheme: String?
    var splitDividerColor: NSColor = .separatorColor

    var isTransparent: Bool { backgroundOpacity < 1 }

    /// window-theme → NSAppearance；auto 按背景亮度推导（官方 Config.windowTheme 同式）
    var appearance: NSAppearance? {
        switch windowTheme {
        case "light": return NSAppearance(named: .aqua)
        case "dark": return NSAppearance(named: .darkAqua)
        case "auto":
            return backgroundColor.isLightColor
                ? NSAppearance(named: .aqua)
                : NSAppearance(named: .darkAqua)
        default: return nil // system
        }
    }
}

/// libghostty 生命周期与回调的唯一持有者。
/// 调用序列与回调约定见 docs/libghostty-embedding.md（钉在 vendor 的 ghostty.h，API 不稳定）。
final class GhosttyRuntime {
    static var shared: GhosttyRuntime!

    let app: ghostty_app_t
    let configValues: GhosttyConfigValues

    init() {
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            fatalError("ghostty_init failed")
        }

        // 加载顺序对齐官方壳；有意跳过 load_cli_args（lightty 的命令行属于自己）
        guard let config = ghostty_config_new() else { fatalError("ghostty_config_new failed") }
        ghostty_config_load_default_files(config)
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)
        self.configValues = Self.readConfigValues(config)

        var rt = ghostty_runtime_config_s()
        rt.userdata = nil
        rt.supports_selection_clipboard = false
        rt.wakeup_cb = { _ in
            // 任意线程 → 主队列 tick，全进程仅此一处
            DispatchQueue.main.async { GhosttyRuntime.shared?.tick() }
        }
        rt.action_cb = { _, _, _ in false }
        rt.read_clipboard_cb = { userdata, location, state in
            GhosttyRuntime.readClipboard(userdata, location: location, state: state)
        }
        rt.confirm_read_clipboard_cb = { userdata, _, state, _ in
            // 不做确认弹窗：直接放行读剪贴板
            guard let userdata, let state else { return }
            let view = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            guard let surface = view.surface else { return }
            let str = NSPasteboard.general.string(forType: .string) ?? ""
            str.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, true) }
        }
        rt.write_clipboard_cb = { _, _, content, count, _ in
            guard let content, count > 0 else { return }
            // 只取第一个 text 内容写系统剪贴板
            for i in 0..<count {
                let c = content[i]
                guard let mime = c.mime, let data = c.data else { continue }
                if String(cString: mime).hasPrefix("text/") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(String(cString: data), forType: .string)
                    break
                }
            }
        }
        rt.close_surface_cb = { userdata, _ in
            guard let userdata else { return }
            let view = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async { view.requestClose() }
        }

        guard let app = ghostty_app_new(&rt, config) else { fatalError("ghostty_app_new failed") }
        self.app = app
        // app 内部已 clone config
        ghostty_config_free(config)
    }

    func tick() {
        ghostty_app_tick(app)
    }

    // MARK: - config 读取

    private static func readConfigValues(_ config: ghostty_config_t) -> GhosttyConfigValues {
        var v = GhosttyConfigValues()

        if let bg = getColor(config, "background") { v.backgroundColor = bg }
        if let fg = getColor(config, "foreground") { v.foregroundColor = fg }

        var opacity: Double = 1
        _ = get(config, &opacity, "background-opacity")
        v.backgroundOpacity = opacity

        var blur: Int16 = 0
        _ = get(config, &blur, "background-blur")
        v.backgroundBlur = blur

        var theme: UnsafePointer<CChar>?
        if get(config, &theme, "window-theme"), let theme {
            v.windowTheme = String(cString: theme)
        }

        // split-divider-color：未设时按官方公式从 background 推导
        if let divider = getColor(config, "split-divider-color") {
            v.splitDividerColor = divider
        } else {
            let bg = v.backgroundColor
            v.splitDividerColor = bg.isLightColor ? bg.darken(by: 0.08) : bg.darken(by: 0.4)
        }
        return v
    }

    private static func get<T>(_ config: ghostty_config_t, _ value: inout T, _ key: String) -> Bool {
        withUnsafeMutablePointer(to: &value) { ptr in
            ghostty_config_get(config, ptr, key, UInt(key.utf8.count))
        }
    }

    private static func getColor(_ config: ghostty_config_t, _ key: String) -> NSColor? {
        var c = ghostty_config_color_s()
        guard get(config, &c, key) else { return nil }
        return NSColor(
            srgbRed: CGFloat(c.r) / 255,
            green: CGFloat(c.g) / 255,
            blue: CGFloat(c.b) / 255,
            alpha: 1)
    }

    // MARK: - 剪贴板回调

    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let userdata, let state else { return false }
        let view = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        guard let surface = view.surface else { return false }
        guard let str = NSPasteboard.general.string(forType: .string) else { return false }
        str.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, false) }
        return true
    }
}

extension NSColor {
    var isLightColor: Bool { luminance > 0.5 }

    var luminance: Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard let rgb = usingColorSpace(.sRGB) else { return 0 }
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        // 官方 OSColor+Extension 同式（ITU BT.709）
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    func darken(by amount: CGFloat) -> NSColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard let hsb = usingColorSpace(.sRGB) else { return self }
        hsb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: s, brightness: min(b * (1 - amount), 1), alpha: a)
    }
}
