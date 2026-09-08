import Foundation
import LighttyCore

/// A pane's known conversation, independent of its tab, task file and transient activity.
/// This is the single identity used by navigation, snapshots and resume planning.
struct PaneSessionAssociation: Equatable {
    let key: AgentSessionKey
    let configuration: SessionConfigurationLocation
    let workingDirectory: String

    static func resolve(status: PaneStatus?, fallback: Self?, processExited: Bool,
                        candidates: [AgentSessionKey], home: URL) -> Self? {
        guard !processExited else { return nil }
        guard let status else { return fallback }
        guard status.event != "SessionEnd", let name = status.agent,
              let agent = SessionAgent(rawValue: name), let id = status.sessionID, !id.isEmpty else { return nil }
        let key: AgentSessionKey
        if let root = status.sourceRoot, !root.isEmpty {
            key = .init(agent: agent, sourceRoot: root, nativeID: id)
        } else if let fallback, fallback.key.agent == agent, fallback.key.nativeID == id {
            key = fallback.key
        } else {
            // Old hook payloads cannot distinguish multiple roots. Never guess from cwd/title/task.
            let matches = Set(candidates.filter { $0.agent == agent && $0.nativeID == id })
            guard matches.count == 1, let match = matches.first else { return nil }
            key = match
        }
        let previous = fallback.flatMap { $0.key == key ? $0 : nil }
        let location = status.sourceConfiguration ?? previous?.configuration
            ?? inferredConfiguration(for: key, home: home)
        guard location.root(for: agent, home: home).standardizedFileURL.path == key.sourceRoot else { return nil }
        return Self(key: key, configuration: location,
                    workingDirectory: status.cwd ?? previous?.workingDirectory ?? home.path)
    }

    private static func inferredConfiguration(for key: AgentSessionKey, home: URL) -> SessionConfigurationLocation {
        key.sourceRoot == SessionConfigurationLocation.standard.root(for: key.agent, home: home).standardizedFileURL.path
            ? .standard : .custom(key.sourceRoot)
    }

    /// Adapter for the published workspace v1 fields. No duplicate runtime identity state.
    init?(snapshot: PaneSnapshot, home: URL) {
        guard snapshot.agentAlive else { return nil }
        if let key = snapshot.catalogSession {
            self.init(key: key, configuration: snapshot.catalogConfiguration ?? Self.inferredConfiguration(for: key, home: home),
                      workingDirectory: snapshot.agentCWD ?? snapshot.workingDirectory ?? home.path)
        } else {
            // Published snapshots before full source identity used the standard CLI invocation.
            guard let name = snapshot.agent, let agent = SessionAgent(rawValue: name),
                  let id = snapshot.sessionID, !id.isEmpty else { return nil }
            self.init(key: .init(agent: agent, sourceRoot: SessionConfigurationLocation.standard.root(for: agent, home: home).path,
                                nativeID: id), configuration: .standard,
                      workingDirectory: snapshot.agentCWD ?? snapshot.workingDirectory ?? home.path)
        }
    }

    init(key: AgentSessionKey, configuration: SessionConfigurationLocation, workingDirectory: String) {
        self.key = key
        self.configuration = configuration
        self.workingDirectory = workingDirectory
    }

    func resumePlan(executable: String) throws -> SessionResumePlan {
        guard configuration.root(for: key.agent, home: FileManager.default.homeDirectoryForCurrentUser)
            .standardizedFileURL.path == key.sourceRoot else { throw SessionResumePlan.InvalidPlan.invalidValue }
        return try SessionResumePlan(resuming: .init(key: key, title: "", workingDirectory: workingDirectory, updatedAt: nil),
                                     executable: executable, configuration: configuration)
    }
}
