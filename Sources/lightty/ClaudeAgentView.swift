import Foundation
import LighttyCore

/// Claude 的 agent view（Claude Code 2.1.28x，官方文档 agent-view）：pane 里的 `claude` 界面能切到
/// supervisor 托管的后台会话上显示。空输入框按 ← 把前台会话转到后台、打开后台会话列表，列表里
/// 回车连上一段，再按 ← 回到列表；shell 里 `claude attach <id>` 直接连上。
///
/// 后台会话跑在 supervisor 自己的伪终端里，环境继承自第一个拉起 supervisor 的终端：哪个 pane
/// 转出来的后台会话都带着那一个 pane 的身份，备用会话一建出来就发 SessionStart。hook 据终端
/// 归属认出这种会话，只认路由记录（见 lightty-hook）。这里回答「这个 pane 此刻在显示哪段后台
/// 会话」，只用两样公开的东西：
/// - 界面写进 pane 的终端标题（OSC 0）：列表是 `isAgentViewList`，连着一段会话时是那段会话的
///   `<前缀> <会话名>`，和前台会话同一种形状；
/// - `claude agents --json`（官方说的「从 Claude Code 外面读会话状态」的正式途径）：哪些会话
///   在前台（`interactive`）、哪些在后台，后台会话的名字彼此不重复（重名时 Claude 自动编号）。
/// 查到就写路由记录（hook 从此把那段会话的状态送进这个 pane）、把 pane 关联到它；换成了另一段
/// 对话就解绑 pane 上的 handoff 任务——任务跟的是原来那段对话。
///
/// **标题只决定「什么时候去问」，不决定答案。** 每次问都从头核对一遍：pane 关联的会话还在前台
/// 就是前台；不在前台了、而有一段后台会话叫这个名字，就是连着它。不靠记住「先看到了列表」——
/// 那样漏认一次列表标题（上游给标题加了一段），pane 就永远跟不上，重启 lightty 也救不回来。
/// 什么时候去问：标题正文变了，或者上一条标题不是认识的会话标题（列表、认不出来的形状、
/// 刚启动）。转圈时每秒一条标题，正文不变就不问。
///
/// 没有关联任何会话的 pane（没装 hook）答不了「关联的会话还在不在前台」，只在看到列表之后才跟——
/// 否则前台会话和一段同名的后台会话分不开。
///
/// 全 app 只有这里据 agent view 行动；`ClaudeSessionProvider` 只把官方输出里的 `kind`、`name` 读出来。
final class ClaudeAgentView {
    /// 一个 pane 在 agent view 里的样子。只记在跑 Claude 的 pane。
    private struct Display {
        enum Mode {
            /// 还没核对过（刚开始跑、上一条标题认不出来）
            case unknown
            /// 前台会话：标题是它自己的
            case foreground
            /// 停在后台会话列表上，或从列表连上了一段、还没核对出是哪段
            case list
            /// 连着一段后台会话（`shown`）
            case attached
        }
        var mode = Mode.unknown
        /// 已写路由记录的后台会话 ID
        var shown: String?
        /// 最近一次拿去核对的标题正文：同一个正文只问一次
        var checked: String?
        /// 上次按 `checked` 没核对出结果的时刻：刚派出的会话可能还没进列表，隔一会儿再问
        var missedAt: Date?
        /// 这个 pane 上一段对话的名字，判断换没换对话
        var conversation: String?
    }

    /// 没核对出结果的正文隔多久再问：`claude agents --json` 要起一个进程，转圈的标题每秒一条。
    private static let retryInterval: TimeInterval = 10

    typealias LiveSessions = (SessionCatalogSource) -> [ClaudeSessionProvider.LiveSession]?

    private let diagnostic: (AgentDiagnostic) -> Void
    private let library: SessionLibrary
    private let taskBindings: TaskBindings
    private let socketPath: String
    private let runDirectory: URL
    private let liveSessions: LiveSessions
    private let queryQueue = DispatchQueue(label: "lightty.claude-agent-view", qos: .utility)
    private var displays: [UUID: Display] = [:]

