import AppKit
import GhosttyKit

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
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        // Do not use L(): app language preferences must not be read before migration.
        let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
        let alert = NSAlert()
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
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
