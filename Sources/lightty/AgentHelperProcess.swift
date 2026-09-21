import Foundation
import LighttyCore
import Darwin

/// 会话操作起的工具进程怎么启动：可执行文件、参数、目录、环境。全 app 只在这里拼。
///
/// 两种进程，环境规则不同：
///
/// - **打包的 Claude SDK helper**（node 运行时 + mjs 脚本）：不继承 app 的环境，PATH
///   只给系统目录，只带配置根变量。它是本地文件操作，不是一次 Agent 调用，用不着
///   用户 shell 里的任何东西。
/// - **用户装的 Agent CLI**（`codex app-server`、`codex delete`、`claude agents`）：继承
///   app 的环境（CLI 可能依赖用户自己的变量），PATH 换成 `HookInstaller.searchPath()`
///   ——`claude` 是 node 包装脚本，Finder 启动的 PATH 里没有 node；配置根变量显式
///   设成来源根，不依赖默认值。
///
/// 两种都没有 `LIGHTTY_` 开头的变量：那是 pane 的 hook 路由，工具进程不是 pane，绝不能继承。
struct AgentHelperProcess: Equatable {
    let executable: URL
    let arguments: [String]
    let directory: URL
    let environment: [String: String]

    /// helper 目录里当前架构的 node 运行时。打包脚本两种架构都放，只挑自己这一份。
    static func nodeRuntime(in helperDirectory: URL) -> URL {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x64"
        #endif
        return helperDirectory.appendingPathComponent("runtime-\(architecture)/node")
    }

    /// 跑打包 helper 里的一个脚本。参数直接交给进程，不经过 shell，所以不需要引号规则。
    static func sdkScript(_ script: String, arguments: [String], helperDirectory: URL,
                          source: SessionCatalogSource) -> AgentHelperProcess {
        AgentHelperProcess(
            executable: nodeRuntime(in: helperDirectory),
            arguments: [helperDirectory.appendingPathComponent(script).path] + arguments,
            directory: helperDirectory,
            environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
                          source.agent.configurationVariable: source.root.path])
    }

    /// 跑来源配置的那个 CLI。
    static func agentCLI(_ agent: SessionAgent, executable: String, root: String,
                         arguments: [String], directory: URL,
                         inherited: [String: String] = ProcessInfo.processInfo.environment,
                         searchPath: [String] = HookInstaller.searchPath()) -> AgentHelperProcess {
        var environment = inherited.filter { !$0.key.hasPrefix("LIGHTTY_") }
        environment["PATH"] = searchPath.joined(separator: ":")
        environment[agent.configurationVariable] = root
        return AgentHelperProcess(executable: URL(fileURLWithPath: executable), arguments: arguments,
                                  directory: directory, environment: environment)
    }

    static func agentCLI(_ source: SessionCatalogSource, arguments: [String], directory: URL) -> AgentHelperProcess {
        agentCLI(source.agent, executable: source.executable, root: source.root.path,
                 arguments: arguments, directory: directory)
    }

    /// 一问一答：跑完读回 stdout。常驻的 `codex app-server` 见 `CodexAppServer`。
    func output(cancelled: () -> Bool = { false }, timeout: TimeInterval = 15,
                maximumBytes: Int = 1024 * 1024) throws -> Data {
        try SessionHelperProcess.readPage(executable: executable, arguments: arguments, directory: directory,
                                          environment: environment, cancelled: cancelled,
                                          timeout: timeout, maximumBytes: maximumBytes)
    }
}

/// 强杀一个子进程连同它的后代。
///
/// npm 装的 codex 是 node 包装脚本，真正干活的原生二进制是它的子进程；包装脚本会把
/// SIGTERM 转发下去，但要是它没按时退出、我们只 SIGKILL 它，原生进程就成了孤儿（PPID 1）
/// 一直挂着。后代必须趁根进程还活着时收集：根一死，子进程被 launchd 收养，再也顺不出来。
enum ProcessTree {
    static func kill(_ root: pid_t) {
        let tree = descendants(of: root)
        Darwin.kill(root, SIGKILL)
        for pid in tree { Darwin.kill(pid, SIGKILL) }
    }

    static func descendants(of root: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var pending = [root]
        // 上限防御进程表在遍历中途变化成环；正常的包装链只有一两层。
        while let parent = pending.popLast(), result.count < 256 {
            var buffer = [pid_t](repeating: 0, count: 64)
            let count = buffer.withUnsafeMutableBytes {
                proc_listchildpids(parent, $0.baseAddress, Int32($0.count))
            }
            guard count > 0 else { continue }
            let children = buffer.prefix(min(Int(count), buffer.count)).filter { $0 > 0 }
            result += children
            pending += children
        }
        return result
    }
}

/// One-shot child lifecycle, bounded output and deadline. No credentials or hook routing inherited.
enum SessionHelperProcess {
    static func readPage(executable: URL, arguments: [String], directory: URL,
                         environment: [String: String], cancelled: () -> Bool,
                         timeout: TimeInterval = 15, maximumBytes: Int = 1024 * 1024) throws -> Data {
        if cancelled() { throw CancellationError() }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        try? pipe.fileHandleForWriting.close()
        defer {
            if process.isRunning { process.terminate() }
            let deadline = Date().addingTimeInterval(0.2)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
            if process.isRunning { ProcessTree.kill(process.processIdentifier) }
            process.waitUntilExit()
            try? pipe.fileHandleForReading.close()
        }
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var result = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cancelled() { throw CancellationError() }
            var buffer = [UInt8](repeating: 0, count: 16384)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                result.append(contentsOf: buffer.prefix(count))
                if result.count > maximumBytes { throw SessionCatalogError.tooLarge }
            } else if count == 0 {
                if !process.isRunning {
                    guard process.terminationStatus == 0 else { throw SessionCatalogError.protocolFailure }
                    return result
                }
                Thread.sleep(forTimeInterval: 0.005)
            } else if errno == EAGAIN || errno == EINTR { Thread.sleep(forTimeInterval: 0.005) }
            else { throw SessionCatalogError.protocolFailure }
        }
        throw SessionCatalogError.timeout
    }
}
