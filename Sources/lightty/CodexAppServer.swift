import Foundation
import Darwin

/// 常驻的 `codex app-server`（stdio JSON-RPC）。同一个 codex 可执行文件 + 配置根只起一个，
/// 会话列表、改名、插件清单都问它。
///
/// 为什么常驻：app-server 按服务设计，一启动就在后台跑插件同步、git 市场升级检查这类
/// 启动任务。每问一句就起一个、问完就关，会把这些任务拦腰砍断——Codex 用来检查 git 市场的
/// `git ls-remote` 成了孤儿，`~/.codex/.tmp/git-*` 也没人删，会话列表刷新得勤，一天上千个。
/// 常驻时启动任务每次开 lightty 只跑一次、自然跑完；Codex 自己的界面也是这样用它的。
///
/// 生命周期：第一次请求时启动并握手；进程退出、请求超时、或可执行文件换过（升级）时，
/// 下一次请求换一个新进程；`shutdownAll()` 在 app 退出时关掉 stdin，让它自己收尾退出。
/// 请求是同步的，供后台线程调用；多个线程可以同时问，回应按 id 分发。
final class CodexAppServer: @unchecked Sendable {
    /// 自己的错误：说清是进程退出、超时、太大还是 Codex 拒绝，别笼统报成「接口不支持」。
    enum Failure: LocalizedError, Equatable {
        case exited
        case timedOut
        case tooLarge
        case malformed
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .exited: return L("Codex app-server exited. Try refreshing.")
            case .timedOut: return L("Codex app-server did not answer in time. Try refreshing.")
            case .tooLarge: return L("Codex app-server returned more data than lightty loads.")
            case .malformed: return L("Codex app-server answered in a format lightty does not recognize.")
            case .rejected(let message): return L("Codex app-server rejected the request: %@", message)
            }
        }
    }

    private struct Key: Hashable {
        let executable: String
        let root: String
    }

    private static let registryLock = NSLock()
    private static var servers: [Key: CodexAppServer] = [:]

    /// 同一个可执行文件 + 配置根共用一个；`spec` 只在第一次用来启动。
    static func shared(_ spec: AgentHelperProcess, root: URL) -> CodexAppServer {
        let key = Key(executable: spec.executable.standardizedFileURL.path, root: root.standardizedFileURL.path)
        registryLock.lock()
        defer { registryLock.unlock() }
        if let server = servers[key] { return server }
        let server = CodexAppServer(spec: spec)
        servers[key] = server
        return server
    }

    static func shutdownAll() {
        registryLock.lock()
        let all = Array(servers.values)
        servers.removeAll()
        registryLock.unlock()
        all.forEach { $0.shutdown() }
    }

    static let requestTimeout: TimeInterval = 12

    private let spec: AgentHelperProcess
    /// 启动与握手串行：同时来的请求等同一次握手，而不是各起一个进程。
    private let startLock = NSLock()
    private var connection: Connection?
    private var launchedStamp: ExecutableStamp?

    init(spec: AgentHelperProcess) {
        self.spec = spec
    }

    func request(_ method: String, params: [String: Any], timeout: TimeInterval = requestTimeout,
                 cancelled: () -> Bool = { false }) throws -> [String: Any] {
        let connection = try readyConnection()
        if cancelled() { throw CancellationError() }
        do {
            return try connection.call(method, params: params, timeout: timeout, cancelled: cancelled)
        } catch Failure.timedOut {
            // 不回话的进程不再复用；下一次请求重起。
            retire(connection)
            throw Failure.timedOut
        }
    }

    func shutdown() {
        startLock.lock()
        let current = connection
        connection = nil
        startLock.unlock()
        current?.close()
    }

    /// 握手不看调用方的取消：刷新连着触发时取消很常见，而半路关掉一个刚起的进程，
    /// 正是会砍断启动任务的那种关法。等握手的调用方最多等一次握手的时间。
    private func readyConnection() throws -> Connection {
        startLock.lock()
        defer { startLock.unlock() }
        let stamp = ExecutableStamp(spec.executable)
        if let connection, connection.isOpen, stamp == launchedStamp { return connection }
        connection?.close()
        connection = nil
        let fresh = try Connection(spec)
        do {
            _ = try fresh.call("initialize", params: [
                "clientInfo": ["name": "lightty", "version": "0.1.0"],
                "capabilities": ["experimentalApi": false],
            ], timeout: Self.requestTimeout, cancelled: { false })
            try fresh.notify("initialized")
        } catch {
            fresh.close()
            throw error
        }
        connection = fresh
        launchedStamp = stamp
        return fresh
    }

    private func retire(_ stale: Connection) {
        startLock.lock()
        if connection === stale { connection = nil }
        startLock.unlock()
        stale.close()
    }

    /// 可执行文件换过没有。npm / Homebrew 升级都是换文件，按符号链接的终点比 inode 与修改时间。
    private struct ExecutableStamp: Equatable {
        let inode: UInt64
        let modified: timespec

        init?(_ url: URL) {
            var info = stat()
            guard stat(url.resolvingSymlinksInPath().path, &info) == 0 else { return nil }
            inode = UInt64(info.st_ino)
            modified = info.st_mtimespec
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.inode == rhs.inode && lhs.modified.tv_sec == rhs.modified.tv_sec
                && lhs.modified.tv_nsec == rhs.modified.tv_nsec
        }
    }
}

