import Foundation

public enum SessionAgent: String, Codable, CaseIterable, Sendable {
    case claude, codex

    public var configurationVariable: String {
        self == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"
    }
}

/// Configuration provenance, not the directory containing a transcript.
/// Explicitly setting Claude's default-looking directory changes global settings lookup.
public enum SessionConfigurationLocation: Codable, Equatable, Sendable {
    case standard
    case custom(String)

    public static func resolve(agent: SessionAgent, environment: [String: String]) -> Self {
        environment[agent.configurationVariable].map(Self.custom) ?? .standard
    }

    public func root(for agent: SessionAgent, home: URL) -> URL {
        switch self {
        case .standard: return home.appendingPathComponent(agent == .codex ? ".codex" : ".claude")
        case .custom(let path): return URL(fileURLWithPath: path)
        }
    }
}

/// A native session belongs to a configured local source, never just a display title.
public struct AgentSessionKey: Codable, Hashable, Sendable {
    public let agent: SessionAgent
    public let sourceRoot: String
    public let nativeID: String

    public init(agent: SessionAgent, sourceRoot: String, nativeID: String) {
        self.agent = agent
        self.sourceRoot = URL(fileURLWithPath: sourceRoot).standardizedFileURL.path
        self.nativeID = nativeID
    }
}

public struct AgentSession: Equatable, Sendable {
    public let key: AgentSessionKey
    public let title: String
    public let workingDirectory: String?
    public let updatedAt: Date?
    /// Source metadata only; unrelated to lightty's local organization archive state.
    public let sourceArchived: Bool

    public init(key: AgentSessionKey, title: String, workingDirectory: String?,
                updatedAt: Date?, sourceArchived: Bool = false) {
        self.key = key
        self.title = String(title.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }.prefix(240).map(String.init).joined())
        self.workingDirectory = workingDirectory
        self.updatedAt = updatedAt
        self.sourceArchived = sourceArchived
    }
}

public struct SessionProject: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var collapsed: Bool

    public init(id: UUID = UUID(), name: String, collapsed: Bool = false) {
        self.id = id
        self.name = name
        self.collapsed = collapsed
    }
}

public struct SessionAssignment: Codable, Equatable, Sendable {
    public let session: AgentSessionKey
    /// nil places the session in Recent sessions.
    public var projectID: UUID?
    public init(session: AgentSessionKey, projectID: UUID?) {
        self.session = session
        self.projectID = projectID
    }
}

public struct SessionOrganization: Codable, Equatable, Sendable {
    public var format = PersistenceFormat.organization.rawValue
    public var version = PersistenceFormat.organization.currentVersion
    public var projects: [SessionProject] = []
    public var assignments: [SessionAssignment] = []
    public private(set) var archivedSessions: Set<AgentSessionKey> = []
    public private(set) var archivedProjects: Set<UUID> = []
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case format, version, projects, assignments, archivedSessions, archivedProjects
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        format = try values.decode(String.self, forKey: .format)
        version = try values.decode(Int.self, forKey: .version)
        projects = try values.decode([SessionProject].self, forKey: .projects)
        assignments = try values.decode([SessionAssignment].self, forKey: .assignments)
        archivedSessions = try values.decodeIfPresent(Set<AgentSessionKey>.self, forKey: .archivedSessions) ?? []
        archivedProjects = try values.decodeIfPresent(Set<UUID>.self, forKey: .archivedProjects) ?? []
    }

    public func isArchived(_ session: AgentSession) -> Bool {
        archivedSessions.contains(session.key)
            || projectID(for: session).map { archivedProjects.contains($0) } == true
    }

    public mutating func setArchived(_ archived: Bool, session: AgentSession) {
        if archived { archivedSessions.insert(session.key) }
        else {
            archivedSessions.remove(session.key)
            if let project = projectID(for: session), archivedProjects.contains(project) {
                assign(session.key, to: nil)
            }
        }
    }

    public mutating func setArchived(_ archived: Bool, projectID: UUID) {
        guard projects.contains(where: { $0.id == projectID }) else { return }
        if archived { archivedProjects.insert(projectID) }
        else { archivedProjects.remove(projectID) }
    }

    public func projectID(for session: AgentSession) -> UUID? {
        if let explicit = assignments.first(where: { $0.session == session.key }) {
            return projects.contains(where: { $0.id == explicit.projectID }) ? explicit.projectID : nil
        }
        return nil
    }

    public mutating func assign(_ key: AgentSessionKey, to projectID: UUID?) {
        assignments.removeAll { $0.session == key }
        assignments.append(SessionAssignment(session: key, projectID: projectID))
    }

    /// Moving between visible groups is not a restore action.
    public mutating func move(_ session: AgentSession, to projectID: UUID?) {
        guard self.projectID(for: session) != projectID else { return }
        let wasArchived = isArchived(session)
        assign(session.key, to: projectID)
        if wasArchived { archivedSessions.insert(session.key) }
    }

    public mutating func removeProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        archivedProjects.remove(id)
        // Removing a group returns its members to Recent sessions, not to another project.
        for index in assignments.indices where assignments[index].projectID == id {
            assignments[index].projectID = nil
        }
    }

    public mutating func forgetSessions(_ keys: Set<AgentSessionKey>) {
        assignments.removeAll { keys.contains($0.session) }
        archivedSessions.subtract(keys)
    }

}

