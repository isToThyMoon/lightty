import Foundation

/// 一家 agent 经 OSC 0 写进终端标题的**形状**——纯数据，值在各家的 `AgentSpec` 里。
///
/// 两家都把状态写进了标题（实测 Claude Code 2.1.274、Codex 0.154.0）：
/// - Claude Code：`<前缀> <会话标题>`，回合进行中 ◐ ◑ 轮换，不忙时 ✳；改名即推送。
/// - Codex：`<旋转字符> <线程名> | <项目名>`，工作中前缀是 braille 旋转字符，空闲时没有前缀，
///   等用户处理时整行以 `[ ! ] Action Required` 开头（`tui.terminal_title` 可配，这是默认项）。
///
/// 这是**推送式的终端协议**（和 OSC 7 报 cwd 一样）：零成本、零延迟，用户按 Esc 中断的那一刻
/// 就变，而 hook 侧 Claude 的 `Stop` 跳过用户中断、没有对等事件。
///
/// **这些字符是上游 UI 的细节，随时可能换。** 所以字符只写在各家 `Agent.swift` 的
/// `terminalTitle` 一处，这里不含任何字符常量；解析不出来一律返回 nil，读方退回只靠 hook
/// ——换字符的后果是回到没有这条通道的行为，不是认错状态。上游改了就改那一行，
/// 核对方法见各家文件里记的源码位置。
public struct TerminalTitleShape: Equatable, Sendable {
    /// 表示回合进行中的首字符，后面跟一个空格
    public let busyPrefixes: Set<Character>
    /// 表示不忙的首字符，后面跟一个空格或结尾
    public let settledPrefixes: Set<Character>
    /// 表示等用户处理的整段开头
    public let attentionPrefixes: [String]
    /// 没有任何前缀、且以字母或数字开头的标题算不算「不忙」。Claude 总带前缀（没前缀的
    /// 不是它写的）；Codex 空闲时就是没前缀。以别的符号开头的标题**两家都不认**：那多半是
    /// 上游换了旋转字符，认成闲会把正在跑的回合显示成空闲，不认只是退回 hook。
    public let bareTitleIsSettled: Bool

    public init(busyPrefixes: Set<Character>, settledPrefixes: Set<Character>,
                attentionPrefixes: [String], bareTitleIsSettled: Bool) {
        self.busyPrefixes = busyPrefixes
        self.settledPrefixes = settledPrefixes
        self.attentionPrefixes = attentionPrefixes
        self.bareTitleIsSettled = bareTitleIsSettled
    }
}

/// 解析出来的一条标题：状态 + 正文。
public struct AgentTerminalTitle: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// 回合进行中
        case busy
        /// 停在提示符上。Claude 等用户处理对话框时也是这个（它的标题分不开）
        case settled
        /// 等用户处理
        case attention
    }

    public let phase: Phase
    /// 前缀之后的正文，已去首尾空白。Claude 是会话标题；Codex 是 `线程名 | 项目名`。
    /// 读方只拿它判断「变没变」，标题的真值仍在各家的官方目录里。
    public let body: String
    /// 是靠前缀认出来的（而不是「没前缀即闲」那条兜底）。只有这种形状能证明标题是这家写的；
    /// 没有 hook 登记 agent 时，靠它判断 pane 里在跑的是谁。
    public let recognizedByPrefix: Bool

    public init(phase: Phase, body: String, recognizedByPrefix: Bool = true) {
        self.phase = phase
        self.body = body
        self.recognizedByPrefix = recognizedByPrefix
    }

    /// 按这家的形状解析；不是它写的形状 → nil，读方不动状态。
    /// 这家改了格式也只是回到「只靠 hook」的行为，不会认错。
    public static func parse(_ title: String, shape: TerminalTitleShape) -> AgentTerminalTitle? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        for prefix in shape.attentionPrefixes where trimmed.hasPrefix(prefix) {
            return AgentTerminalTitle(phase: .attention, body: body(after: prefix.count, in: trimmed))
        }
        guard let first = trimmed.first else { return nil }
        let phase: Phase
        if shape.busyPrefixes.contains(first) { phase = .busy }
        else if shape.settledPrefixes.contains(first) { phase = .settled }
        else { return bare(trimmed, shape: shape) }
        // 前缀后面必须是空格或结尾：`✳foo` 是别的程序碰巧以同一个字符开头
        let rest = trimmed.dropFirst()
        guard rest.isEmpty || rest.first == " " else { return bare(trimmed, shape: shape) }
        return AgentTerminalTitle(phase: phase, body: body(after: 1, in: trimmed))
    }

    /// 没有已知前缀的标题：只有这家「无前缀即闲」、且以字母或数字开头时才认；
    /// 以未知符号开头的宁可不认（见 `TerminalTitleShape.bareTitleIsSettled`）。
    private static func bare(_ title: String, shape: TerminalTitleShape) -> AgentTerminalTitle? {
        guard shape.bareTitleIsSettled, let first = title.first, first.isLetter || first.isNumber else { return nil }
        return AgentTerminalTitle(phase: .settled, body: title, recognizedByPrefix: false)
    }

    private static func body(after count: Int, in title: String) -> String {
        var rest = title.dropFirst(count).trimmingCharacters(in: .whitespaces)
        // Codex 在 `[ ! ] Action Required` 后面用 ` | ` 接其余各项
        if rest.hasPrefix("| ") { rest = String(rest.dropFirst(2)) }
        return rest
    }
}
