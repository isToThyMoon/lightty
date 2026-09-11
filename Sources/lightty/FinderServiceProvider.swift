import AppKit
import GhosttyKit

/// Finder 右键 → Services 里的「New Lightty Tab Here / New Lightty Window Here」。
///
/// 菜单项本身由 Info.plist 的 `NSServices` 声明（scripts/package-app.sh 生成），
/// `NSMessage` 对应这里的 selector；AppKit 按 `<message>:userData:error:` 的签名
/// 反射调用，所以方法名和参数形状都不能改。swift build 出来的裸可执行没有
/// Info.plist，本地调试看不到菜单项，只能打包后放进 /Applications 验证。
///
/// 兜底规则（与 Ghostty 对齐并补齐几处）：
/// - 选中的是文件 → 打开其所在目录；不存在的路径 → 跳过。
/// - 多选 → 去重后每个目录各开一个 tab / 窗口；顺序跟 Finder 选中顺序一致。
/// - Finder 传的是文件 URL；纯文本路径（其它 app 通过 Services 传字符串）也接受。
/// - 要开 tab 但一个窗口都没有 → 退化成新窗口，剩余目录进这个新窗口的 tab。
/// - 目标窗口已最小化 / 正显示设置页 → 先还原、收起设置页再加 tab。
@MainActor
final class FinderServiceProvider: NSObject {
    enum Target { case tab, window }

    @objc func openTab(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        open(from: pasteboard, target: .tab, error: error)
    }

    @objc func openWindow(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        open(from: pasteboard, target: .window, error: error)
    }

    private func open(
        from pasteboard: NSPasteboard,
        target: Target,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        // 服务由 Finder 触发时 app 可能刚被拉起：AppKit 保证在 didFinishLaunching
        // 之后才派发，但 AppState 仍是隐式解包，这里显式守一下而不是让它炸。
        guard let state = AppState.shared else {
            error.pointee = L("Lightty is still starting up. Try again in a moment.") as NSString
            return
        }
        let directories = Self.directories(from: pasteboard)
        guard !directories.isEmpty else {
            error.pointee = L("No folder to open.") as NSString
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        open(directories, target: target, in: state)
    }

    /// 真正开 tab / 窗口的一步，与剪贴板解析分开，便于测试直接喂目录。
    func open(_ directories: [URL], target: Target, in state: AppState) {
        switch target {
        case .window:
            for directory in directories {
                state.newWindow(initialPane: pane(for: directory, context: GHOSTTY_SURFACE_CONTEXT_WINDOW))
            }

        case .tab:
            var remaining = directories[...]
            let host: TerminalWindowController
            if let controller = state.keyWindowController, let window = controller.window {
                window.deminiaturize(nil)
                window.makeKeyAndOrderFront(nil)
                controller.hideSettings()
                host = controller
            } else {
                // 没有任何窗口可挂 tab：第一个目录撑起新窗口，其余照常进 tab。
                guard let first = remaining.popFirst() else { return }
                host = state.newWindow(initialPane: pane(for: first, context: GHOSTTY_SURFACE_CONTEXT_WINDOW))
            }
            for directory in remaining {
                state.newTab(from: host, initialPane: pane(for: directory, context: GHOSTTY_SURFACE_CONTEXT_TAB))
            }
        }
    }

    private func pane(for directory: URL, context: ghostty_surface_context_e) -> PaneView {
        var configuration = TerminalSurfaceConfiguration()
        configuration.workingDirectory = directory.path
        configuration.context = context
        return PaneView(surfaceConfiguration: configuration)
    }

    // MARK: - 剪贴板解析

    /// 文件 URL 优先（Finder 给的是 NSFilenamesPboardType，NSURL 能直接读）；
    /// 读不到再退回纯文本，按行当路径处理。
    nonisolated static func directories(from pasteboard: NSPasteboard) -> [URL] {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            !urls.isEmpty {
            return directories(fromPaths: urls.map { $0.path })
        }
        let text = pasteboard.string(forType: .string) ?? ""
        return directories(fromPaths: text.components(separatedBy: .newlines))
    }

    /// 路径 → 可作为工作目录的目录列表：展开 `~`、文件取父目录、不存在的跳过、
    /// 去重但保持首次出现的顺序。
    nonisolated static func directories(fromPaths paths: [String]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for raw in paths {
            let path = (raw.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            guard !path.isEmpty, path.hasPrefix("/") else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            let directory = isDirectory.boolValue
                ? URL(fileURLWithPath: path, isDirectory: true)
                : URL(fileURLWithPath: path).deletingLastPathComponent()
            let key = directory.standardizedFileURL.path
            guard seen.insert(key).inserted else { continue }
            result.append(URL(fileURLWithPath: key, isDirectory: true))
        }
        return result
    }
}
