import Foundation
@testable import lightty

/// 测试进程里唯一的终端运行时入口。
///
/// 放进窗口的 pane 会真实 spawn `login → shell`，测试环境对此有两处不友好：
///
/// - 卡死：所有 surface 发给 app 的消息共用一个 64 格邮箱，只有主线程 tick 才会取走。
///   测试主线程很少转 runloop，又留着几十个没释放的 surface，邮箱常年是满的；读 pty
///   的线程于是停着。这时释放一个跑着 zsh 的 surface，`ghostty_surface_free` 发 SIGHUP
///   后同步等 login 退出，而 login 退出要等终端输出被读完，zsh 也卡在内核的 `setpgid`
///   里——主线程永久挂住。真实应用主线程一直在 tick，碰不到这条边界。
/// - 孤儿：pane 没释放就到了进程退出，内核关 pty 时还没初始化完的 zsh 会永久卡在
///   `init_io` 的 `open()` 上，成为挂在 launchd 下的孤儿。
///
/// 所以测试里的 pane 进窗口时默认**不建 surface**（`TerminalTestShell.spawnsSurfaces`），
/// 绝大多数测试只拿装在窗口里的 pane 当布局/状态载体；确实要 pty 的测试再打开。
/// 打开后终端也不跑交互 shell，而是跑一个不输出的 `cat`（见 `TerminalTestShell`）；
/// 退出前再把剩下的子进程收掉。
@MainActor
func ensureTerminalRuntime() {
    guard GhosttyRuntime.shared == nil else { return }
    TerminalTestShell.install()
    TerminalTestShell.spawnsSurfaces = false
    GhosttyRuntime.shared = GhosttyRuntime()
    atexit { reapTerminalShells() }
}

/// 测试进程的 `SHELL` 指向这里生成的包装脚本。ghostty 在命令行环境下拿 `SHELL` 当终端命令，
/// 并且之后每次重载配置都会重新读，所以只能整个进程一直指着它。
///
/// 脚本名就叫 `zsh`，ghostty 照常注入 zsh 的 shell 集成。带参数的调用（如 `LoginShellPath`
/// 的 `-ilc`）原样交给真 zsh；ghostty 起终端时不带参数，默认跑 `cat`，只有测试明确要真
/// shell 时才起登录 zsh。
@MainActor
enum TerminalTestShell {
    private static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("lightty-test-shell-\(getpid())")
    private static let realShellMarker = directory.appendingPathComponent("real-shell")

    /// 之后进窗口的 pane 是否真的创建 ghostty surface（spawn 终端进程、起渲染/IO 线程）。
    /// 默认关：只有要 pty 的测试（环境变量到 shell、启动命令真执行、进程退出……）
    /// 才打开，用完必须复原。已经装进窗口的 pane 不受影响。
    static var spawnsSurfaces: Bool {
        get { TerminalSurfaceView.spawnsSurfaces }
        set { TerminalSurfaceView.spawnsSurfaces = newValue }
    }

    /// 之后新建的终端是否跑真实的登录 zsh。已经起来的终端不受影响。只在
    /// `spawnsSurfaces` 打开时才有意义。
    static var usesRealShell: Bool {
        get { FileManager.default.fileExists(atPath: realShellMarker.path) }
        set {
            if newValue {
                FileManager.default.createFile(atPath: realShellMarker.path, contents: nil)
            } else {
                try? FileManager.default.removeItem(at: realShellMarker)
            }
        }
    }

    fileprivate static func install() {
        let script = directory.appendingPathComponent("zsh")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let body = """
            #!/bin/bash
            if [ $# -gt 0 ]; then exec /bin/zsh "$@"; fi
            if [ -e '\(realShellMarker.path)' ]; then exec -a -zsh /bin/zsh; fi
            exec /bin/cat
            """
        FileManager.default.createFile(atPath: script.path, contents: Data((body + "\n").utf8),
                                       attributes: [.posixPermissions: 0o755])
        setenv("SHELL", script.path, 1)
        let path = directory.path
        atexit_b { try? FileManager.default.removeItem(atPath: path) }
    }
}

/// 退出时有的子进程还没 exec 成 `login`，之后才会再 fork 出 shell，所以扫一遍不够，
/// 要一直收割到子进程清空。还没 exec 的直接杀；已经是 `login` 的是 setuid root 杀不动，
/// 就杀它名下属于我们的 shell，login 随即自行退出。设上限，别让退出卡死。
private func reapTerminalShells() {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        let children = childPIDs(of: getpid())
        if children.isEmpty { return }
        for child in children {
            kill(child, SIGKILL)
            for shell in childPIDs(of: child) { kill(shell, SIGKILL) }
            waitpid(child, nil, WNOHANG)
        }
        usleep(10_000)
    }
}

private func childPIDs(of pid: pid_t) -> [pid_t] {
    var pids = [pid_t](repeating: 0, count: 1024)
    let count = pids.withUnsafeMutableBytes {
        proc_listchildpids(pid, $0.baseAddress, Int32($0.count))
    }
    return Array(pids.prefix(Int(max(count, 0))))
}
