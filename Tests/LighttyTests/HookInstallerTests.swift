import XCTest
@testable import lightty

/// `HookInstaller` 现在**不再改写用户的配置**——注册交给两家自己的 CLI。
/// 所以这里的用例只问三个问题：
///
/// 1. 只读探测认得出配置里的声明吗？（认错 = 用户点了没反应，或反复重装）
/// 2. 交给 CLI 的命令行对不对？（错一个子命令就是静默失败）
/// 3. **我们真的一个字节都没写进 agent 的配置吗？**
///
/// 所有用例都注入自己的 `HookInstaller.Context`：CLI 是个只记账的假实现，
/// 配置是临时目录里的 fixture。**任何用例都不得触碰 ~/.claude 或 ~/.codex**。
final class HookInstallerTests: XCTestCase {
    private var dir: URL!
    private var marketplace: URL!
    private var shim: URL!
    private var ledger: URL!
    private var configs: [HookAgent: URL] = [:]
    /// 假 CLI 记下的调用：(可执行文件, 参数)。并发用例会从多个线程写，必须上锁。
    private var recorded: [(executable: String, arguments: [String])] = []
    private let recordLock = NSLock()
    /// 假 CLI 的失败注入
    private var failure: Error?

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hook-installer-\(UUID().uuidString)", isDirectory: true)
        marketplace = dir.appendingPathComponent("marketplace", isDirectory: true)
        ledger = dir.appendingPathComponent("hook-plugins", isDirectory: true)
        configs = [
            .claudeCode: dir.appendingPathComponent("claude/settings.json"),
            .codex: dir.appendingPathComponent("codex/config.toml"),
        ]
        for file in configs.values {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        // hooks.json 指向一个不存在的可执行文件时安装会被拒，这里造一个真的
        shim = dir.appendingPathComponent("bin/lightty-hook")
        try FileManager.default.createDirectory(
            at: shim.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: shim)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: shim.path)
        recorded = []
        failure = nil
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - 工具

    private func context(cliPresent: Bool = true) -> HookInstaller.Context {
        HookInstaller.Context(
            marketplaceRoot: marketplace,
            shimPath: shim,
            stateDirectory: ledger,
            executable: { cliPresent ? "/fake/bin/\($0.executableName)" : nil },
            configFile: { [configs] in configs[$0]! },
            run: { [self] executable, arguments in
                recordLock.lock()
                recorded.append((executable, arguments))
                recordLock.unlock()
                if let failure { throw failure }
                return "ok"
            })
    }

    /// 假 CLI 收到的全部调用
    private var invocations: [(executable: String, arguments: [String])] {
        recordLock.lock()
        defer { recordLock.unlock() }
        return recorded
    }

    private func write(_ agent: HookAgent, _ text: String) throws {
        try Data(text.utf8).write(to: configs[agent]!)
    }

    private func state(_ agent: HookAgent, cliPresent: Bool = true) -> HookInstaller.State {
        HookInstaller.report(for: agent, in: context(cliPresent: cliPresent)).state
    }

    /// 只保留参数部分，断言读起来短一点
    private var arguments: [[String]] { invocations.map(\.arguments) }

    /// agent 配置目录的完整快照（路径 → 字节）
    private func configSnapshot() throws -> [String: Data] {
        let fm = FileManager.default
        var snapshot: [String: Data] = [:]
        for directory in configs.values.map({ $0.deletingLastPathComponent() }) {
            guard let walker = fm.enumerator(at: directory, includingPropertiesForKeys: nil)
            else { continue }
            for case let url as URL in walker {
                snapshot[url.path] = (try? Data(contentsOf: url)) ?? Data()
            }
        }
        return snapshot
    }

    // MARK: - fixture

    /// Claude Code 装好后 settings.json 的真实形状（实测抓取）
    private let claudeInstalled = """
        {"extraKnownMarketplaces":{"lightty":{"source":{"source":"directory",\
        "path":"/Users/tester/.lightty/marketplace"}}},\
        "enabledPlugins":{"lightty@lightty":true},"model":"opus"}
        """