/// Native resume only. It does not inject a prompt or bind a task. The configured launch
/// flags ride along so a resumed session runs under the mode the user set for a new one.
public struct SessionResumePlan: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let unsetEnvironment: [String]
    public let workingDirectory: String
    private let agent: SessionAgent
    private let launchArguments: [String]

    public enum InvalidPlan: Error { case invalidIdentifier, invalidValue, missingDirectory }

    /// `launchArguments` 没有默认值：新的续接入口必须显式交代带哪些参数，
    /// 漏掉是编译错误，而不是一条悄悄退回默认审批模式的命令。
    public init(session: AgentSession, executable: String,
                configuration: SessionConfigurationLocation,
                workingDirectory: String? = nil,
                launchArguments: [String]) throws {
        let id = session.key.nativeID
        guard !id.isEmpty, id.count <= 128, id.first != "-",
              id.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
                      .contains($0)
              }) else { throw InvalidPlan.invalidIdentifier }
        guard let cwd = workingDirectory ?? session.workingDirectory, cwd.hasPrefix("/") else {
            throw InvalidPlan.missingDirectory
        }
        for value in [executable, cwd, session.key.sourceRoot] {
            guard value.hasPrefix("/"),
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw InvalidPlan.invalidValue
            }
        }
        for argument in launchArguments {
            guard !argument.isEmpty,
                  !argument.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw InvalidPlan.invalidValue
            }
        }
        self.executable = executable
        self.workingDirectory = cwd
        agent = session.key.agent
        self.launchArguments = launchArguments
        arguments = Self.compose(agent: agent, launchArguments: launchArguments, tail: [id])
        let variable = session.key.agent.configurationVariable
        switch configuration {
        case .standard:
            environment = [:]
            // A login shell may set an override after catalog discovery. Keep the selected
            // standard source without changing that shell or the user's configuration.
            unsetEnvironment = [variable]
        case .custom(let path):
            guard path.hasPrefix("/"),
                  !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  URL(fileURLWithPath: path).standardizedFileURL.path == session.key.sourceRoot else {
                throw InvalidPlan.invalidValue
            }
            environment = [variable: path]
            unsetEnvironment = []
        }
    }

    public var shellInput: String {
        render(arguments)
    }

    public var nativePickerInput: String {
        render(Self.compose(agent: agent, launchArguments: launchArguments,
                            tail: agent == .codex ? ["--all"] : []))
    }

    /// Each CLI keeps its own resume shape: codex takes a subcommand, claude a flag. The launch
    /// flags go where that CLI accepts them, never in front of the subcommand.
    private static func compose(agent: SessionAgent, launchArguments: [String], tail: [String]) -> [String] {
        agent == .codex
            ? ["resume"] + launchArguments + tail
            : launchArguments + ["--resume"] + tail
    }

    private func render(_ arguments: [String]) -> String {
        let env = environment.sorted { $0.key < $1.key }.map { Self.quote($0.key + "=" + $0.value) }
        let unset = unsetEnvironment.flatMap { ["-u", Self.quote($0)] }
        return (["/usr/bin/env"] + unset + env + [Self.quote(executable)] + arguments.map(Self.quote))
            .joined(separator: " ") + "\n"
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