    /// - Parameter liveSessions: 问一次 `claude agents --json`。测试换成固定的表。
    init(library: SessionLibrary, taskBindings: TaskBindings, socketPath: String,
         runDirectory: URL = PaneRuntimeDirectory.runDirectory,
         diagnostic: @escaping (AgentDiagnostic) -> Void = AgentDiagnostic.emit,
         liveSessions: @escaping LiveSessions = {
             ClaudeSessionProvider.liveSessions(executable: $0.executable, root: $0.root.path)
         }) {
        self.diagnostic = diagnostic
        self.library = library
        self.taskBindings = taskBindings
        self.socketPath = socketPath
        self.runDirectory = runDirectory
        self.liveSessions = liveSessions
    }

    func start() {
        library.terminalTitleObserver = { [weak self] pane, title in self?.noteTerminalTitle(title, in: pane) }
        NotificationCenter.default.addObserver(self, selector: #selector(libraryDidChange),
                                               name: .lighttySessionLibraryDidChange, object: library)
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        library.terminalTitleObserver = nil
        for pane in Array(displays.keys) { forget(pane) }
    }

    // MARK: - 终端标题

    func noteTerminalTitle(_ title: String, in pane: UUID) {
        let shape = SessionAgent.claude.spec.terminalTitle
        guard let parsed = AgentTerminalTitle.parse(title, shape: shape), parsed.recognizedByPrefix,
              !parsed.body.isEmpty else {
            if shape.isAgentViewList(title) { return enterList(pane) }
            // 认不出来的标题（上游换了列表的写法、shell 的标题）：下一条会话标题重新核对。
            if displays[pane] != nil {
                displays[pane]?.checked = nil
                if displays[pane]?.mode == .foreground { displays[pane]?.mode = .unknown }
            }
            return
        }
        var display = displays[pane] ?? Display()
        if display.mode == .foreground { display.conversation = parsed.body }
        let retry = display.missedAt.map { Date().timeIntervalSince($0) >= Self.retryInterval } ?? false
        guard display.checked != parsed.body || retry else { displays[pane] = display; return }
        display.checked = parsed.body
        display.missedAt = nil
        displays[pane] = display
        diagnostic(.init(.titleRefresh, .requested, agent: .claude, pane: pane))
        check(parsed.body, for: pane)
    }

    /// 列表：这个 pane 不再显示哪段会话。前台会话被 ← 转到后台时也走这里——它还在跑，只是
    /// 不在这个 pane 上了。还没回来的查询跟着作废（`checked` 清掉）。
    private func enterList(_ pane: UUID) {
        var display = displays[pane] ?? Display()
        diagnostic(.init(.sessionRoute, .list, agent: .claude, pane: pane, session: display.shown))
        display.mode = .list
        display.checked = nil
        display.missedAt = nil
        if let shown = display.shown { AgentSessionRoute.remove(sessionID: shown, in: runDirectory) }
        display.shown = nil
        displays[pane] = display
        if library.paneState(for: pane)?.sessionKey != nil { library.associate(.none, with: pane) }
    }

    private func check(_ name: String, for pane: UUID) {
        guard let source = library.source(for: .claude) else { return }
        let liveSessions = liveSessions
        queryQueue.async { [weak self] in
            let rows = liveSessions(source)
            DispatchQueue.main.async {
                guard let self, self.displays[pane]?.checked == name else { return }
                self.resolve(name, rows: rows, source: source, in: pane)
            }
        }
    }

