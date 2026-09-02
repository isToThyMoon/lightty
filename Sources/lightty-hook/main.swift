import Foundation
import LighttyCore

// lightty-hook —— agent（claude / codex）的 hook 事件 → lightty 的状态 socket
//
// 契约见 docs/specs/pane-status.md §4 / §6 S2 / §8。三条硬约束：
//
// 1. **只链 Foundation + LighttyCore**。PreToolUse 每次工具调用都触发一次进程，
//    启动开销直接变成用户 agent 的延迟税。
// 2. **永不吵闹、永不阻塞**。stdin 读不到、JSON 烂、socket 发不出去——一律静默 exit 0。
//    坏掉的 hook 阻塞或刷屏用户会话，比没有状态可视化糟糕得多。
//    SOCK_DGRAM 的每一种失败都是即时返回的（ENOENT / ECONNREFUSED / ENOBUFS，
//    实测均在 25µs 内），所以「不阻塞」是传输层保证的，不是靠我们小心。
// 3. **不在 lightty 里跑就当自己不存在**：LIGHTTY_PANE_ID / LIGHTTY_SOCK 任一未设时
//    零输出、零副作用。用户很可能在 lightty 之外也跑同一个 agent，那时 hook 必须完全隐形。

// MARK: - 事件映射

/// hook 事件名 → pane 状态（§4.3）。事件 key 是 PascalCase，两家一致。
/// 不认识的事件返回 nil：agent 随时可能加新事件，静默跳过才是向前兼容的做法。
private func activity(for event: String) -> PaneActivity? {
    switch event {
    case "SessionStart", "SessionEnd": return .idle
    case "UserPromptSubmit", "PostToolUse": return .thinking
    case "PreToolUse": return .tool
    case "Notification", "PermissionRequest": return .attention
    case "Stop": return .done
    default: return nil
    }
}

// MARK: - payload 取值

/// 取非空字符串。空串和纯空白当作「没有」——写进报文只会污染 UI。
private func string(_ value: Any?) -> String? {
    guard let raw = value as? String else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// tool_input 里按优先级找一个「人一眼能看懂」的字段。两家 agent 的工具参数名
/// 大体同源，覆盖不到就返回 nil——宁可没有 detail，也不把原始 JSON 倒进报文。
private let detailKeys = [
    "file_path", "path", "notebook_path", "command", "pattern", "url", "query", "description",
]

private func detail(from toolInput: Any?) -> String? {
    guard let dict = toolInput as? [String: Any] else { return nil }
    for key in detailKeys {
        if let raw = string(dict[key]) { return summarize(raw) }
    }
    return nil
}

/// 压成单行并截断。读方（§4.2）也会截断，但写方先截是硬要求：
/// 一条 bash 命令可能有几 KB，而报文有 4KB 上限、这个字段只够显示一行。
private func summarize(_ raw: String, limit: Int = 80) -> String {
    let flat = raw.split(whereSeparator: \.isNewline).joined(separator: " ")
    guard flat.count > limit else { return flat }
    // 路径的信息量在尾部（文件名），命令/描述在头部
    if flat.contains("/") { return "…" + String(flat.suffix(limit - 1)) }
    return String(flat.prefix(limit - 1)) + "…"
}

/// 尽力而为地认 agent：hook 子进程继承 agent 自己设的环境变量。
/// 认不出就留空——`agent` 是可选字段，猜错比留空更糟。
private func detectAgent(payload: [String: Any]) -> String? {
    let env = ProcessInfo.processInfo.environment
    if env["CLAUDECODE"] != nil || env["CLAUDE_CODE_ENTRYPOINT"] != nil { return "claude" }
    if env["CODEX_HOME"] != nil || env["CODEX_SANDBOX"] != nil { return "codex" }
    // Claude Code 独有的 payload 字段，作为环境变量之外的兜底
    if payload["transcript_path"] != nil { return "claude" }
    return nil
}

// MARK: - handoff 注入（§8）

/// hook 输出 wire：两家 agent 完全相同的 `hookSpecificOutput` 结构。
private struct HookOutput: Encodable {
    struct Specific: Encodable {
        let hookEventName: String
        let additionalContext: String
    }
    let hookSpecificOutput: Specific
}

/// pane 当前绑定的任务文件路径。没绑 / 指针读不到 → nil。
private func boundTaskPath(paneID: String) -> String? {
    let pointer = PaneRuntimeDirectory.taskPointerFile(for: paneID)
    guard let raw = try? String(contentsOf: pointer, encoding: .utf8) else { return nil }
    let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? nil : path
}

/// 去重标记的读写。标记内容 `<session>\n<path>`；session 没给就存空行。
private struct HandoffMarker: Equatable {
    let session: String
    let path: String

    static func read(paneID: String) -> HandoffMarker? {
        let file = PaneRuntimeDirectory.handoffMarkerFile(for: paneID)
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2 else { return nil }
        return HandoffMarker(session: lines[0], path: lines[1])
    }

    /// 尽力而为：写不成（目录没了）下次多注一遍而已，比让 agent 缺上下文好。
    func write(paneID: String) {
        try? PaneRuntimeDirectory.atomicWrite(
            Data("\(session)\n\(path)\n".utf8),
            to: PaneRuntimeDirectory.handoffMarkerFile(for: paneID))
    }
}

/// 这一发要不要注入 handoff。
///
/// - `SessionStart`：绑了就注，无条件——新会话对之前注过什么一无所知。
/// - `UserPromptSubmit`：绑了、且（会话, 路径）与上次注入的不同才注。这补的是
///   「先开 agent 再绑任务 / 新建任务 / 改名」这些晚于开场的绑定变化；
///   改名会换路径，重注是对的——agent 需要知道新的回写地址。
/// - 其他事件：不注。
private func handoffToInject(event: String, paneID: String, sessionID: String?) -> String? {
    guard let path = boundTaskPath(paneID: paneID) else { return nil }
    let marker = HandoffMarker(session: sessionID ?? "", path: path)
    switch event {
    case "SessionStart":
        break
    case "UserPromptSubmit":
        guard HandoffMarker.read(paneID: paneID) != marker else { return nil }
    default:
        return nil
    }
    guard let context = handoffContext(path: path, lateBinding: event != "SessionStart")
    else { return nil }
    marker.write(paneID: paneID)
    return context
}

/// 把任务文件拼成注入的上下文。文件读不到 → nil（不注入，也不报错）。
///
/// 框架文本固定英文：这是跨会话的协议语言，与界面语言无关
/// （同 Sources/lightty/Localization.swift 的边界说明）。
private func handoffContext(path: String, lateBinding: Bool) -> String? {
    guard let body = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }

    let opener = lateBinding
        ? "This terminal pane has just been bound to a task in lightty (or its binding changed), and"
        : "This terminal pane is bound to a task in lightty, and"

    return """
        \(opener) the handoff document below is that \
        task's running record, left by the previous sessions at `\(path)`.

        Read it before doing anything else: continue from its "Next steps" section, and treat \
        "Key decisions & constraints" as reference material rather than work to redo. When this \
        session's work is done, write the updated handoff back to that same absolute path \
        (`\(path)`): rewrite only the body after the frontmatter terminator, refresh `updated` in \
        the frontmatter, and write a temp file in the same directory then mv it over the target.

        ----- BEGIN HANDOFF DOCUMENT -----
        \(body)
        ----- END HANDOFF DOCUMENT -----
        """
}

