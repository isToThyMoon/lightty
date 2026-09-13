import Darwin
import Foundation
import LighttyCore

/// 开着的会话被改名时发信号：盯住 agent 改名会写的那几个文件（见
/// `AgentSessionProvider.titleSignalFiles`），一变就回调这段会话的身份。
///
/// 为什么需要：用户在终端里自己敲 `/rename` 不触发任何钩子，而元数据只在钩子或
/// lightty 自己发起的操作之后才重读，于是两个侧栏和 pane 标题都停在旧名上，要等下一轮
/// 对话结束或手动刷新。文件只当信号，标题照旧由 `SessionLibrary` 从官方列表读。
///
/// 只在主线程调用。找文件会读目录，放在后台队列；监听回调也回到主线程。
final class SessionTitleSignals {
    private struct Watch {
        let file: URL
        let inode: ino_t?
        let token: AnyObject
    }

    private let changes: PathChangeSource
    private let onSignal: (AgentSessionKey) -> Void
    private let queue = DispatchQueue(label: "lightty.session-title-signals")
    private var wanted = Set<AgentSessionKey>()
    private var watching: [AgentSessionKey: [Watch]] = [:]
    private var resolving = Set<AgentSessionKey>()

    init(changes: @escaping PathChangeSource, onSignal: @escaping (AgentSessionKey) -> Void) {
        self.changes = changes
        self.onSignal = onSignal
    }

    /// 让被监听的会话与 `keys` 一致。还没找到文件的会话每次调用都再找一次——新会话要等
    /// 第一条记录写下才有文件，调用方在钩子到达时调用，正好赶上。
    func watch(_ keys: Set<AgentSessionKey>, provider: (SessionAgent) -> AgentSessionProvider?) {
        wanted = keys
        for key in watching.keys where !keys.contains(key) { watching.removeValue(forKey: key) }
        for key in keys where watching[key] == nil && !resolving.contains(key) {
            guard let provider = provider(key.agent) else { continue }
            resolve(key, with: provider)
        }
    }

    private func resolve(_ key: AgentSessionKey, with provider: AgentSessionProvider) {
        resolving.insert(key)
        queue.async { [weak self] in
            let files = provider.titleSignalFiles(for: key)
            DispatchQueue.main.async {
                guard let self else { return }
                self.resolving.remove(key)
                guard self.wanted.contains(key), self.watching[key] == nil else { return }
                let watches = files.compactMap { file -> Watch? in
                    let inode = Self.inode(of: file)
                    guard let token = try? self.changes(file, { [weak self] in
                        DispatchQueue.main.async { self?.fire(key, provider: provider) }
                    }) else { return nil }
                    return Watch(file: file, inode: inode, token: token)
                }
                if !watches.isEmpty { self.watching[key] = watches }
            }
        }
    }

    /// 文件被「临时文件 + rename」替换过，旧监听就挂在旧 inode 上、以后收不到了，
    /// 这时丢掉重找。只比 inode，不每次都重扫目录：Claude 一轮对话里记录文件写个不停。
    private func fire(_ key: AgentSessionKey, provider: AgentSessionProvider) {
        guard wanted.contains(key), let watches = watching[key] else { return }
        if watches.contains(where: { Self.inode(of: $0.file) != $0.inode }) {
            watching.removeValue(forKey: key)
            resolve(key, with: provider)
        }
        onSignal(key)
    }

    private static func inode(of file: URL) -> ino_t? {
        var info = stat()
        return stat(file.path, &info) == 0 ? info.st_ino : nil
    }
}