// MARK: - 一次进程生命周期

/// 一个 app-server 进程：写请求、在专用线程上读回应并按 id 交给等待的调用方。
private final class Connection: @unchecked Sendable {
    private final class Waiter {
        let signal = DispatchSemaphore(value: 0)
        var result: Result<[String: Any], Error>?
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    /// 状态锁只护 `waiters` / `nextID` / `open`；写管道另用一把——管道写满时卡住的写方
    /// 不能挡住读线程分发回应，否则两边互等。
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var waiters: [Int: Waiter] = [:]
    private var nextID = 0
    private var open = true
    /// 由 `writeLock` 保护：stdin 只关一次，而且不管从哪条路走到 `close()` 都会关。
    private var inputClosed = false

    /// 单条消息的上限，与原先一次性读取时一致。
    private static let maximumLine = 8 * 1024 * 1024

    init(_ spec: AgentHelperProcess) throws {
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        process.environment = spec.environment
        process.currentDirectoryURL = spec.directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice // Never log private provider diagnostics.
        try process.run()
        // 进程先退出时再写，默认的 SIGPIPE 会连 lightty 一起杀掉；只对这一根管道改成报错。
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let reader = Thread { [self] in readLoop() }
        reader.name = "lightty.codex-app-server"
        reader.start()
    }

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return open && process.isRunning
    }

    func notify(_ method: String) throws {
        try send(["method": method])
    }

    func call(_ method: String, params: [String: Any], timeout: TimeInterval,
              cancelled: () -> Bool) throws -> [String: Any] {
        let waiter = Waiter()
        lock.lock()
        guard open else {
            lock.unlock()
            throw CodexAppServer.Failure.exited
        }
        nextID += 1
        let id = nextID
        waiters[id] = waiter
        lock.unlock()
        do {
            try send(["id": id, "method": method, "params": params])
        } catch {
            forget(id)
            throw error
        }
        let deadline = Date().addingTimeInterval(timeout)
        while waiter.signal.wait(timeout: .now() + 0.05) == .timedOut {
            if cancelled() { forget(id); throw CancellationError() }
            if Date() >= deadline { forget(id); throw CodexAppServer.Failure.timedOut }
        }
        guard let result = waiter.result else { throw CodexAppServer.Failure.exited }
        return try result.get()
    }

    /// 关 stdin，app-server 读到 EOF 自己收尾退出；等在上面的调用方立刻失败。
    func close() {
        lock.lock()
        open = false
        lock.unlock()
        // 正在写的线程写完再关：写已关闭的 FileHandle 会抛 Objective-C 异常。
        writeLock.lock()
        if !inputClosed {
            inputClosed = true
            try? input.fileHandleForWriting.close()
        }
        writeLock.unlock()
        failAll(CodexAppServer.Failure.exited)
    }

    private func forget(_ id: Int) {
        lock.lock()
        waiters.removeValue(forKey: id)
        lock.unlock()
    }

    private func send(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value)
        data.append(10)
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !inputClosed else { throw CodexAppServer.Failure.exited }
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func readLoop() {
        let handle = output.fileHandleForReading
        var buffer = Data()
        // 已经确认没有换行的前缀长度：每块只在新到的部分里找，长消息不会变成平方级的反复扫描。
        var scanned = 0
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }  // EOF：进程退出了
            buffer.append(chunk)
            while let newline = buffer[(buffer.startIndex + scanned)...].firstIndex(of: 10) {
                dispatch(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[(newline + 1)...])
                scanned = 0
            }
            scanned = buffer.count
            if buffer.count > Self.maximumLine {
                // 超限：先让等着的调用方知道是太大，而不是笼统的「接口不支持」；进程可能还活着，下面关它的 stdin
                failAll(CodexAppServer.Failure.tooLarge)
                break
            }
        }
        close()
        try? handle.close()
    }

    private func dispatch(_ line: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if let method = message["method"] as? String {
            // app-server 反过来问 lightty 的请求（审批、登录之类）：这里从不开对话，一律拒绝，
            // 免得它一直等。通知没有 id，忽略。回话放到别的线程写：读线程不能等写锁——
            // 写锁的持有者可能正卡在写满的管道上，而管道要靠读线程把回应读走才会松。
            if let id = message["id"] {
                let reply: [String: Any] = ["id": id, "error": ["code": -32601, "message": "\(method) is not supported"]]
                DispatchQueue.global(qos: .utility).async { [weak self] in try? self?.send(reply) }
            }
            return
        }
        guard let id = message["id"] as? Int else { return }
        lock.lock()
        let waiter = waiters.removeValue(forKey: id)
        lock.unlock()
        guard let waiter else { return }
        if let error = message["error"] as? [String: Any] {
            waiter.result = .failure(CodexAppServer.Failure.rejected(error["message"] as? String ?? "\(error)"))
        } else if let value = message["result"] as? [String: Any] {
            waiter.result = .success(value)
        } else {
            waiter.result = .failure(CodexAppServer.Failure.malformed)
        }
        waiter.signal.signal()
    }

    private func failAll(_ error: Error) {
        lock.lock()
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending.values {
            waiter.result = .failure(error)
            waiter.signal.signal()
        }
    }
}
