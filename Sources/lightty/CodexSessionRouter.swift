import Foundation
import LighttyCore

/// 把 Codex 共享后台进程里的会话对到 pane，写成 hook 读得到的路由记录（`AgentSessionRoute`）。
///
/// Codex 0.157 起，终端里的 `codex` 只是界面，会话和 hook 都跑在一个多终端共用的后台进程里，
/// hook 继承的 `LIGHTTY_PANE_ID` 属于当初拉起后台进程的终端。hook 手里唯一可靠的身份是
/// `session_id`，所以这里负责回答「这段会话显示在哪个 pane」。答案写下之后，hook 的
/// 状态、工具细节、中断、handoff 注入全走原来那条按 pane 的路，lightty 其余部分不知道这件事。
///
/// 事实从哪来：
/// - 后台进程的广播（和 ChatGPT 桌面端用的是同一条官方连接，见 `CodexDaemonChannel`）：
///   `thread/started` 在界面建会话时发出，带会话 ID、目录、创建时间；续接不发这条，
///   就在它第一次 `thread/status/changed` 时补查（`thread/read`）。`thread/closed` 时撤记录。
/// - 进程事实（见 `ProcessInspector`）：pane 里起的进程都继承了 `LIGHTTY_PANE_ID`，
///   界面进程是 pane 终端的前台作业组长，启动参数里是 `codex`；续接时参数里还有会话 ID。
///
/// 选 pane 的规则见 `choose`。子会话（带 `parentThreadId`）不在任何 pane 上显示，不写记录；
/// 工具里另起的 `codex exec` 也对不上任何界面进程——它们的 hook 查不到记录，照旧隐形。
final class CodexSessionRouter {
    /// 一个候选界面进程：它在哪个 pane、是谁、怎么启动的、在哪个目录。
    struct Client: Equatable {
        let pane: UUID
        let process: AgentProcessIdentity
        let arguments: [String]
        let workingDirectory: String?
    }

    private let library: SessionLibrary
    private let socketPath: String
    private let runDirectory: URL
    private var channel: CodexDaemonChannel?
    /// 当前连接握手完成没有。没完成就断了算一次失败。
    private var initialized = false
    private var lastAttempt = Date.distantPast
    /// 连续失败次数：机器上没有后台进程（旧版 Codex、`--no-daemon`）时 `proxy` 一起就退，
    /// 别在每次会话库变化时都起一个。间隔从 5 秒倍增，最长 5 分钟；连上一次就清零。
    private var failures = 0
    /// 会话 ID → 已写记录的 pane 与界面进程。
    private var routes: [String: (pane: UUID, client: AgentProcessIdentity?)] = [:]
    /// 暂时对不上的会话，上次尝试的时间：状态广播很密，别每条都扫一遍进程表。
    private var unresolved: [String: Date] = [:]
    private let scanQueue = DispatchQueue(label: "lightty.codex-session-router", qos: .utility)

    init(library: SessionLibrary, socketPath: String,
         runDirectory: URL = PaneRuntimeDirectory.runDirectory) {
        self.library = library
        self.socketPath = socketPath
        self.runDirectory = runDirectory
    }

    func start() {
        AgentSessionRoute.sweepStale(in: runDirectory)
        NotificationCenter.default.addObserver(self, selector: #selector(libraryDidChange),
                                               name: .lighttySessionLibraryDidChange, object: library)
        connectIfNeeded()
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        channel?.onClose = nil
        channel?.close()
        channel = nil
        for id in routes.keys { AgentSessionRoute.remove(sessionID: id, in: runDirectory) }
        routes.removeAll()
    }

    /// pane 关了就撤掉指向它的记录；有 pane 开始跑 Codex 而还没连上，就去连。
    @objc private func libraryDidChange() {
        let registered = library.registeredPaneIDs
        for (id, route) in routes where !registered.contains(route.pane) { drop(id) }
        if channel == nil, library.hasCodexPane { connectIfNeeded() }
    }

    // MARK: - 连接

