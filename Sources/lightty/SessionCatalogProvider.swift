import Foundation
import LighttyCore

struct SessionCatalogSource: Equatable {
    let agent: SessionAgent
    let root: URL
    let executable: String
    let configuration: SessionConfigurationLocation

    init(agent: SessionAgent, root: URL, executable: String,
         configuration: SessionConfigurationLocation? = nil) {
        self.agent = agent
        self.root = root
        self.executable = executable
        self.configuration = configuration ?? .custom(root.path)
    }
}

enum SessionCatalogError: LocalizedError {
    case unavailable(String), protocolFailure, timeout, tooLarge
    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .protocolFailure: return L("The CLI session interface is not supported by this version.")
        case .timeout: return L("Reading CLI sessions timed out. Try refreshing.")
        case .tooLarge: return L("The session catalog exceeded the loading limit.")
        }
    }
}

struct SessionCatalogPage {
    let sessions: [AgentSession]
    let nextCursor: String?
}

protocol SessionCatalogProvider {
    var source: SessionCatalogSource { get }
    /// One bounded page, off the main thread. No Agent execution or transcript mutation.
    func page(archived: Bool, cursor: String?, cancelled: () -> Bool) throws -> SessionCatalogPage
}

extension SessionCatalogProvider {
    // Complete reads are for fixtures, not the UI's incremental loading path.
    func sessions(archived: Bool, cancelled: () -> Bool) throws -> [AgentSession] {
        var records: [AgentSession] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            let result = try page(archived: archived, cursor: cursor, cancelled: cancelled)
            records += result.sessions
            cursor = result.nextCursor
            if let cursor, !seen.insert(cursor).inserted { throw SessionCatalogError.protocolFailure }
            if records.count > 50_000 { throw SessionCatalogError.tooLarge }
        } while cursor != nil
        return records
    }
}
