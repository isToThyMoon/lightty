import AppKit
import GhosttyKit

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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