    /// Codex 装好后 config.toml 的真实形状（实测抓取）
    private let codexInstalled = """
        [marketplaces.lightty]
        source_type = "local"
        source = "/Users/tester/.lightty/marketplace"

        [plugins."lightty@lightty"]
        enabled = true
        """

    // MARK: - agent 探测

    func testLocatesExecutablesOutsideOfPath() throws {
        // PATH 只有 /usr/bin:/bin 的 Finder 启动场景：兜底目录必须包含标准位置
        XCTAssertNotNil(HookInstaller.locateExecutable("sh"))
        XCTAssertNil(HookInstaller.locateExecutable("definitely-not-a-real-binary-xyz"))
    }

    func testSearchPathHasNoDuplicatesAndCoversFinderLaunch() throws {
        let path = HookInstaller.searchPath()
        XCTAssertEqual(path.count, Set(path).count, "PATH 里有重复目录")
        // 子进程 PATH 直接由它拼出来，缺了 node 的常见安装位置 claude 会自己失败
        XCTAssertTrue(path.contains("/opt/homebrew/bin"))
        XCTAssertTrue(path.contains("/usr/local/bin"))
    }

    func testMissingCLIIsReportedNotThrown() throws {
        let report = HookInstaller.report(for: .claudeCode, in: context(cliPresent: false))

        // 注册要靠它们自己的 CLI，找不到就是"这台机器上没有"
        XCTAssertFalse(report.isAgentPresent)
        XCTAssertEqual(report.state, .agentMissing)
        XCTAssertNil(report.executablePath)
    }

    func testInstallWithMissingCLIThrowsInsteadOfHalfInstalling() throws {
        XCTAssertThrowsError(try HookInstaller.install(.codex, in: context(cliPresent: false))) {
            XCTAssertEqual($0 as? HookCLIError, .notFound(executable: "codex"))
        }
        XCTAssertTrue(invocations.isEmpty)
    }

    // MARK: - 只读探测：Claude Code

    func testClaudeInstalledIsRecognised() throws {
        try write(.claudeCode, claudeInstalled)
        XCTAssertEqual(state(.claudeCode), .installed)
    }

    func testClaudeMissingConfigIsNotInstalled() throws {
        XCTAssertEqual(state(.claudeCode), .notInstalled)
    }

