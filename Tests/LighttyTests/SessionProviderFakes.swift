import Foundation
import LighttyCore
@testable import lightty

/// 只关心列表的 fixture：写操作一律失败、占用一律说不清、观察一律问不出来。
/// 生产 adapter 没有这些默认值——漏实现一项是编译错误；只有测试替身才借用它们。
protocol CatalogOnlyProvider: AgentSessionProvider {}

extension CatalogOnlyProvider {
    func rename(_ key: AgentSessionKey, to title: String) throws {
        throw SessionCatalogError.unavailable("Catalog fixture does not rename")
    }
    func delete(_ key: AgentSessionKey) throws {
        throw SessionCatalogError.unavailable("Catalog fixture does not delete")
    }
    func occupancy(of key: AgentSessionKey) -> SessionOccupancy.Result { .unknown }
    func checkDeletable(_ key: AgentSessionKey, known: [AgentProcessIdentity: AgentSessionKey]) throws {}
    func observeLiveSessions() -> LiveSessionObservation? { nil }
    func titleSignalFiles(for key: AgentSessionKey) -> [URL] { [] }
}

/// 可编排结果、记录调用的 provider 替身，用来走改名 / 删除 / 占用经 interface 的分支。
final class FakeSessionProvider: AgentSessionProvider {
    enum Call: Equatable {
        case rename(AgentSessionKey, String), delete(AgentSessionKey), occupancy(AgentSessionKey)
        case checkDeletable(AgentSessionKey, [AgentProcessIdentity: AgentSessionKey]), observe
    }

    let source: SessionCatalogSource
    var sessions: [AgentSession] = []
    var occupancyResult: SessionOccupancy.Result = .unknown
    var renameError: Error?
    var deleteError: Error?
    var deletionCheckError: Error?
    var observation: LiveSessionObservation?
    private(set) var calls: [Call] = []

    /// `executable` 默认不存在；要走通续接（启动器会核对可执行文件）时传 `/bin/echo` 之类。
    init(agent: SessionAgent = .claude, root: String = "/fixture/root", executable: String? = nil) {
        source = SessionCatalogSource(agent: agent, root: URL(fileURLWithPath: root),
                                      executable: executable ?? "/nonexistent/\(agent.executableName)",
                                      configuration: .custom(root))
    }

    func page(archived: Bool, cursor: String?, cancelled: () -> Bool) throws -> SessionCatalogPage {
        annotatingLiveSessions(SessionCatalogPage(sessions: archived ? [] : sessions, nextCursor: nil))
    }
    func rename(_ key: AgentSessionKey, to title: String) throws {
        calls.append(.rename(key, title))
        if let renameError { throw renameError }
    }
    func delete(_ key: AgentSessionKey) throws {
        calls.append(.delete(key))
        if let deleteError { throw deleteError }
    }
    func occupancy(of key: AgentSessionKey) -> SessionOccupancy.Result {
        calls.append(.occupancy(key))
        return occupancyResult
    }
    func checkDeletable(_ key: AgentSessionKey, known: [AgentProcessIdentity: AgentSessionKey]) throws {
        calls.append(.checkDeletable(key, known))
        if let deletionCheckError { throw deletionCheckError }
    }
    func observeLiveSessions() -> LiveSessionObservation? {
        calls.append(.observe)
        return observation
    }
    func titleSignalFiles(for key: AgentSessionKey) -> [URL] { [] }
}

/// 包一个真 adapter，只替换删除前的进程核查：集成测试不能依赖机器上此刻跑着哪些 claude。
struct DeletionCheckOverride: AgentSessionProvider {
    let base: AgentSessionProvider
    let check: () throws -> Void

    var source: SessionCatalogSource { base.source }
    func page(archived: Bool, cursor: String?, cancelled: () -> Bool) throws -> SessionCatalogPage {
        try base.page(archived: archived, cursor: cursor, cancelled: cancelled)
    }
    func rename(_ key: AgentSessionKey, to title: String) throws { try base.rename(key, to: title) }
    func delete(_ key: AgentSessionKey) throws { try base.delete(key) }
    func occupancy(of key: AgentSessionKey) -> SessionOccupancy.Result { base.occupancy(of: key) }
    func checkDeletable(_ key: AgentSessionKey, known: [AgentProcessIdentity: AgentSessionKey]) throws { try check() }
    func observeLiveSessions() -> LiveSessionObservation? { base.observeLiveSessions() }
    func titleSignalFiles(for key: AgentSessionKey) -> [URL] { base.titleSignalFiles(for: key) }
}