    /// 后台进程不在时 `proxy` 会直接退出，所以不常驻重试：启动时试一次，之后等有 pane
    /// 开始跑 Codex 再试，按连续失败次数退避。
    private func connectIfNeeded() {
        let interval = min(5 * pow(2, Double(failures)), 300)
        guard channel == nil, Date().timeIntervalSince(lastAttempt) > interval,
              let source = library.source(for: .codex) else { return }
        lastAttempt = Date()
        initialized = false
        let spec = AgentHelperProcess.agentCLI(source, arguments: ["app-server", "proxy"], directory: source.root)
        guard let channel = try? CodexDaemonChannel(spec) else { return }
        self.channel = channel
        channel.onNotification = { [weak self] method, params in self?.handle(method, params) }
        channel.onClose = { [weak self, weak channel] in
            guard let self, self.channel === channel else { return }
            self.channel = nil
            if !self.initialized { self.failures += 1 }
        }
        // 握手卡住（`proxy` 起了却没有回应）也要断开，否则永远不再重试。
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak channel] in
            guard let self, let channel, self.channel === channel, !self.initialized else { return }
            channel.close()
        }
        channel.request("initialize", params: [
            "clientInfo": ["name": "lightty", "version": "0.1.0"],
            "capabilities": ["experimentalApi": false],
        ]) { [weak self, weak channel] result in
            guard let self, let channel, result != nil else { return }
            self.initialized = true
            self.failures = 0
            channel.notify("initialized")
            // 连上之前就在跑的会话：广播错过了，挨个补查。
            channel.request("thread/loaded/list") { [weak self] loaded in
                for id in (loaded?["data"] as? [String]) ?? [] { self?.lookUp(id) }
            }
        }
    }

    private func handle(_ method: String, _ params: [String: Any]) {
        switch method {
        case "thread/started":
            if let thread = params["thread"] as? [String: Any] { consider(thread, announced: true) }
        case "thread/status/changed":
            if let id = params["threadId"] as? String, routes[id] == nil { lookUp(id) }
        case "thread/closed":
            if let id = params["threadId"] as? String { drop(id) }
        case "thread/name/updated":
            // 自动起名与 `/rename` 都经 `thread/name/set`，后台进程随后广播这一条：重读目录的准确时机。
            if let id = params["threadId"] as? String { library.codexThreadRenamed(id) }
        default:
            break
        }
    }

    private func lookUp(_ id: String) {
        guard routes[id] == nil, Date().timeIntervalSince(unresolved[id] ?? .distantPast) > 5 else { return }
        unresolved[id] = Date()
        channel?.request("thread/read", params: ["threadId": id, "includeTurns": false]) { [weak self] result in
            if let thread = result?["thread"] as? [String: Any] { self?.consider(thread, announced: false) }
        }
    }

    // MARK: - 对 pane

    /// - Parameter announced: 会话是不是经 `thread/started` 刚宣布的。只有这种才算
    ///   「新鲜」；连上时补查、状态变化补查到的可能是界面早已退出、还挂在后台进程里的残留会话。
    private func consider(_ thread: [String: Any], announced: Bool) {
        guard let id = thread["id"] as? String, Self.isShownInATerminal(thread) else { return }
        let cwd = thread["cwd"] as? String
        let createdAt = (thread["createdAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let declared = library.panes(forCodexThread: id)
        let registered = library.registeredPaneIDs
        let socket = socketPath
        scanQueue.async { [weak self] in
            let clients = Self.scanClients(socket: socket, panes: registered)
            DispatchQueue.main.async {
                guard let self else { return }
                if let pane = declared.count == 1 ? declared.first : nil {
                    // lightty 自己续接或恢复的：pane 早就知道，界面进程找得到就一并记下。
                    self.record(id, pane: pane, client: clients.first { $0.pane == pane }?.process)
                } else if let client = Self.choose(threadID: id, cwd: cwd, createdAt: createdAt,
                                                   announced: announced, clients: clients) {
                    self.record(id, pane: client.pane, client: client.process)
                }
            }
        }
    }

    private func record(_ id: String, pane: UUID, client: AgentProcessIdentity?) {
        // 一个界面同一时刻只显示一个会话（`/new` 之后旧会话就不在它上面了）。
        if let client {
            for (other, route) in routes where other != id && route.client == client { drop(other) }
        }
        let route = AgentSessionRoute(pane: pane, socket: socketPath, client: client)
        do {
            try route.write(sessionID: id, in: runDirectory)
            routes[id] = (pane, client)
            unresolved.removeValue(forKey: id)
            library.setCodexRouted(true, pane: pane)
        } catch {
            NSLog("codex session route write failed: \(error)")
        }
    }

    private func drop(_ id: String) {
        let pane = routes.removeValue(forKey: id)?.pane
        unresolved.removeValue(forKey: id)
        AgentSessionRoute.remove(sessionID: id, in: runDirectory)
        if let pane, !routes.values.contains(where: { $0.pane == pane }) {
            library.setCodexRouted(false, pane: pane)
        }
    }

    /// 界面上显示的会话才有 pane。后台进程还会自己建会话，目录与界面相同、也会宣布
    /// `thread/started`，配上去会把真正会话的记录挤掉（实测：生成会话标题时建了一个
    /// `threadSource: thread_title`、`ephemeral: true` 的会话，回合的 Stop 就此丢失）：
    /// 子会话（带 `parentThreadId`）、临时会话、以及来源不是 `user` 的
    /// （`subagent`、`guardian_review`、`memory_consolidation`、各功能自建的）。
    /// 没有 `threadSource` 字段的旧版本按 `user` 处理。
    static func isShownInATerminal(_ thread: [String: Any]) -> Bool {
        thread["parentThreadId"] as? String == nil
            && (thread["ephemeral"] as? Bool) != true
            && (thread["threadSource"] as? String ?? "user") == "user"
    }

    /// 在 lightty 的 pane 里、此刻占着终端、启动参数是 `codex` 的进程。
    /// 读的都是同一用户的进程；只认本实例的 socket，另一个 lightty 实例的 pane 不归这里。
    static func scanClients(socket: String, panes: Set<UUID>) -> [Client] {
        let executable = SessionAgent.codex.executableName
        return ProcessInspector.allPIDs().compactMap { pid in
            guard let facts = ProcessInspector.jobFacts(pid), facts.isForegroundJobLeader,
                  let launch = ProcessInspector.launch(pid),
                  launch.environment["LIGHTTY_SOCK"] == socket,
                  let pane = launch.environment["LIGHTTY_PANE_ID"].flatMap(UUID.init(uuidString:)),
                  panes.contains(pane),
                  launch.arguments.prefix(2).contains(where: { names($0, executable) })
            else { return nil }
            return Client(pane: pane, process: facts.identity, arguments: launch.arguments,
                          workingDirectory: ProcessInspector.workingDirectory(pid))
        }
    }

    /// 参数是不是这个可执行文件：原生安装是 `codex` 本身，npm 安装是 `node …/codex.js`。
    private static func names(_ argument: String, _ executable: String) -> Bool {
        URL(fileURLWithPath: argument).deletingPathExtension().lastPathComponent == executable
    }

    /// 从候选界面进程里挑出显示这段会话的那一个。宁可不选也不选错：选错会把状态和
    /// handoff 送进别人的 pane，不选只是这段会话暂时没有状态。
    ///
    /// 1. 启动参数里带着会话 ID（`codex resume <ID>`）：确定。
    /// 2. 只凭工作目录配对时，必须有「新鲜」的证据——界面早已退出、还挂在后台进程里的残留会话
    ///    目录也可能相同（实测：连上时 `thread/loaded/list` 里就有上一轮留下的会话）：
    ///    - 刚经 `thread/started` 宣布、这个目录只有一个界面：就是它（也覆盖同一界面里 `/new`）；
    ///    - 否则看会话创建时间：界面启动约一秒后建会话，取启动时间离它最近、而且明显比
    ///      第二近的更近的那个，相差不超过 10 秒。
    ///
    /// 手敲 `codex resume` 的选择器或 `--last` 两样都没有，对不上，这段会话就不显示状态。
    static func choose(threadID: String, cwd: String?, createdAt: Date?, announced: Bool,
                       clients: [Client]) -> Client? {
        let named = clients.filter { $0.arguments.contains(threadID) }
        if !named.isEmpty { return Set(named.map(\.pane)).count == 1 ? named.first : nil }

        guard let cwd else { return nil }
        let target = URL(fileURLWithPath: cwd).standardizedFileURL.path
        let here = clients.filter {
            $0.workingDirectory.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == target
        }
        if announced, here.count == 1 { return here.first }

        guard let createdAt else { return nil }
        let ranked = here.map { client -> (Client, TimeInterval) in
            let started = Date(timeIntervalSince1970: TimeInterval(client.process.startedSeconds)
                + TimeInterval(client.process.startedMicroseconds) / 1_000_000)
            return (client, abs(createdAt.timeIntervalSince(started)))
        }.sorted { $0.1 < $1.1 }
        guard let nearest = ranked.first, nearest.1 < 10 else { return nil }
        if ranked.count > 1, ranked[1].1 - nearest.1 < 3 { return nil }
        return nearest.0
    }
}
