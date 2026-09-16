import Foundation
import XCTest

/// 在**受控的终端结构**里跑真实的 `lightty-hook`。
///
/// 为什么不能直接 `Process` 起 hook：每一发 hook 都要先过「是不是别的会话从工具里拉起的
/// 子会话」那一关（`AgentProcessIdentity.foregroundJobLeader(in:)`），判据是祖先链上的终端
/// 结构。而测试进程的祖先链取决于谁在跑 `swift test`——在某个 agent 的 Bash 工具里跑，
/// 测试进程**真的**就是一个工具子进程（实测 xctest → swift-package → zsh 三层都已脱离终端，
/// 再往上才是终端上的 agent），hook 会正确地静默，用例跟着时灵时不灵。
/// 所以一律用 `script -q /dev/null` 造一条自己的 pty，把 hook 摆到确定的位置上。
final class HookLauncher {
    /// hook 在终端结构里的四种位置，对应 `docs/specs/agent-integration-cleanup.md` D 的实测事实表。
    enum Shape {
        /// 主会话：假 agent 是 pty 上的前台作业组长，hook 是它的子进程。两家都是这个形状。
        case foreground
        /// 包装：前台作业再起一个**带终端**的子 shell 去跑 hook（npm 版 codex 的 node 包装）。
        case wrapped
        /// 子会话：前台作业用 `setsid` 起一个**脱离终端**的 shell 再跑 hook（工具里的 `claude -p`）。
        case nested
        /// 没有 pty：整条祖先链走到 launchd 为止，谁都没有控制终端。
        case detached
    }

    struct Run {
        /// pty 上的前台作业组长，也就是期望被记成 agent 进程的那个。`.detached` 没有。
        let leader: pid_t?
        /// 直接拉起 hook 的那个 shell。`.wrapped` 下它不是 `leader`。
        let hookParent: pid_t
        /// hook 写到 stdout 的东西（handoff 注入）。
        let output: Data
    }

    private let scratch: URL
    private let hook: URL
    private var spawned: [Process] = []

    init(scratch: URL, hook: URL) {
        self.scratch = scratch
        self.hook = hook
    }

    /// tearDown 调：造 pty 的 `script`、中间 shell 一个都不许留下。
    func reclaimSpawnedProcesses() {
        for process in spawned where process.isRunning { process.terminate() }
        for process in spawned { process.waitUntilExit() }
        spawned.removeAll()
    }

