import Foundation
import LighttyCore
import Darwin

/// Positive evidence only. No match is unknown, not proof that native resume will succeed.
/// Never opens a transcript, takes a lock, or signals an Agent.
///
/// 两家的证据来源不一样，因为它们提供的东西不一样：
///
/// - **Claude** 自己维护着一张活会话表，`claude agents --json` 就是给脚本读的
///   （帮助里写着 "for scripting; does not require a TTY"）。它直接给出 pid 与
///   sessionId 的对应关系，是这个问题的正面答案。
/// - **Codex** 没有对等的东西：`codex agents` 要先有一个共用的后台服务，而 lightty
///   是直接在终端里跑 codex，不连那个服务；不连的话 `thread/list` 里每一条都是
///   「未加载」。所以 codex 只能退回读操作系统的文件表，靠会话记录文件的文件名反推。
///
/// 读文件表这条路对两家都留着：Claude 那条命令可能因为版本旧、输出改格式而失败，
/// 失败时不该把「问不出来」当成「没人用」。
///
/// 这里只放两家共用的文件表读取与解析。哪些目录算会话记录、文件名怎么对应会话，
/// 以及 Claude 的活会话表，归各自的 provider adapter。
enum SessionOccupancy {
    enum Result: Equatable { case inUse(pid: Int32), unknown }

    /// 当前用户名下、进程名为 `command` 的进程打开的文件表（`lsof -F` 字段输出）。
    /// 命令失败返回 nil（「问不出来」）。
    static func openFiles(command: String, timeout: TimeInterval) -> Data? {
        try? SessionHelperProcess.readPage(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-n", "-P", "-b", "-a", "-u", String(getuid()), "-c", command, "-F0pcfan"],
            directory: URL(fileURLWithPath: "/"), environment: ["PATH": "/usr/bin:/bin"],
            cancelled: { false }, timeout: timeout, maximumBytes: 4 * 1024 * 1024)
    }

    /// lsof field output is NUL-delimited, with a newline separating process/file sets.
    /// Keep parsing separate so paths, access modes and partial output are fixture-testable.
    ///
    /// 只认**可写打开的会话记录文件**：命令名对得上、描述符是数字、访问模式是 u/w，
    /// 路径落在来源根下的 `directories` 之一。只读打开不算证据——别的工具也会读它。
    static func forEachWritableSessionFile(
        _ data: Data, command expected: String, root: String, directories: [String],
        body: (_ pid: Int32, _ name: String) -> Void
    ) {
        let root = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        var pid: Int32?
        var command = ""
        var descriptor = ""
        var access = ""
        for field in String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: true) {
            let field = field.drop(while: { $0 == "\n" })
            guard let tag = field.first else { continue }
            let value = String(field.dropFirst())
            switch tag {
            case "p": pid = Int32(value); command = ""; descriptor = ""; access = ""
            case "c": command = value
            case "f": descriptor = value; access = ""
            case "a": access = value
            case "n":
                guard let pid, pid > 0, command == expected,
                      Int(descriptor) != nil, access == "u" || access == "w",
                      value.hasPrefix("/") else { continue }
                let path = URL(fileURLWithPath: value).standardizedFileURL.path
                guard directories.contains(where: { path.hasPrefix(root + "/" + $0 + "/") }) else { continue }
                body(pid, URL(fileURLWithPath: path).lastPathComponent)
            default: break
            }
        }
    }

    /// 文件表里第一个可写打开了 `matches` 文件的进程。
    static func firstWriter(_ data: Data, command: String, root: String, directories: [String],
                            matches: (_ fileName: String) -> Bool) -> Result {
        var found: Int32?
        forEachWritableSessionFile(data, command: command, root: root, directories: directories) { pid, name in
            if found == nil, matches(name) { found = pid }
        }
        return found.map { Result.inUse(pid: $0) } ?? .unknown
    }
}
