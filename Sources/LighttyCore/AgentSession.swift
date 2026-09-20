import Foundation

public enum SessionAgent: String, Codable, CaseIterable, Sendable {
    case claude, codex
}

/// 一家 Agent 最常用的几项描述，都取自 `spec`（见 `AgentSpec.swift`）。
///
/// 这里只是给调用点省掉一个 `.spec.`，值本身写在各家自己的文件里。
/// 会话操作里的差异（列表、改名、删除、占用）既不是常量也不在这里，归各自的 provider adapter。
extension SessionAgent {
    /// PATH 上的可执行文件名。
    public var executableName: String { spec.executableName }

    /// CLI 用来改写配置根的环境变量。
    public var configurationVariable: String { spec.configurationVariable }

    /// 标准配置根相对家目录的名字。
    public var standardConfigurationDirectory: String { spec.standardConfigurationDirectory }

    /// 会话来源的名字：Sessions 侧栏的筛选、错误前缀、搜索结果标签。
    public var sourceName: String { spec.sourceName }

    /// 启动选择里的短名（启动浮层、设置页）。
    public var launchName: String { spec.launchName }

    /// 会话行图标的提示文字。
    public var iconToolTip: String { spec.iconToolTip }
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
        case .standard: return home.appendingPathComponent(agent.standardConfigurationDirectory)
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
    /// Process evidence observed while reading this source, not a live boolean or proof of
    /// another terminal. The app model reconciles ownership and exit using PID + start time.
    /// Empty means no evidence; it does not guarantee native resume is available.
    public let sourceProcesses: Set<AgentProcessIdentity>

    public init(key: AgentSessionKey, title: String, workingDirectory: String?,
                updatedAt: Date?, sourceArchived: Bool = false, sourceProcesses: Set<AgentProcessIdentity> = []) {
        self.key = key
        self.title = String(title.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }.prefix(240).map(String.init).joined())
        self.workingDirectory = workingDirectory
        self.updatedAt = updatedAt
        self.sourceArchived = sourceArchived
        self.sourceProcesses = sourceProcesses
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

/// 续接计划或选择器计划拼不出来的原因。
public enum InvalidLaunchPlan: Error { case invalidIdentifier, invalidValue, missingDirectory }

/// 续接与原生选择器共用的启动环境：哪家 Agent、哪个配置来源、哪个可执行文件、
/// 在哪个目录、带哪些启动参数。
///
/// 值的校验、配置来源到环境变量、各家参数位置、引号规则都只在这里。两种计划组合它，
/// 只各自补上命令尾部：续接是会话身份，选择器什么都不指向。
public struct AgentLaunchContext: Equatable, Sendable {
    public let agent: SessionAgent
    /// 配置来源目录，已标准化。自定义来源必须指向它。
    public let sourceRoot: String
    public let configuration: SessionConfigurationLocation
    public let executable: String
    public let workingDirectory: String
    /// 新建会话时用户设置的启动参数（bypass 等），续接与选择器照样带上。
    public let launchArguments: [String]

    /// `launchArguments` 没有默认值：新的入口必须显式交代带哪些参数，
    /// 漏掉是编译错误，而不是一条悄悄退回默认审批模式的命令。
    public init(agent: SessionAgent, sourceRoot: String, configuration: SessionConfigurationLocation,
                executable: String, workingDirectory: String, launchArguments: [String]) throws {
        guard workingDirectory.hasPrefix("/") else { throw InvalidLaunchPlan.missingDirectory }
        let root = URL(fileURLWithPath: sourceRoot).standardizedFileURL.path
        for value in [executable, workingDirectory, root] {
            guard value.hasPrefix("/"), !Self.hasControlCharacters(value) else {
                throw InvalidLaunchPlan.invalidValue
            }
        }
        for argument in launchArguments {
            guard !argument.isEmpty, !Self.hasControlCharacters(argument) else {
                throw InvalidLaunchPlan.invalidValue
            }
        }
        if case .custom(let path) = configuration {
            guard path.hasPrefix("/"), !Self.hasControlCharacters(path),
                  URL(fileURLWithPath: path).standardizedFileURL.path == root else {
                throw InvalidLaunchPlan.invalidValue
            }
        }
        self.agent = agent
        self.sourceRoot = root
        self.configuration = configuration
        self.executable = executable
        self.workingDirectory = workingDirectory
        self.launchArguments = launchArguments
    }

