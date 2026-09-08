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

    public static func executable(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
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

    /// Nearest recognized Agent ancestor, not the short-lived hook or its intermediary shell.
    public static func agentAncestor(startingAt pid: Int32) -> (agent: String, process: Self)? {
        var current = pid
        for _ in 0..<16 {
            guard current > 1, let path = executable(of: current) else { return nil }
            if let agent = HookAgentDetection.agent(ancestorExecutablePaths: [path], transcriptPath: nil, environment: [:]),
               let identity = read(current) { return (agent, identity) }
            guard let next = parent(of: current), next != current else { return nil }
            current = next
        }
        return nil
    }

    private static func info(_ pid: Int32) -> proc_bsdinfo? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.stride))
            == MemoryLayout<proc_bsdinfo>.stride else { return nil }
        return info
    }
}
