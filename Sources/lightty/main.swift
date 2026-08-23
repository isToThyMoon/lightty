import AppKit
import GhosttyKit

// 冒烟锚点：真实调用符号，防 SwiftPM 空链接假报 Build complete
// （docs/libghostty-embedding.md 链接契约）
let info = ghostty_info()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