    /// 子进程里要设置的变量：自定义来源才设。
    public var environment: [String: String] {
        switch configuration {
        case .standard: return [:]
        case .custom(let path): return [agent.configurationVariable: path]
        }
    }

    /// 子进程里要清掉的变量。
    public var unsetEnvironment: [String] {
        switch configuration {
        // A login shell may set an override after catalog discovery. Keep the selected
        // standard source without changing that shell or the user's configuration.
        case .standard: return [agent.configurationVariable]
        case .custom: return []
        }
    }

    /// Each CLI keeps its own resume shape: codex takes a subcommand, claude a flag. The launch
    /// flags go where that CLI accepts them, never in front of the subcommand.
    func arguments(tail: [String]) -> [String] {
        switch agent.spec.resumeShape {
        case .flag(let flag): return launchArguments + [flag] + tail
        case .subcommand(let name): return [name] + launchArguments + tail
        }
    }

    func shellInput(tail: [String]) -> String {
        let env = environment.sorted { $0.key < $1.key }.map { Self.quote($0.key + "=" + $0.value) }
        let unset = unsetEnvironment.flatMap { ["-u", Self.quote($0)] }
        return (["/usr/bin/env"] + unset + env + [Self.quote(executable)] + arguments(tail: tail).map(Self.quote))
            .joined(separator: " ") + "\n"
    }

    private static func hasControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Native resume only. It does not inject a prompt or bind a task. The configured launch
/// flags ride along so a resumed session runs under the mode the user set for a new one.
public struct SessionResumePlan: Equatable, Sendable {
    public let context: AgentLaunchContext
    /// 续接的那段会话的原生 ID，已校验，不会被 shell 或 CLI 当成选项。
    public let nativeID: String

    /// `launchArguments` 没有默认值，理由见 `AgentLaunchContext`。
    public init(session: AgentSession, executable: String,
                configuration: SessionConfigurationLocation,
                workingDirectory: String? = nil,
                launchArguments: [String]) throws {
        let id = session.key.nativeID
        guard !id.isEmpty, id.count <= 128, id.first != "-",
              id.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
                      .contains($0)
              }) else { throw InvalidLaunchPlan.invalidIdentifier }
        guard let cwd = workingDirectory ?? session.workingDirectory else {
            throw InvalidLaunchPlan.missingDirectory
        }
        context = try AgentLaunchContext(agent: session.key.agent, sourceRoot: session.key.sourceRoot,
                                         configuration: configuration, executable: executable,
                                         workingDirectory: cwd, launchArguments: launchArguments)
        nativeID = id
    }

    public var arguments: [String] { context.arguments(tail: [nativeID]) }
    public var shellInput: String { context.shellInput(tail: [nativeID]) }
}

/// CLI 自带的会话选择器（`claude --resume`、`codex resume --all`）。
///
/// 它不续接任何一段会话，所以构造时**不要会话身份**：只要启动环境。以前只有
/// `SessionResumePlan` 拼得出这行命令，调用方得伪造一个 `nativeID: "placeholder"`
/// 的会话去换。
public struct SessionPickerPlan: Equatable, Sendable {
    public let context: AgentLaunchContext

    /// 与续接一样，`launchArguments` 没有默认值。
    public init(agent: SessionAgent, sourceRoot: String, executable: String,
                configuration: SessionConfigurationLocation, workingDirectory: String,
                launchArguments: [String]) throws {
        context = try AgentLaunchContext(agent: agent, sourceRoot: sourceRoot, configuration: configuration,
                                         executable: executable, workingDirectory: workingDirectory,
                                         launchArguments: launchArguments)
    }

    /// codex 默认只列当前目录的会话，`--all` 才是全部；claude 的选择器不带尾巴。
    private var tail: [String] { context.agent.spec.pickerArguments }

    public var arguments: [String] { context.arguments(tail: tail) }
    public var shellInput: String { context.shellInput(tail: tail) }
}
