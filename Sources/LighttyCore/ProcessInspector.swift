import Foundation
import Darwin

/// 读别的进程的事实：终端作业结构、启动参数与环境变量、工作目录。都是系统接口
/// （`proc_listallpids`、`sysctl KERN_PROC` / `KERN_PROCARGS2`、`proc_pidinfo`），
/// 同一用户的进程可读，读不到就是 nil，不猜。
///
/// 用途：Codex 共享后台进程里的会话要对到 pane（见 `CodexSessionRouter`）。
/// pane 里起的每个进程都继承了 `LIGHTTY_PANE_ID`，界面进程又是 pane 终端的前台作业，
/// 这两条事实合起来就能说清「这个界面进程在哪个 pane」。
public enum ProcessInspector {
    /// 终端作业结构，全来自 `kinfo_proc`。
    public struct JobFacts: Equatable, Sendable {
        public let identity: AgentProcessIdentity
        public let parent: Int32
        public let processGroup: Int32
        public let foregroundGroup: Int32
        public let hasControllingTerminal: Bool

        /// 此刻占着终端的作业组长：自成一组、这一组在前台。pane 里闲着的 shell 也满足，
        /// 调用方另按启动参数区分是不是 agent。
        public var isForegroundJobLeader: Bool {
            hasControllingTerminal && identity.pid == processGroup && processGroup == foregroundGroup
        }

        public init(identity: AgentProcessIdentity, parent: Int32, processGroup: Int32,
                    foregroundGroup: Int32, hasControllingTerminal: Bool) {
            self.identity = identity
            self.parent = parent
            self.processGroup = processGroup
            self.foregroundGroup = foregroundGroup
            self.hasControllingTerminal = hasControllingTerminal
        }
    }

    /// 启动参数与环境变量（`KERN_PROCARGS2`）。
    public struct Launch: Equatable, Sendable {
        public let arguments: [String]
        public let environment: [String: String]

        public init(arguments: [String], environment: [String: String]) {
            self.arguments = arguments
            self.environment = environment
        }
    }

    public static func allPIDs() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        // 两次调用之间可能多出进程，多留些余量
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBytes {
            proc_listallpids($0.baseAddress, Int32($0.count))
        }
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled)).filter { $0 > 1 }
    }

    public static func jobFacts(_ pid: Int32) -> JobFacts? {
        guard pid > 1, let identity = AgentProcessIdentity.read(pid) else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return JobFacts(identity: identity, parent: info.kp_eproc.e_ppid, processGroup: info.kp_eproc.e_pgid,
                        foregroundGroup: info.kp_eproc.e_tpgid,
                        // NODEV 是 `(dev_t)(-1)`，带强制转换的宏 Swift 导不进来
                        hasControllingTerminal: info.kp_eproc.e_tdev != dev_t(-1))
    }

    public static func launch(_ pid: Int32) -> Launch? {
        var maximum: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var argmaxMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argmaxMIB, 2, &maximum, &size, nil, 0) == 0, maximum > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(maximum))
        var length = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &length, nil, 0) == 0 else { return nil }
        return parseProcargs(Array(buffer.prefix(length)))
    }

    /// `KERN_PROCARGS2` 的布局：argc（int32），可执行路径，若干 NUL 填充，
    /// 然后 argc 个参数，再往后到空串为止是环境变量。纯函数，便于测试。
    public static func parseProcargs(_ bytes: [UInt8]) -> Launch? {
        guard bytes.count >= 4 else { return nil }
        let argc = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc >= 0 else { return nil }
        var index = 4
        // 跳过可执行路径和它后面的 NUL 填充
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }

        func nextString() -> String? {
            guard index < bytes.count else { return nil }
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            let value = String(decoding: bytes[start..<index], as: UTF8.self)
            index += 1
            return value
        }

        var arguments: [String] = []
        for _ in 0..<argc {
            guard let argument = nextString() else { return nil }
            arguments.append(argument)
        }
        var environment: [String: String] = [:]
        while let entry = nextString(), !entry.isEmpty {
            guard let separator = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
        }
        return Launch(arguments: arguments, environment: environment)
    }

    public static func workingDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }
}
