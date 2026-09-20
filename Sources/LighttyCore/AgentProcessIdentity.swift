import Foundation
import Darwin

/// Runtime-only identity. PID alone is unsafe because the OS reuses it.
public struct AgentProcessIdentity: Codable, Equatable, Hashable, Sendable {
    public let pid: Int32
    public let startedSeconds: UInt64
    public let startedMicroseconds: UInt64

    public init(pid: Int32, startedSeconds: UInt64, startedMicroseconds: UInt64) {
        self.pid = pid
        self.startedSeconds = startedSeconds
        self.startedMicroseconds = startedMicroseconds
    }

    public static func read(_ pid: Int32) -> Self? {
        guard let info = info(pid) else { return nil }
        return Self(pid: pid, startedSeconds: info.pbi_start_tvsec, startedMicroseconds: info.pbi_start_tvusec)
    }

    public enum Liveness { case running, exited, unknown }

    public var liveness: Liveness {
        guard let info = Self.info(pid) else { return errno == ESRCH ? .exited : .unknown }
        guard info.pbi_start_tvsec == startedSeconds, info.pbi_start_tvusec == startedMicroseconds,
              info.pbi_status != SZOMB else { return .exited }
        return .running
    }

    public func startedBefore(_ other: Self) -> Bool {
        (startedSeconds, startedMicroseconds) < (other.startedSeconds, other.startedMicroseconds)
    }

    public static func parent(of pid: Int32) -> Int32? {
        info(pid).map { Int32($0.pbi_ppid) }
    }

    public func isDescendant(of ancestor: Int32) -> Bool {
        var current = pid
        var seen = Set<Int32>()
        for _ in 0..<64 {
            guard current > 1, seen.insert(current).inserted, let parent = Self.parent(of: current) else { return false }
            if parent == ancestor { return true }
            current = parent
        }
        return false
    }

    private static func info(_ pid: Int32) -> proc_bsdinfo? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.stride))
            == MemoryLayout<proc_bsdinfo>.stride else { return nil }
        return info
    }
}

// MARK: - 按终端结构找 agent 进程

extension AgentProcessIdentity {
    /// 祖先链上一个进程的终端结构事实（`kinfo_proc.kp_eproc`），判定要的全部输入。
    /// 刻意不含可执行路径：按名字认 agent 是最后一处随安装方式变化的知识，已经不用了。
    struct TerminalFacts: Equatable, Sendable {
        let pid: Int32
        /// `e_pgid`：进程组。
        let processGroup: Int32
        /// `e_tpgid`：控制终端当前的前台进程组；没有控制终端时无意义。
        let foregroundGroup: Int32
        /// `e_tdev != NODEV`。
        let hasControllingTerminal: Bool

        /// 终端的前台作业组长：自己就是组，且这个组正占着控制终端。
        var isForegroundJobLeader: Bool {
            hasControllingTerminal && pid == processGroup && processGroup == foregroundGroup
        }
    }

    /// hook 父进程链的结构判定。**纯函数**：进程表怎么读是调用方的事。
    ///
    /// 实测（2026-09-16，Claude Code 2.1.274 / Codex 0.154.0，`script` 造 pty）：
    /// 两家的主会话都是终端的前台作业组长（`pid == e_pgid == e_tpgid`、有控制终端）；
    /// 两家的工具子进程（Bash / shell 工具、以及工具里起的 `claude -p`、`codex exec`）
    /// 一律**脱离终端**，前台组为 0。Claude 还把 hook 自己也脱离了终端，Codex 没有——
    /// 所以判定只能从 hook 的**父进程**起算，hook 自身有没有终端不作数。
    ///
    /// - Parameter chain: 从 hook 父进程往上的祖先链，最近的在前。
    /// - Returns: `leader` 是 agent 进程；npm 版 codex 那种 node 包装、用户的启动脚本，
    ///   组长就是最外层的包装进程，监视它退出与监视里面那个原生进程等价。
    ///   `isNested` 表示走到组长之前经过了脱离终端的进程——那就是别的会话从工具里
    ///   拉起的子会话（`claude -p`），它的事件必须丢掉，否则会顶掉主会话的状态与绑定。
    ///   链上找不到组长（hook 跑在没有 pty 的环境里）时返回 `(nil, false)`：
    ///   **不按嵌套处理**，宁可多报一发状态，也不能把主会话的事件丢了。
    static func foregroundJobLeader(in chain: [TerminalFacts]) -> (leader: TerminalFacts?, isNested: Bool) {
        guard let index = chain.firstIndex(where: \.isForegroundJobLeader) else { return (nil, false) }
        return (chain[index], chain[..<index].contains { !$0.hasControllingTerminal })
    }

    /// 结构判定的结果：agent 进程的运行时身份（找不到组长时为 nil）＋ 是不是子会话。
    public struct Ancestry: Equatable, Sendable {
        public let process: AgentProcessIdentity?
        public let isNested: Bool
    }

    /// 从 `pid`（调用方传 hook 的父进程）起沿父进程链采集 `TerminalFacts`，最近的在前。
    /// 只做输入采集，不判定。`limit` 够穿过 agent → 包装 → 工具 shell 的任何嵌套，
    /// 又不会在深层进程树里白跑；读不到（进程已退出）就到此为止。
    static func terminalChain(startingAt pid: Int32, limit: Int = 16) -> [TerminalFacts] {
        var chain: [TerminalFacts] = []
        var current = pid
        while chain.count < limit, current > 1 {
            guard let step = terminalFacts(current) else { break }
            chain.append(step.facts)
            guard step.parent != current else { break }
            current = step.parent
        }
        return chain
    }

    /// 采集 + 判定。超出 `limit` 仍没找到组长就当没找到（多报一发，不丢事件）。
    public static func ancestry(startingAt pid: Int32, limit: Int = 16) -> Ancestry {
        let found = foregroundJobLeader(in: terminalChain(startingAt: pid, limit: limit))
        return Ancestry(process: found.leader.flatMap { read($0.pid) }, isNested: found.isNested)
    }

    /// `proc_bsdinfo` 里没有控制终端的前台进程组，只能另读一次 `kinfo_proc`。
    private static func terminalFacts(_ pid: Int32) -> (facts: TerminalFacts, parent: Int32)? {
        guard pid > 1 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let process = info.kp_eproc
        let facts = TerminalFacts(
            pid: pid, processGroup: process.e_pgid, foregroundGroup: process.e_tpgid,
            // NODEV 是 `(dev_t)(-1)`，带强制转换的宏 Swift 导不进来
            hasControllingTerminal: process.e_tdev != dev_t(-1))
        return (facts, process.e_ppid)
    }
}