    /// 按此刻的会话表核对 pane 显示的是谁。表问不出来、或对不上任何一行，就什么都不改——
    /// 宁可暂时没跟上，也不认错。
    private func resolve(_ name: String, rows: [ClaudeSessionProvider.LiveSession]?,
                         source: SessionCatalogSource, in pane: UUID) {
        guard let rows, let display = displays[pane] else {
            diagnostic(.init(.sessionRoute, .lookupFailed, agent: .claude, pane: pane))
            displays[pane]?.missedAt = Date()
            return
        }
        let associated = library.paneState(for: pane)?.sessionKey
            .flatMap { $0.agent == .claude ? $0.nativeID : nil }
        let foreground = rows.filter { !$0.isBackground }
        let associatedInForeground = associated.map { id in foreground.contains { $0.sessionID == id } } ?? false
        if associatedInForeground || foreground.contains(where: { $0.name == name }) {
            return showForeground(name, in: pane)
        }
        // 关联着的会话不在前台了（← 把它转到了后台、换了会话 ID），或者刚从列表连上一段。
        if associated != nil || display.mode == .list,
           let row = rows.first(where: { $0.isBackground && $0.name == name }), let session = row.sessionID {
            return show(session, named: name, directory: row.cwd, source: source, in: pane)
        }
        diagnostic(.init(.sessionRoute, .titleUnmatched, agent: .claude, pane: pane, session: associated))
        displays[pane]?.missedAt = Date()
    }

    private func showForeground(_ name: String, in pane: UUID) {
        guard var display = displays[pane] else { return }
        if let shown = display.shown { AgentSessionRoute.remove(sessionID: shown, in: runDirectory) }
        display.shown = nil
        diagnostic(.init(.sessionRoute, .foreground, agent: .claude, pane: pane))
        display.mode = .foreground
        display.conversation = name
        displays[pane] = display
    }

    private func show(_ session: String, named name: String, directory: String?,
                      source: SessionCatalogSource, in pane: UUID) {
        guard var display = displays[pane] else { return }
        display.mode = .attached
        guard display.shown != session else {
            // 连着的会话改了名（`/rename`、自动起名）：还是同一段对话。
            display.conversation = name
            displays[pane] = display
            return
        }
        if let previous = display.shown { AgentSessionRoute.remove(sessionID: previous, in: runDirectory) }
        // 一段会话的状态只能送进一个 pane：两个 pane 连着同一段时，后连上的为准，前一个不再关联它。
        for (other, candidate) in displays where other != pane && candidate.shown == session {
            displays[other]?.shown = nil
            if library.paneState(for: other)?.sessionKey?.nativeID == session { library.associate(.none, with: other) }
        }
        do {
            try AgentSessionRoute(pane: pane, socket: socketPath, client: nil)
                .write(sessionID: session, in: runDirectory)
        } catch {
            diagnostic(.init(.sessionRoute, .writeFailed, agent: .claude, pane: pane, session: session))
            displays[pane] = display
            return
        }
        // ← 转到后台再连回来是同一段对话（名字随会话带走），任务留着；换成别的对话才解绑。
        // 不知道上一段叫什么（重启后第一条标题就跟上）不算换了对话：解绑丢的东西找不回来。
        if let previous = display.conversation, previous != name, taskBindings.task(for: pane) != nil {
            taskBindings.unbind(pane)
        }
        diagnostic(.init(.sessionRoute, .titleMatched, agent: .claude, pane: pane, session: session))
        display.shown = session
        display.conversation = name
        displays[pane] = display
        let key = AgentSessionKey(agent: .claude, sourceRoot: source.root.path, nativeID: session)
        library.associate(.attached(PaneSessionAssociation(
            key: key, configuration: source.configuration,
            workingDirectory: directory ?? NSHomeDirectory())), with: pane)
    }

    // MARK: - 收尾

    /// pane 关了、界面退回了 shell、或者换成了别的会话：撤掉路由记录。
    @objc private func libraryDidChange() {
        let registered = library.registeredPaneIDs
        for (pane, display) in displays {
            let state = library.paneState(for: pane)
            guard registered.contains(pane), state?.titleAgent == .claude || state?.sessionKey != nil else {
                forget(pane)
                continue
            }
            if let shown = display.shown, state?.sessionKey?.nativeID != shown {
                AgentSessionRoute.remove(sessionID: shown, in: runDirectory)
                displays[pane]?.shown = nil
            }
        }
    }

    private func forget(_ pane: UUID) {
        if let shown = displays.removeValue(forKey: pane)?.shown {
            diagnostic(.init(.sessionRoute, .removed, agent: .claude, pane: pane, session: shown))
            AgentSessionRoute.remove(sessionID: shown, in: runDirectory)
        }
    }
}