    func testClaudeUnrelatedConfigIsNotInstalled() throws {
        try write(.claudeCode, #"{"model":"opus","hooks":{"Stop":[]}}"#)
        XCTAssertEqual(state(.claudeCode), .notInstalled)
    }

    func testClaudeDisabledPluginIsNotInstalled() throws {
        // 用户手工关掉过插件——这不是"装好了"
        try write(.claudeCode, #"{"enabledPlugins":{"lightty@lightty":false}}"#)
        XCTAssertEqual(state(.claudeCode), .notInstalled)
    }

    func testClaudeMarketplaceWithoutPluginIsPartial() throws {
        // `claude plugin uninstall` 之后的真实形状：marketplace 条目会留下
        try write(.claudeCode, """
            {"extraKnownMarketplaces":{"lightty":{"source":{}}},"enabledPlugins":{}}
            """)
        XCTAssertEqual(state(.claudeCode), .partial(missing: ["lightty@lightty"]))
    }

    func testClaudePluginWithoutMarketplaceIsPartial() throws {
        try write(.claudeCode, #"{"enabledPlugins":{"lightty@lightty":true}}"#)
        XCTAssertEqual(state(.claudeCode), .partial(missing: ["lightty"]))
    }

    func testClaudeUnparseableConfigIsReportedNotGuessed() throws {
        try write(.claudeCode, "// 用户手写的带注释配置\n{}")

        guard case .unreadable(let reason) = state(.claudeCode) else {
            return XCTFail("读不懂的配置应报 unreadable")
        }
        XCTAssertTrue(reason.contains(configs[.claudeCode]!.path))
    }

    func testClaudeEmptyConfigIsNotInstalled() throws {
        // 空文件不是合法 JSON，但语义上就是"还没配过"
        try write(.claudeCode, "   \n")
        XCTAssertEqual(state(.claudeCode), .notInstalled)
    }

    // MARK: - 只读探测：Codex

    func testCodexInstalledIsRecognised() throws {
        try write(.codex, codexInstalled)
        XCTAssertEqual(state(.codex), .installed)
    }

    func testCodexMissingConfigIsNotInstalled() throws {
        XCTAssertEqual(state(.codex), .notInstalled)
    }

    func testCodexPluginRemovedLeavesMarketplaceBehind() throws {
        // `codex plugin remove` 之后的真实形状
        try write(.codex, """
            [marketplaces.lightty]
            source_type = "local"
            source = "/Users/tester/.lightty/marketplace"
            """)
        XCTAssertEqual(state(.codex), .partial(missing: ["lightty@lightty"]))
    }

    func testCodexDisabledPluginIsNotEnabled() throws {
        try write(.codex, """
            [marketplaces.lightty]
            source_type = "local"

            [plugins."lightty@lightty"]
            enabled = false
            """)
        XCTAssertEqual(state(.codex), .partial(missing: ["lightty@lightty"]))
    }

    func testCodexDoesNotConfuseNeighbouringTables() throws {
        // 别人的插件开着，不代表我们的开着——扫描必须认表头边界
        try write(.codex, """
            [plugins."someone-else@theirs"]
            enabled = true

            [model]
            name = "gpt-5"
            """)
        XCTAssertEqual(state(.codex), .notInstalled)
    }

    func testCodexKeepsUserContentIrrelevant() throws {
        // 用户自己的一大堆配置里夹着我们的两张表，照样认得出来
        try write(.codex, """
            model = "gpt-5"

            [tools]
            web_search = true

            [marketplaces.lightty]
            source_type = "local"

            [plugins."lightty@lightty"]
            enabled = true

            [history]
            persistence = "save-all"
            """)
        XCTAssertEqual(state(.codex), .installed)
    }

    // MARK: - 版本台账

    /// 直接往台账里塞一条记录（`record` 是私有的，测试从文件这一侧进）
    private func writeLedger(_ agent: HookAgent, _ version: String) throws {
        try FileManager.default.createDirectory(at: ledger, withIntermediateDirectories: true)
        try Data("\(version)\n".utf8).write(
            to: HookInstaller.versionFile(for: agent, in: context()))
    }

    func testInstalledCurrentVersionDoesNotNeedUpdate() throws {
        try write(.claudeCode, claudeInstalled)
        try writeLedger(.claudeCode, HookMarketplace.version(for: .claudeCode, command: shim.path))

        XCTAssertFalse(HookInstaller.report(for: .claudeCode, in: context()).needsUpdate)
    }

    func testInstalledStaleVersionNeedsUpdate() throws {
        try write(.claudeCode, claudeInstalled)
        try writeLedger(.claudeCode, "0.1.0+deadbeef")

        // 两家都在安装时**拷贝**插件，marketplace 变了不会自动生效
        XCTAssertTrue(HookInstaller.report(for: .claudeCode, in: context()).needsUpdate)
    }

    func testOtherAgentsLedgerIsNotConsulted() throws {
        try write(.claudeCode, claudeInstalled)
        // Codex 那条记录写得再新，也不该让 Claude Code 显示成"已是最新"
        try writeLedger(.codex, HookMarketplace.version(for: .codex, command: shim.path))

        XCTAssertTrue(HookInstaller.report(for: .claudeCode, in: context()).needsUpdate)
    }

    func testNoLedgerMeansNeedsUpdate() throws {
        try write(.claudeCode, claudeInstalled)
        // 宁可让 CLI 空跑一次幂等命令，也不要让 agent 悄悄跑着旧事件表
        XCTAssertTrue(HookInstaller.report(for: .claudeCode, in: context()).needsUpdate)
    }

    func testNotInstalledNeverNeedsUpdate() throws {
        XCTAssertFalse(HookInstaller.report(for: .codex, in: context()).needsUpdate)
    }

    // MARK: - 安装：交给 CLI 的命令

    func testFreshClaudeInstallUsesInstallSubcommand() throws {
        let outcome = try HookInstaller.install(.claudeCode, in: context())

        XCTAssertEqual(arguments, [
            ["plugin", "marketplace", "add", marketplace.path],
            ["plugin", "install", "lightty@lightty"],
        ])
        XCTAssertEqual(invocations.first?.executable, "/fake/bin/claude")
        XCTAssertEqual(
            outcome.version, HookMarketplace.version(for: .claudeCode, command: shim.path))
        XCTAssertFalse(outcome.removed)
    }

    func testAlreadyInstalledClaudeUsesUpdateSubcommand() throws {
        // 实测：插件已装时 `plugin install` 是空操作，版本变了也不会重新拷贝
        try write(.claudeCode, claudeInstalled)

        try HookInstaller.install(.claudeCode, in: context())

        XCTAssertEqual(arguments.last, ["plugin", "update", "lightty@lightty"])
    }

    func testCodexInstallAlwaysUsesAdd() throws {
        try write(.codex, codexInstalled)

        try HookInstaller.install(.codex, in: context())

        // `add` 每次都重新拷贝，一条命令兼任安装与更新；plugin@marketplace 形式是强制的
        XCTAssertEqual(arguments, [
            ["plugin", "marketplace", "add", marketplace.path],
            ["plugin", "add", "lightty@lightty"],
        ])
    }

    func testInstallGeneratesTheMarketplaceFirst() throws {
        try HookInstaller.install(.codex, in: context())

        let hooks = marketplace.appendingPathComponent("plugins/lightty/hooks.json")
        let text = try String(contentsOf: hooks, encoding: .utf8)
        XCTAssertTrue(text.contains(shim.path), "hooks.json 没指向 shim")
    }

    func testInstallRecordsTheVersionItLandedOn() throws {
        try HookInstaller.install(.claudeCode, in: context())

        XCTAssertEqual(
            HookInstaller.installedVersion(of: .claudeCode, in: context()),
            HookMarketplace.version(for: .claudeCode, command: shim.path))
        XCTAssertNil(HookInstaller.installedVersion(of: .codex, in: context()))
    }

    func testEachAgentGetsItsOwnLedgerEntry() throws {
        for agent in HookAgent.allCases {
            try HookInstaller.install(agent, in: context())
        }

        // 装第二家不能把第一家的记录顶掉
        for agent in HookAgent.allCases {
            XCTAssertEqual(
                HookInstaller.installedVersion(of: agent, in: context()),
                HookMarketplace.version(for: agent, command: shim.path),
                "\(agent.rawValue) 的台账被另一家覆盖了")
        }
    }

    func testInterleavedInstallsBothSurviveInTheLedger() throws {
        // 台账曾经是一份两家共用的 JSON，靠读-改-写维护：并发装两家必然丢一条。
        // 现在一家一个文件，正确性不再依赖调用方恰好串行——这里就绕开
        // HookInstaller 自己的串行队列，直接并发调阻塞版来钉死这一点。
        let done = expectation(description: "both installs")
        done.expectedFulfillmentCount = HookAgent.allCases.count
        for agent in HookAgent.allCases {
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do {
                    try HookInstaller.install(agent, in: context())
                } catch {
                    XCTFail("\(agent.rawValue) 并发安装失败: \(error)")
                }
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 20)

        for agent in HookAgent.allCases {
            XCTAssertEqual(
                HookInstaller.installedVersion(of: agent, in: context()),
                HookMarketplace.version(for: agent, command: shim.path),
                "并发安装丢了 \(agent.rawValue) 的台账")
        }
        // 并发生成同一棵树也不该产生半截文件或临时残留
        let strays = try FileManager.default
            .contentsOfDirectory(atPath: marketplace.appendingPathComponent(
                "plugins/lightty").path)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(strays.isEmpty, "并发生成留下了临时文件: \(strays)")
    }

    // MARK: - 卸载

    func testUninstallRemovesPluginThenMarketplace() throws {
        try write(.claudeCode, claudeInstalled)

        let outcome = try HookInstaller.uninstall(.claudeCode, in: context())

        XCTAssertEqual(arguments, [
            ["plugin", "uninstall", "lightty@lightty"],
            // marketplace 声明也要撤掉，否则用户配置里留下一条孤儿条目
            ["plugin", "marketplace", "remove", "lightty"],
        ])
        XCTAssertTrue(outcome.removed)
    }

    func testCodexUninstallUsesRemove() throws {
        try write(.codex, codexInstalled)

        try HookInstaller.uninstall(.codex, in: context())

        XCTAssertEqual(arguments.first, ["plugin", "remove", "lightty@lightty"])
    }

    func testUninstallOnlyRunsWhatIsActuallyDeclared() throws {
        try write(.codex, """
            [marketplaces.lightty]
            source_type = "local"
            """)

        try HookInstaller.uninstall(.codex, in: context())

        // 对着不存在的插件跑 remove 会非零退出，那种噪音不该变成"卸载失败"
        XCTAssertEqual(arguments, [["plugin", "marketplace", "remove", "lightty"]])
    }

    func testUninstallOnUntouchedConfigRunsNothing() throws {
        let outcome = try HookInstaller.uninstall(.claudeCode, in: context())

        XCTAssertTrue(invocations.isEmpty, "无事可做却跑了 CLI")
        XCTAssertTrue(outcome.commands.isEmpty)
    }

    func testUninstallClearsTheLedger() throws {
        try write(.claudeCode, claudeInstalled)
        try HookInstaller.install(.claudeCode, in: context())

        try HookInstaller.uninstall(.claudeCode, in: context())

        XCTAssertNil(HookInstaller.installedVersion(of: .claudeCode, in: context()))
    }

    // MARK: - 铁律：安装器从不写 agent 配置

    func testNothingWritesToAgentConfigPaths() throws {
        try write(.claudeCode, claudeInstalled)
        try write(.codex, codexInstalled)
        let before = try configSnapshot()

        for agent in HookAgent.allCases {
            try HookInstaller.install(agent, in: context())
            _ = HookInstaller.report(for: agent, in: context())
            try HookInstaller.uninstall(agent, in: context())
        }

        // 写用户配置的是它们自己的 CLI（这里是个假实现，什么都不写）。
        // 我们这一侧一个字节都不该动——包括不新建任何文件。
        XCTAssertEqual(try configSnapshot(), before, "安装器改动了 agent 配置目录")
    }

    func testFailedCLIDoesNotTouchAgentConfig() throws {
        try write(.claudeCode, claudeInstalled)
        let before = try configSnapshot()
        failure = HookCLIError.failed(
            command: "claude plugin install", status: 1, output: "boom")

        XCTAssertThrowsError(try HookInstaller.install(.claudeCode, in: context()))
        XCTAssertEqual(try configSnapshot(), before)
    }

    // MARK: - 错误

    func testMissingShimIsRefusedBeforeAnyCLIRuns() throws {
        try FileManager.default.removeItem(at: shim)

        XCTAssertThrowsError(try HookInstaller.install(.claudeCode, in: context())) { error in
            guard case HookInstallError.shimUnavailable(let expected) = error else {
                return XCTFail("应报 shimUnavailable，实际 \(error)")
            }
            XCTAssertEqual(expected, shim.path)
        }
        // 注册一条指向不存在文件的命令，只会让 agent 每次事件都报错
        XCTAssertTrue(invocations.isEmpty)
    }

    func testCLIFailureCarriesItsOutput() throws {
        failure = HookCLIError.failed(
            command: "claude plugin install lightty@lightty", status: 1,
            output: "✘ Failed to install plugin")

        XCTAssertThrowsError(try HookInstaller.install(.claudeCode, in: context())) { error in
            guard case HookCLIError.failed(_, let status, let output) = error else {
                return XCTFail("应原样带回 CLI 失败，实际 \(error)")
            }
            XCTAssertEqual(status, 1)
            XCTAssertTrue(output.contains("Failed to install"))
        }
    }

    func testCLIErrorsDescribeThemselves() throws {
        // 覆盖层尚未迁移，落到 localizedDescription 的路径也必须可读
        XCTAssertTrue(
            HookCLIError.timedOut(command: "codex plugin add", seconds: 60)
                .localizedDescription.contains("60s"))
        XCTAssertTrue(
            HookCLIError.notFound(executable: "codex")
                .localizedDescription.contains("codex"))
    }

    func testMarketplaceGenerationFailureIsSurfaced() throws {
        // marketplace 根被一个普通文件占住 → 建目录必然失败
        try Data("not a directory".utf8).write(to: marketplace)

        XCTAssertThrowsError(try HookInstaller.install(.codex, in: context())) { error in
            guard case HookInstallError.writeFailed = error else {
                return XCTFail("应报 writeFailed，实际 \(error)")
            }
        }
        XCTAssertTrue(invocations.isEmpty)
    }

    // MARK: - 真正的子进程

    func testCLIRunnerCapturesBothStreams() throws {
        let output = try HookCLI.run(
            "/bin/sh", ["-c", "echo out; echo err 1>&2"], timeout: 20)

        XCTAssertTrue(output.contains("out"))
        XCTAssertTrue(output.contains("err"), "stderr 没被收进来，错误信息会缺一半")
    }

    func testCLIRunnerMapsNonZeroExit() throws {
        XCTAssertThrowsError(
            try HookCLI.run("/bin/sh", ["-c", "echo nope 1>&2; exit 3"], timeout: 20)
        ) { error in
            guard case HookCLIError.failed(_, let status, let output) = error else {
                return XCTFail("应报 failed，实际 \(error)")
            }
            XCTAssertEqual(status, 3)
            XCTAssertEqual(output, "nope")
        }
    }

    func testCLIRunnerTimesOutInsteadOfHangingForever() throws {
        // 卡住的 CLI 不能把 app 一起冻住
        XCTAssertThrowsError(try HookCLI.run("/bin/sh", ["-c", "sleep 30"], timeout: 0.5)) {
            guard case HookCLIError.timedOut = $0 else {
                return XCTFail("应报 timedOut，实际 \($0)")
            }
        }
    }

    func testCLIRunnerDoesNotDeadlockOnLargeOutput() throws {
        // 输出超过管道缓冲区（64KB）时，读端不排空就会把子进程卡死在 write 上
        let output = try HookCLI.run(
            "/bin/sh", ["-c", "for i in $(seq 1 20000); do echo 0123456789; done"], timeout: 30)

        XCTAssertGreaterThan(output.count, 200_000)
    }

    func testCLIRunnerRejectsMissingExecutable() throws {
        XCTAssertThrowsError(try HookCLI.run("/nope/definitely-missing", [], timeout: 5)) {
            XCTAssertEqual($0 as? HookCLIError, .notFound(executable: "/nope/definitely-missing"))
        }
    }

    // MARK: - 异步入口

    func testCompletionHandlerRunsOffMainAndCallsBackOnMain() throws {
        let done = expectation(description: "completion")
        var onMain = false

        HookInstaller.install(.codex, in: context()) { result in
            onMain = Thread.isMainThread
            guard case .success = result else { return XCTFail("安装应成功") }
            done.fulfill()
        }

        wait(for: [done], timeout: 10)
        // UI 直接消费结果，回调必须在主线程
        XCTAssertTrue(onMain)
    }

    // MARK: - 真实配置路径不能被测试碰到

    func testRealConfigPathsAreNeverTheTestTarget() throws {
        // 这条用例本身不写任何东西，只是把「测试只碰 fixture」这个约定钉死：
        // 如果哪天有人把测试改成走无参 install()，这里的路径会提醒他后果。
        let claude = HookAgent.claudeCode.configFile.path
        let codex = HookAgent.codex.configFile.path
        if ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] == nil {
            XCTAssertTrue(claude.hasSuffix(".claude/settings.json"))
        }
        if ProcessInfo.processInfo.environment["CODEX_HOME"] == nil {
            XCTAssertTrue(codex.hasSuffix(".codex/config.toml"))
        }
        XCTAssertFalse(claude.hasPrefix(dir.path), "fixture 目录与真实配置路径重合了")
        XCTAssertFalse(codex.hasPrefix(dir.path), "fixture 目录与真实配置路径重合了")
    }
}
