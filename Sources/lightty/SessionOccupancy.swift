import Foundation
import LighttyCore
import Darwin

/// Positive evidence only. No match is unknown, not proof that native resume will succeed.
/// Reads the OS file table; never opens a transcript, takes a lock, or signals an Agent.
enum SessionOccupancy {
    enum Result: Equatable { case inUse(pid: Int32), unknown }

    static func check(_ key: AgentSessionKey) -> Result {
        let command = key.agent.rawValue
        guard let data = try? SessionHelperProcess.readPage(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-n", "-P", "-b", "-a", "-u", String(getuid()), "-c", command, "-F0pcfan"],
            directory: URL(fileURLWithPath: "/"), environment: ["PATH": "/usr/bin:/bin"],
            cancelled: { false }, timeout: 2, maximumBytes: 4 * 1024 * 1024) else { return .unknown }
        return inspect(data, for: key)
    }

    /// lsof field output is NUL-delimited, with a newline separating process/file sets.
    /// Keep parsing separate so paths, access modes and partial output are fixture-testable.
    static func inspect(_ data: Data, for key: AgentSessionKey) -> Result {
        guard UUID(uuidString: key.nativeID) != nil else { return .unknown }
        let root = URL(fileURLWithPath: key.sourceRoot).resolvingSymlinksInPath().path
        var pid: Int32?
        var command = ""
        var descriptor = ""
        var access = ""
        for field in String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: true) {
            let field = field.drop(while: { $0 == "\n" })
            guard let tag = field.first else { continue }
            let value = String(field.dropFirst())
            switch tag {
            case "p": pid = Int32(value); command = ""; descriptor = ""; access = ""
            case "c": command = value
            case "f": descriptor = value; access = ""
            case "a": access = value
            case "n":
                guard let pid, pid > 0, command == key.agent.rawValue,
                      Int(descriptor) != nil, access == "u" || access == "w",
                      value.hasPrefix("/") else { continue }
                let path = URL(fileURLWithPath: value).standardizedFileURL.path
                let name = URL(fileURLWithPath: path).lastPathComponent
                let matches: Bool
                switch key.agent {
                case .codex:
                    matches = (path.hasPrefix(root + "/sessions/") || path.hasPrefix(root + "/archived_sessions/"))
                        && name.hasPrefix("rollout-") && name.hasSuffix("-" + key.nativeID + ".jsonl")
                case .claude:
                    matches = path.hasPrefix(root + "/projects/") && name == key.nativeID + ".jsonl"
                }
                if matches { return .inUse(pid: pid) }
            default: break
            }
        }
        return .unknown
    }
}