// MARK: - 主流程

// 不在 lightty 的 pane 里 → 彻底隐形。两个变量由 PaneView 在 spawn 时注入，
// 沿 shell → agent → hook 子进程继承。
//
// paneID 必须解析成 UUID：它既是报文的路由字段，又会拼进 handoff 指针的文件路径。
// 值来自 lightty 自己，但 hook 是用户配置里的一条命令行，环境变量随时可能被手工
// 改成别的东西——UUID 解析同时兜住了「路由不认识」和「路径穿越」两种脏值。
let environment = ProcessInfo.processInfo.environment
guard let paneID = string(environment["LIGHTTY_PANE_ID"]),
      let paneUUID = UUID(uuidString: paneID),
      let socketPath = string(environment["LIGHTTY_SOCK"])
else { exit(0) }

// readToEnd 抛 Swift 错误（readDataToEndOfFile 抛的是 NSException，Swift 侧接不住）
guard let input = try? FileHandle.standardInput.readToEnd(), !input.isEmpty,
      let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
      let event = string(payload["hook_event_name"]),
      let state = activity(for: event)
else { exit(0) }

let status = PaneStatus(
    ts: Date(),
    state: state,
    agent: detectAgent(payload: payload),
    sessionID: string(payload["session_id"]),
    tool: string(payload["tool_name"]),
    // detail 只在 PreToolUse 给：那一刻「在干什么」才有信息量，
    // PostToolUse 的同一份参数只是回声
    detail: event == "PreToolUse" ? detail(from: payload["tool_input"]) : nil,
    cwd: string(payload["cwd"])
)

// 一发即走。返回值刻意丢弃：lightty 没在跑（ENOENT）、残留 socket（ECONNREFUSED）、
// 收方卡住（ENOBUFS）都不是 hook 该处理的事——没人看状态而已，agent 照跑。
// 不重试、不写 stderr：重试只会把不确定的延迟加到用户的每次工具调用上。
PaneStatusDatagram(pane: paneUUID, status: status).send(to: URL(fileURLWithPath: socketPath))

// handoff 注入：SessionStart 开场注一次；UserPromptSubmit 补「开场之后才绑定」的情况。
// 其余事件不输出任何东西——hook 的沉默就是「一切照常」。
if let context = handoffToInject(event: event, paneID: paneID, sessionID: status.sessionID) {
    let output = HookOutput(
        hookSpecificOutput: .init(hookEventName: event, additionalContext: context))
    // 必须走 JSONEncoder：正文是任意 markdown，手拼字符串迟早炸在引号/换行上
    if let json = try? JSONEncoder().encode(output) {
        FileHandle.standardOutput.write(json)
    }
}

exit(0)
