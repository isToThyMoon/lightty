import Foundation

/// 用户登录 shell 的 PATH。
///
/// 从 Finder / Dock 启动时进程 PATH 只有 `/usr/bin:/bin:/usr/sbin:/sbin`。npm 全局包
/// 在 nvm / volta / fnm / pnpm / asdf 下各有各的 bin 目录，靠写死清单永远追不全，
/// 用户在终端里能敲 `codex`、lightty 却说"未检测到"就是这么来的。根治是问一次
/// `$SHELL -ilc` 拿到用户真实的 PATH——VS Code 等 GUI 开发工具都这么做。
///
/// 结果落盘缓存：下次启动同步可用，后台再刷新；变了就发通知让会话目录重扫。
/// 第一次（没有缓存）同步等一小会儿，避免升级后首启恢复 agent 会话时找不到 CLI。
enum LoginShellPath {
    static let didChangeNotification = Notification.Name("lightty.loginShellPathDidChange")
    static let defaultsKey = "lightty.loginShellPath"
    /// 传给子 shell 的标记：用户 rc 文件可据此跳过慢操作（如 tmux attach）。
    static let environmentMarker = "LIGHTTY_RESOLVING_PATH"

    private static let lock = NSLock()
    private static var cached: [String]?

    /// 当前已知的登录 shell PATH 目录；没解析过也没缓存时为空。
    static var directories: [String] {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let stored = FilePreferences.shared.string(forKey: defaultsKey).map(parse) ?? []
        cached = stored
        return stored
    }

    /// 启动时调一次：没有缓存就同步解析（有上限），有缓存则后台刷新。
    static func prime(timeout: TimeInterval = 2) {
        if directories.isEmpty {
            if let resolved = resolve(timeout: timeout) { store(resolved) }
        } else {
            refresh()
        }
    }

    /// 后台刷新；变化时更新缓存、落盘并在主线程发 `didChangeNotification`。
    static func refresh(timeout: TimeInterval = 5, completion: (([String]) -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async {
            guard let resolved = resolve(timeout: timeout) else {
                DispatchQueue.main.async { completion?(directories) }
                return
            }
            let changed = store(resolved)
            DispatchQueue.main.async {
                if changed { NotificationCenter.default.post(name: didChangeNotification, object: nil) }
                completion?(resolved)
            }
        }
    }

    /// 写入缓存与偏好；返回是否与之前不同。
    @discardableResult
    static func store(_ resolved: [String]) -> Bool {
        let changed = directories != resolved
        lock.lock(); cached = resolved; lock.unlock()
        if changed { FilePreferences.shared.set(resolved.joined(separator: ":"), forKey: defaultsKey) }
        return changed
    }

    /// 同步执行登录 shell 取 PATH。输出用随机标记包住，rc 文件里的 echo / 警告
    /// 不会混进来。超时或 shell 不存在返回 nil，调用方沿用旧值。
    static func resolve(
        shell: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval
    ) -> [String]? {
        let shell = shell ?? environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let marker = "LIGHTTY_PATH_\(UUID().uuidString)"
        // fish 的 $PATH 是列表，要先 join；POSIX shell 直接引用。
        let script = (shell as NSString).lastPathComponent == "fish"
            ? "printf '%s%s%s' '\(marker)' (string join : $PATH) '\(marker)'"
            : "printf '%s%s%s' '\(marker)' \"$PATH\" '\(marker)'"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", script]
        var env = environment
        env[environmentMarker] = "1"
        env["TERM"] = "dumb"
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }

        // 读端放到别的队列：rc 输出可能塞满管道，主等待方不能同时兼任读者。
        var data = Data()
        let finished = DispatchGroup()
        finished.enter()
        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            finished.leave()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8),
              let path = extract(output, marker: marker) else { return nil }
        return parse(path)
    }

    /// 从 shell 输出里取出两个标记之间的内容；标记不成对视为失败。
    static func extract(_ output: String, marker: String) -> String? {
        let parts = output.components(separatedBy: marker)
        guard parts.count >= 3 else { return nil }
        return parts[1]
    }

    /// `a:b::a` → `[a, b]`：去空、去重、保序。
    static func parse(_ path: String) -> [String] {
        var seen = Set<String>()
        return path.split(separator: ":").map(String.init)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
