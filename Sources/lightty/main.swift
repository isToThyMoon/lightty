import AppKit
import Darwin
import GhosttyKit

// 抬高本进程的打开文件数上限（RLIMIT_NOFILE）。macOS 下 GUI 应用默认软限只有 256，
// 每个 pane 的 shell 与其子进程（codex / claude）都继承这个软限；恢复时多个 agent
// 同时启动、各自读一堆 skill 文件，很快就 EMFILE（"Too many open files"）。上游
// Ghostty 在自己的 main 里做（os/file.zig fixMaxFiles），但 lightty 用的是自己的
// main，必须在这里补上，且要在任何 surface / 子进程 spawn 之前。
func raiseOpenFileLimit() {
    // RLIM_INFINITY 是 C 宏，Swift 导不进来；按 <sys/resource.h> 定义手写：(1<<63)-1。
    let infinity = rlim_t(1) << 63 - 1
    var limit = rlimit()
    guard getrlimit(RLIMIT_NOFILE, &limit) == 0, limit.rlim_cur < limit.rlim_max else { return }
    if limit.rlim_max != infinity {
        limit.rlim_cur = limit.rlim_max
        _ = setrlimit(RLIMIT_NOFILE, &limit)
        return
    }
    // 硬限无上界：二分找内核实际接受的最大软限（受 kern.maxfilesperproc 约束）。
    var low = limit.rlim_cur
    var high: rlim_t = 1 << 20
    while low + 1 < high {
        var trial = limit
        trial.rlim_cur = low + (high - low) / 2
        if setrlimit(RLIMIT_NOFILE, &trial) == 0 { low = trial.rlim_cur } else { high = trial.rlim_cur }
    }
}
raiseOpenFileLimit()

// Must precede FilePreferences.shared, AppDelegate, workspace restoration and all terminals.
// The optional diagnostic flag uses this same startup gate without opening the GUI.
let migrationOnly = CommandLine.arguments.contains("--migrate-data")
do {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lightty")
    let backup = try UserDataMigration.run(in: root, hasOtherInstance: {
        NSWorkspace.shared.runningApplications.contains(where: {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && $0.executableURL?.lastPathComponent == "lightty"
        })
    })
    if migrationOnly {
        print(backup.map { "Data upgraded. Backup: \($0.path)" } ?? "Data already uses the current format.")
        exit(EXIT_SUCCESS)
    }
} catch {
    fputs("Data upgrade failed: \(error.localizedDescription)\n", stderr)
    if !migrationOnly {
        let app = NSApplication.shared
        AppBranding.install(on: app)
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        // Do not use L(): app language preferences must not be read before migration.
        let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
        let alert = AppBranding.makeAlert()
        alert.alertStyle = .critical
        alert.messageText = chinese ? "无法升级 lightty 数据" : "Could not upgrade lightty data"
        alert.informativeText = (chinese
            ? "应用尚未打开任何终端。原文件或升级前备份已保留在 ~/.lightty/。请解决以下问题后重新打开：\n\n"
            : "No terminals were opened. Original files or pre-upgrade backups remain in ~/.lightty/. Resolve the issue and reopen:\n\n")
            + error.localizedDescription
        alert.addButton(withTitle: chinese ? "退出" : "Quit")
        alert.runModal()
    }
    exit(EXIT_FAILURE)
}

// 冒烟锚点：真实调用符号，防 SwiftPM 空链接假报 Build complete
// （docs/libghostty-embedding.md 链接契约）
let info = ghostty_info()

// 环境净化：lightty 若被别的 agent/终端拉起（开发期常见），会继承其会话标记并
// 传给每个 pane 的 shell——Claude Code 会因 CLAUDE_CODE_CHILD_SESSION 把 pane 里
// 的会话当嵌套子会话（关 transcript 等）。终端 app 应给用户干净的登录环境，
// 与 Finder 启动对齐。必须在首个 surface spawn 之前执行。
for key in ["CLAUDE_CODE_CHILD_SESSION", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT",
            "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_BRIDGE_SESSION_ID",
            "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_EXECPATH",
            "CLAUDE_PID", "CLAUDE_EFFORT"] {
    unsetenv(key)
}

if CommandLine.arguments.contains("--print-effective-terminal-config") {
    GhosttyRuntime.shared = GhosttyRuntime()
    print(GhosttyRuntime.shared.terminalConfigProbe)
    exit(EXIT_SUCCESS)
}

let app = NSApplication.shared
AppBranding.install(on: app)
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
