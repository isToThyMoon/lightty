import Foundation

/// pane 运行时目录：lightty 与 agent hook 之间的唯一交换区。
///
/// 布局（见 docs/specs/pane-status.md §4.1）：
/// ```
/// ~/.lightty/panes/<pane-uuid>/
///     owner.pid     ← lightty 写：宿主进程 pid，供 sweepStale 判活
///     task          ← lightty 写，hook 读（handoff 注入用，一行绝对路径）
///     handoff.injected ← hook 写：上次注入的 <session_id>\n<path>，用于去重
/// ~/.lightty/run/
///     <lightty-pid>.sock  ← lightty bind，hook sendto（实时状态）
/// ```
///
/// 两条通路的分工是刻意的：**持久的走文件，易失的走 socket**。
/// handoff 指针要跨进程、跨重启地活着，文件是对的；活动状态用完即弃，
/// 用文件当「可变槽位」反而会在主线程忙时把中间态整个丢掉（实测 200 发只到 47 发）。
///
/// 主 app 与 lightty-hook 两个可执行文件共用本类型，路径约定只此一处。
public enum PaneRuntimeDirectory {
    /// `~/.lightty/panes`
    public static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lightty/panes", isDirectory: true)
    }

    public static func directory(for paneID: String) -> URL {
        root.appendingPathComponent(paneID, isDirectory: true)
    }

    /// handoff 指针：内容是任务文件的绝对路径（单行，可含尾随换行）
    public static func taskPointerFile(for paneID: String) -> URL {
        directory(for: paneID).appendingPathComponent("task")
    }

    public static func ownerPIDFile(for paneID: String) -> URL {
        directory(for: paneID).appendingPathComponent("owner.pid")
    }

    /// handoff 去重标记：hook 上次把哪个任务文件注入给了哪个会话。
    ///
    /// 注入不只发生在 `SessionStart`——用户完全可能先开 agent 再绑任务（或新建、
    /// 改名），所以 `UserPromptSubmit` 也要查指针。没有这个标记，每次提问都会
    /// 把整篇 handoff 再塞一遍。内容两行：`<session_id>` 和 `<path>`，任一变了才重注。
    public static func handoffMarkerFile(for paneID: String) -> URL {
        directory(for: paneID).appendingPathComponent("handoff.injected")
    }

    // MARK: - 状态 socket

    /// `~/.lightty/run/` —— 每个 lightty 实例一个 datagram socket。
    public static var runDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lightty/run", isDirectory: true)
    }

    /// `~/.lightty/run/<pid>.sock`。
    ///
    /// 按 pid 命名而不是共用一个固定路径：多实例时各绑各的，没有 EADDRINUSE 探测、
    /// 没有第二个实例 unlink 掉第一个的孤儿化。pane 的 shell 在 spawn 时就拿到
    /// 自己实例的路径（LIGHTTY_SOCK），hook 天然知道该发给谁。
    /// sun_path 上限 104 字节，这个形状约 40 字节，余量充足。
    public static func socketPath(for pid: pid_t = getpid()) -> URL {
        runDirectory.appendingPathComponent("\(pid).sock")
    }

    // MARK: - 生命周期

    /// 建目录并落 owner.pid。pane 创建时调用；已存在则只刷新 pid。
    public static func create(paneID: String, ownerPID: pid_t = getpid()) throws {
        let dir = directory(for: paneID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try atomicWrite(Data("\(ownerPID)\n".utf8), to: ownerPIDFile(for: paneID))
    }

    /// pane 关闭时调用。失败静默——残留交给 sweepStale。
    public static func destroy(paneID: String) {
        try? FileManager.default.removeItem(at: directory(for: paneID))
    }

    /// 清理宿主进程已死的残留目录（崩溃/强杀后重启会走到这里）。
    ///
    /// 按 owner.pid 判活而不是「启动时清空整个 panes/」，是为了兼容多实例 lightty：
    /// 另一个实例的 pane 目录不能被误删。
    public static func sweepStale() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return }

        for dir in entries {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            let paneID = dir.lastPathComponent
            guard let raw = try? String(contentsOf: ownerPIDFile(for: paneID), encoding: .utf8),
                  let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            else {
                // 没有 owner.pid 的目录来路不明，一并清掉
                try? fm.removeItem(at: dir)
                continue
            }
            // kill(pid, 0)：只做存在性与权限探测，不发信号
            if kill(pid, 0) != 0 && errno == ESRCH {
                try? fm.removeItem(at: dir)
            }
        }
    }

    /// 清理宿主进程已死的残留 socket 文件。
    ///
    /// bind 过的 Unix socket 不会随进程消失——`kill -9` 之后文件还在，而往它发包会
    /// 收到 ECONNREFUSED（实测 22µs）。功能上无害（发方本来就忽略所有错误），
    /// 但没人收拾就会在 `run/` 里越积越多。判活方式与 `sweepStale` 一致：
    /// 文件名就是 pid，`kill(pid, 0)` 报 ESRCH 才删——另一个 lightty 实例的 socket 不能误删。
    public static func sweepStaleSockets() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: runDirectory, includingPropertiesForKeys: nil) else { return }

        for file in entries where file.pathExtension == "sock" {
            guard let pid = pid_t(file.deletingPathExtension().lastPathComponent) else {
                // 不是 <pid>.sock 形状的东西不归我们管，留着
                continue
            }
            if kill(pid, 0) != 0 && errno == ESRCH {
                try? fm.removeItem(at: file)
            }
        }
    }

    // MARK: - 原子写

    /// 同目录临时文件 + rename(2)。
    ///
    /// **这不是风格偏好**：读方（hook 子进程）随时可能在写到一半时打开这个文件，
    /// rename 保证它要么读到旧的完整内容、要么读到新的完整内容，没有半截状态。
    /// 与 TaskStore.atomicWrite 同约定。
    public static func atomicWrite(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        if Darwin.rename(tmp.path, url.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: tmp)
            throw PaneRuntimeError.atomicRenameFailed(path: url.path, errno: code)
        }
    }
}

public enum PaneRuntimeError: Error {
    case atomicRenameFailed(path: String, errno: Int32)
}
