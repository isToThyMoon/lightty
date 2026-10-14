import Foundation
import LighttyCore

struct SessionCatalogSource: Equatable {
    let agent: SessionAgent
    let root: URL
    let executable: String
    /// 配置来源没有默认值：standard 与 custom 即使路径相同也不是一回事
    /// （见 docs/terminal-associations.md），构造的人必须说清是哪一种。
    let configuration: SessionConfigurationLocation
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
    /// 列表不列、按 ID 却查得到的一段会话；查不到返回 nil。只给 pane 补标题用，不进会话列表。
    /// Claude 会把已被接替的会话（← 转到后台时换了会话 ID）从列表里藏起来，pane 却可能还关联着它。
    func unlistedSession(_ key: AgentSessionKey, cancelled: () -> Bool) throws -> AgentSession?
}

extension SessionCatalogProvider {
    /// 没有按 ID 读的官方接口：列表就是全部。
    func unlistedSession(_ key: AgentSessionKey, cancelled: () -> Bool) throws -> AgentSession? { nil }

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
