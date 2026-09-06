import AppKit
import LighttyCore

/// 改一段原生会话的名字。
///
/// 标题归 agent 所有——lightty 不另存一份覆盖名，否则会话侧栏读的是 agent 的目录，
/// 两边必然对不上。所以两条路写的都是 agent 自己的记录：
///
/// 1. **会话正开在某个 pane 里**：把 `/rename` 敲进那个终端，让 agent 自己改
///    （`PaneView.renameSession(to:)`）。只有这条能让终端里正在显示的标题也跟着变
///    ——从外面写进去，那个已经跑起来的进程不会重读。
/// 2. **会话没开**：走各家的官方接口，也就是本文件。codex 用 app-server 的
///    `thread/name/set`，claude 用官方开发包的 `renameSession`——跟已经在用的
///    `listSessions` / `deleteSession` 同一个包，不新增依赖。
///
/// 有了第 2 条，关着的会话才第一次能改名：以前必须先把它开起来、还得等它空闲。
///
/// 这里只改标题，不加载会话、不启动 agent、不碰会话正文。
enum SessionRename {
    enum Failure: LocalizedError, Equatable {
        case invalidSource, invalidName, failed
        var errorDescription: String? {
            switch self {
            case .invalidSource: return L("This CLI session source is no longer available.")
            case .invalidName: return L("Enter a session name.")
            case .failed: return L("The CLI could not rename this session. It may be in use, missing, or unsupported by this CLI version.")
            }
        }
    }

    /// 一行、无控制字符、限长 240——与 `AgentSession.title` 同一套约束。
    /// 不在这里过滤，改完的名字会在列表里被截成另一个样子，用户看到的和输入的不一致。
    static func sanitize(_ name: String) -> String? {
        let single = name.components(separatedBy: .newlines).joined(separator: " ")
        let stripped = String(String.UnicodeScalarView(single.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }))
        let trimmed = stripped.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(240))
    }

    /// 后台执行 + 回主线程刷新列表。改名不是破坏性操作，所以不设确认对话框，
    /// 也不像删除那样锁住整个 agent。
    static func perform(_ session: AgentSession, to name: String, library: SessionLibrary) {
        guard let source = library.source(for: session.key.agent) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try rename(session.key, to: name, source: source) }
            DispatchQueue.main.async {
                if case .failure = result { NSSound.beep() }
                // 成功要拉一次才看得到新名字；失败也要拉，避免列表停在乐观状态。
                library.refresh()
            }
        }
    }

    static func rename(_ key: AgentSessionKey, to name: String, source: SessionCatalogSource,
                       helperDirectory: URL = ClaudeSessionCatalog.installedHelper) throws {
        guard UUID(uuidString: key.nativeID) != nil, key.agent == source.agent,
              source.root.standardizedFileURL.path == key.sourceRoot,
              source.root.path != "/" else { throw Failure.invalidSource }
        guard let title = sanitize(name) else { throw Failure.invalidName }
        do {
            switch key.agent {
            case .codex: try renameCodex(key, to: title, source: source)
            case .claude: try renameClaude(key, to: title, source: source, helperDirectory: helperDirectory)
            }
        } catch let error as Failure { throw error }
        catch { throw Failure.failed }
    }

    private static func renameCodex(_ key: AgentSessionKey, to title: String,
                                    source: SessionCatalogSource) throws {
        let rpc = try CatalogJSONRPC.connected(to: source, cancelled: { false })
        defer { rpc.close() }
        _ = try rpc.request("thread/name/set",
                            params: ["threadId": key.nativeID, "name": title],
                            cancelled: { false })
    }

    private static func renameClaude(_ key: AgentSessionKey, to title: String,
                                     source: SessionCatalogSource, helperDirectory: URL) throws {
        #if arch(arm64)
        let runtime = "runtime-arm64/node"
        #else
        let runtime = "runtime-x64/node"
        #endif
        // 名字作为参数直接交给进程，不经过 shell，所以不需要引号规则。
        let data = try SessionHelperProcess.readPage(
            executable: helperDirectory.appendingPathComponent(runtime),
            arguments: [helperDirectory.appendingPathComponent("rename-session.mjs").path,
                        key.nativeID, title],
            directory: helperDirectory,
            environment: ["PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": source.root.path],
            cancelled: { false })
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["renamed"] as? String == key.nativeID else { throw Failure.failed }
    }
}
