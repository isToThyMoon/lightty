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
/// - 界面写进 pane 的终端标题（OSC 0）：列表是 `agentViewTitle`，连着一段会话时是那段会话的
///   `<前缀> <会话名>`，和前台会话同一种形状；
/// - `claude agents --json`：后台会话的名字彼此不重复（重名时 Claude 自动编号），按名字查到会话 ID。
/// 查到就写路由记录（hook 从此把那段会话的状态送进这个 pane）、把 pane 关联到它；换成了另一段
/// 对话就解绑 pane 上的 handoff 任务——任务跟的是原来那段对话。
///
/// 跟不跟只由标题决定：见过列表标题之后的前缀标题才算连着后台会话，前台会话（装没装 hook 都一样）
/// 的标题从不触发查询。shell 里直接 `claude attach <id>` 连上的，那一段标题和前台会话分不开，
/// 要等第一次按 ← 回到列表之后才开始跟。
///
/// 全 app 只有这里据 agent view 行动；`ClaudeSessionProvider` 只把官方输出里的 `kind`、`name` 读出来。
final class ClaudeAgentView {
    /// 一个 pane 在 agent view 里的样子。只记在跑 Claude 的 pane。
    private struct Display {
        enum Mode {
            /// 前台会话：标题是它自己的，只记下对话名
            case foreground
            /// 停在后台会话列表上
            case list
            /// 从列表连上了一段后台会话（列表本身不写带前缀的标题，所以列表之后的前缀标题就是连上了）
            case attached
        }
        var mode = Mode.foreground
        /// 已写路由记录的后台会话 ID
        var shown: String?
        /// 最近一次按名字查的会话名：转圈时标题每秒都在变，同一个名字只查一次
        var lookedUp: String?
        /// 上次按 `lookedUp` 没查到的时刻：刚派出的会话可能还没进列表，隔一会儿再查
        var missedAt: Date?
        /// 这个 pane 上一段对话的名字，判断换没换对话
        var conversation: String?
    }

    /// 没查到的名字隔多久再查：`claude agents --json` 要起一个进程，转圈的标题每秒一条。
    private static let retryInterval: TimeInterval = 10

    typealias LiveSessions = (SessionCatalogSource) -> [ClaudeSessionProvider.LiveSession]?

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
         liveSessions: @escaping LiveSessions = {
             ClaudeSessionProvider.liveSessions(executable: $0.executable, root: $0.root.path)
         }) {
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
        if let list = shape.agentViewTitle, title.trimmingCharacters(in: .whitespaces) == list {
            return enterList(pane)
        }
        guard let parsed = AgentTerminalTitle.parse(title, shape: shape), parsed.recognizedByPrefix,
              !parsed.body.isEmpty else { return }
        var display = displays[pane] ?? Display()
        switch display.mode {
        case .foreground:
            // 前台会话自己的标题：记下对话名，别的都不做——绝大多数标题走这里，不查任何东西。
            display.conversation = parsed.body
            displays[pane] = display
            return
        case .list:
            display.mode = .attached
        case .attached:
            break
        }
        let retry = display.missedAt.map { Date().timeIntervalSince($0) >= Self.retryInterval } ?? false
        guard display.lookedUp != parsed.body || retry else { displays[pane] = display; return }
        display.lookedUp = parsed.body
        display.missedAt = nil
        displays[pane] = display
        lookUp(parsed.body, for: pane)
    }

    /// 列表：这个 pane 不再显示哪段会话。前台会话被 ← 转到后台时也走这里——它还在跑，只是
    /// 不在这个 pane 上了。还没回来的查询跟着作废（`lookedUp` 清掉）。
    private func enterList(_ pane: UUID) {
        var display = displays[pane] ?? Display()
        display.mode = .list
        display.lookedUp = nil
        display.missedAt = nil
        if let shown = display.shown { AgentSessionRoute.remove(sessionID: shown, in: runDirectory) }
        display.shown = nil
        displays[pane] = display
        if library.paneState(for: pane)?.sessionKey != nil { library.associate(.none, with: pane) }
    }

    private func lookUp(_ name: String, for pane: UUID) {
        guard let source = library.source(for: .claude) else { return }
        let liveSessions = liveSessions
        queryQueue.async { [weak self] in
            let rows = liveSessions(source)
            DispatchQueue.main.async {
                guard let self, self.displays[pane]?.lookedUp == name else { return }
                guard let row = rows?.first(where: { $0.isBackground && $0.name == name }),
                      let session = row.sessionID else {
                    self.displays[pane]?.missedAt = Date()
                    return
                }
                self.show(session, named: name, directory: row.cwd, source: source, in: pane)
            }
        }
    }

    private func show(_ session: String, named name: String, directory: String?,
                      source: SessionCatalogSource, in pane: UUID) {
        guard var display = displays[pane] else { return }
        guard display.shown != session else {
            // 连着的会话改了名（`/rename`、自动起名）：还是同一段对话。
            displays[pane]?.conversation = name
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
            NSLog("claude agent view route write failed: \(error)")
            return
        }
        // ← 转到后台再连回来是同一段对话（名字随会话带走），任务留着；换成别的对话才解绑。
        if display.conversation != name, taskBindings.task(for: pane) != nil { taskBindings.unbind(pane) }
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
            AgentSessionRoute.remove(sessionID: shown, in: runDirectory)
        }
    }
}