    @discardableResult
    func run(
        _ shape: Shape = .foreground, payload: String, arguments: [String] = [],
        environment: [String: String], file: StaticString = #filePath, line: UInt = #line
    ) throws -> Run {
        let tag = UUID().uuidString.prefix(8)
        let payloadFile = scratch.appendingPathComponent("payload-\(tag).json")
        let outputFile = scratch.appendingPathComponent("out-\(tag)")
        let pidFile = scratch.appendingPathComponent("pid-\(tag)")
        let leaderFile = scratch.appendingPathComponent("leader-\(tag)")
        let statusFile = scratch.appendingPathComponent("status-\(tag)")
        try payload.write(to: payloadFile, atomically: true, encoding: .utf8)
        // 退出码记下来：子会话那一路 hook 本来就静默，不记的话「判成了子会话」和
        // 「命令根本没跑起来」在测试里长得一模一样。
        let command = ([hook.path] + arguments).map { "\"\($0)\"" }.joined(separator: " ")
            + " < \"\(payloadFile.path)\" > \"\(outputFile.path)\"; echo $? > \"\(statusFile.path)\""
        // `; echo …` / `; exit 0` 不是装饰：sh 会把 `-c` 串或脚本里的**最后**一条简单命令直接
        // exec 掉，那样 hook 就顶替了本该在它上面的那层 shell，链的形状全变了。
        let record = "echo $$ > \"\(pidFile.path)\""
        let process = Process()
        process.environment = environment
        switch shape {
        case .foreground, .wrapped, .nested:
            let inner: String
            switch shape {
            case .wrapped: inner = "/bin/sh -c '\(record); \(command); exit 0'"
            case .nested: inner = "\"\(try helper(file: file, line: line).path)\" detach /bin/sh -c '\(record); \(command); exit 0'"
            default: inner = "\(record)\n\(command)"
            }
            let script = scratch.appendingPathComponent("session-\(tag).sh")
            try "echo $$ > \"\(leaderFile.path)\"\n\(inner)\nexit 0\n"
                .write(to: script, atomically: true, encoding: .utf8)
            // BSD script 会 fork 一个 `login_tty` 的子进程，所以 `/bin/sh <script>` 是新会话的
            // 会话组长，pid == pgid == 前台组——正是两家 agent 主会话被实测到的形状。
            process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            process.arguments = ["-q", "/dev/null", "/bin/sh", script.path]
        case .detached:
            process.executableURL = try helper(file: file, line: line)
            process.arguments = ["orphan", "/bin/sh", "-c", "\(record); \(command); exit 0"]
        }
        // stdin 必须给 /dev/null：script 若看见真 tty，会把**跑测试的那个终端**切进 raw 模式
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        spawned.append(process)
        process.waitUntilExit()
        // `.detached` 那路顶层进程立刻退出（孤儿化是它的全部工作），得等里面的 shell 跑完
        try waitUntil("the shell records the hook's exit status", file: file, line: line) {
            FileManager.default.fileExists(atPath: statusFile.path)
        }
        func recorded(_ file: URL) throws -> String {
            try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        XCTAssertEqual(try recorded(statusFile), "0", "hook 应该真的跑起来并静默退出 0", file: file, line: line)
        let hookParent = pid_t(try recorded(pidFile)) ?? 0
        XCTAssertGreaterThan(hookParent, 0, "shell 没写下自己的 pid", file: file, line: line)
        let leader = shape == .detached ? nil : pid_t(try recorded(leaderFile))
        if shape == .wrapped {
            XCTAssertNotEqual(leader, hookParent, "包装那一路得真的隔着一层 shell", file: file, line: line)
        }
        return Run(leader: leader, hookParent: hookParent,
                   output: (try? Data(contentsOf: outputFile)) ?? Data())
    }

    /// `setsid` 的两种用法编成一个小程序：macOS 没有 `/usr/bin/setsid`，
    /// Foundation 的 `Process` 也开不出 `POSIX_SPAWN_SETSID`。没有 cc 的机器跳过这些用例。
    private func helper(file: StaticString, line: UInt) throws -> URL {
        let url = scratch.appendingPathComponent("spawn-helper")
        if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        let source = scratch.appendingPathComponent("spawn-helper.c")
        try """
        #include <string.h>
        #include <unistd.h>
        // argv[1] = detach：脱离控制终端后 exec argv[2...]，调用方照常等它退出。
        // argv[1] = orphan：再 fork 一层，父进程立刻退出，子进程等到被 launchd 收养
        //                   （getppid() == 1，上限 5 秒）再 exec —— 收养前祖先链上还挂着
        //                   带终端的测试进程，早一步 exec 会把这一发判成子会话。
        int main(int argc, char **argv) {
            if (argc < 3) return 2;
            if (strcmp(argv[1], "orphan") == 0) {
                if (fork() != 0) _exit(0);
                for (int i = 0; i < 5000 && getppid() != 1; i++) usleep(1000);
            }
            setsid();
            execv(argv[2], argv + 2);
            _exit(127);
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let cc = Process()
        cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        cc.arguments = ["-O0", "-o", url.path, source.path]
        cc.standardOutput = FileHandle.nullDevice
        cc.standardError = FileHandle.nullDevice
        do { try cc.run() } catch { throw XCTSkip("没有 cc，跳过要造 setsid 的用例") }
        cc.waitUntilExit()
        guard cc.terminationStatus == 0 else { throw XCTSkip("cc 编译失败，跳过要造 setsid 的用例") }
        return url
    }

    /// 仓库根的 `.build/debug/lightty-hook`。
    static func builtHookBinary(fromTestFile path: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(path)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/lightty-hook")
    }
}
