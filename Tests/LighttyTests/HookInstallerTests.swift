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

    // MARK: - 只读探测

    /// 配置文本 → State 的一行。`config` 为 nil 表示配置文件不存在。
    private struct StateCase {
        let name: String
        let config: String?
        let expected: HookInstaller.State
    }

    /// 逐行写入配置、只读探测，比对 State。`unreadable` 只比 case，另查 reason 带路径。
    private func checkStates(_ agent: HookAgent, _ cases: [StateCase]) throws {
        for c in cases {
            try? FileManager.default.removeItem(at: configs[agent]!)
            if let config = c.config { try write(agent, config) }
            let actual = state(agent)
            if case .unreadable(let reason) = c.expected {
                guard case .unreadable(let actualReason) = actual else {
                    XCTFail("\(c.name)：读不懂的配置应报 unreadable，实际 \(actual)")
                    continue
                }
                XCTAssertTrue(actualReason.contains(reason), "\(c.name)：unreadable 的理由里没带配置路径")
            } else {
                XCTAssertEqual(actual, c.expected, c.name)
            }
        }
    }

    /// 同一 `state(.claudeCode)`，只差 settings.json 的内容。
    func testClaudeConfigStateIsDetectedReadOnly() throws {
        try checkStates(.claudeCode, [
            // 装好后的真实形状
            StateCase(name: "installed is recognised", config: claudeInstalled, expected: .installed),
            StateCase(name: "missing config is not installed", config: nil, expected: .notInstalled),
            StateCase(name: "unrelated config is not installed",
                      config: #"{"model":"opus","hooks":{"Stop":[]}}"#, expected: .notInstalled),
            // 用户手工关掉过插件——这不是"装好了"
            StateCase(name: "disabled plugin is not installed",
                      config: #"{"enabledPlugins":{"lightty@lightty":false}}"#, expected: .notInstalled),
            // `claude plugin uninstall` 之后的真实形状：marketplace 条目会留下
            StateCase(name: "marketplace without plugin is partial",
                      config: #"{"extraKnownMarketplaces":{"lightty":{"source":{}}},"enabledPlugins":{}}"#,
                      expected: .partial(missing: ["lightty@lightty"])),
            StateCase(name: "plugin without marketplace is partial",
                      config: #"{"enabledPlugins":{"lightty@lightty":true}}"#,
                      expected: .partial(missing: ["lightty"])),
            // 读不懂的配置报 unreadable（理由带路径），不瞎猜
            StateCase(name: "unparseable config is reported not guessed",
                      config: "// 用户手写的带注释配置\n{}",
                      expected: .unreadable(reason: configs[.claudeCode]!.path)),
            // 空文件不是合法 JSON，但语义上就是"还没配过"
            StateCase(name: "empty config is not installed", config: "   \n", expected: .notInstalled),
        ])
    }

    /// 同一 `state(.codex)`，只差 config.toml 的内容。
    func testCodexConfigStateIsDetectedReadOnly() throws {
        try checkStates(.codex, [
            // 装好后的真实形状
            StateCase(name: "installed is recognised", config: codexInstalled, expected: .installed),
            StateCase(name: "missing config is not installed", config: nil, expected: .notInstalled),
            // `codex plugin remove` 之后的真实形状：marketplace 表留下
            StateCase(name: "plugin removed leaves marketplace behind",
                      config: """
                          [marketplaces.lightty]
                          source_type = "local"
                          source = "/Users/tester/.lightty/marketplace"
                          """,
                      expected: .partial(missing: ["lightty@lightty"])),
            StateCase(name: "disabled plugin is not enabled",
                      config: """
                          [marketplaces.lightty]
                          source_type = "local"

                          [plugins."lightty@lightty"]
                          enabled = false
                          """,
                      expected: .partial(missing: ["lightty@lightty"])),
            // 别人的插件开着，不代表我们的开着——扫描必须认表头边界
            StateCase(name: "does not confuse neighbouring tables",
                      config: """
                          [plugins."someone-else@theirs"]
                          enabled = true

                          [model]
                          name = "gpt-5"
                          """,
                      expected: .notInstalled),
            // 用户自己的一大堆配置里夹着我们的两张表，照样认得出来
            StateCase(name: "keeps user content irrelevant",
                      config: """
                          model = "gpt-5"

                          [tools]
                          web_search = true

                          [marketplaces.lightty]
                          source_type = "local"

                          [plugins."lightty@lightty"]
                          enabled = true

                          [history]
                          persistence = "save-all"
                          """,
                      expected: .installed),
        ])
    }

    // MARK: - 版本台账

    /// 直接往台账里塞一条记录（`record` 是私有的，测试从文件这一侧进）
    private func writeLedger(_ agent: HookAgent, _ version: String) throws {
        try FileManager.default.createDirectory(at: ledger, withIntermediateDirectories: true)
        try Data("\(version)\n".utf8).write(
            to: HookInstaller.versionFile(for: agent, in: context()))
    }

    /// 同一 `report().needsUpdate`，只差台账状态：装没装 × 台账里记的是谁的什么版本。
    func testNeedsUpdateFollowsThisAgentsLedger() throws {
        struct Case {
            let name: String
            let installed: Bool
            /// 台账里写哪一家、写什么版本；nil 表示没有台账。
            let ledger: (agent: HookAgent, version: String)?
            let expected: Bool
        }
        let current = HookMarketplace.version(for: .claudeCode, command: shim.path)
        let cases: [Case] = [
            // 装好且台账就是当前版本——不需要更新
            Case(name: "installed current version does not need update",
                 installed: true, ledger: (.claudeCode, current), expected: false),
            // 两家都在安装时**拷贝**插件，marketplace 变了不会自动生效
            Case(name: "installed stale version needs update",
                 installed: true, ledger: (.claudeCode, "0.1.0+deadbeef"), expected: true),
            // Codex 那条记录写得再新，也不该让 Claude Code 显示成"已是最新"
            Case(name: "other agent's ledger is not consulted",
                 installed: true, ledger: (.codex, HookMarketplace.version(for: .codex, command: shim.path)),
                 expected: true),
            // 宁可让 CLI 空跑一次幂等命令，也不要让 agent 悄悄跑着旧事件表
            Case(name: "no ledger means needs update", installed: true, ledger: nil, expected: true),
            // 没装就谈不上更新
            Case(name: "not installed never needs update", installed: false, ledger: nil, expected: false),
        ]
        for c in cases {
            try? FileManager.default.removeItem(at: ledger)
            try? FileManager.default.removeItem(at: configs[.claudeCode]!)
            if c.installed { try write(.claudeCode, claudeInstalled) }
            if let entry = c.ledger { try writeLedger(entry.agent, entry.version) }
            XCTAssertEqual(HookInstaller.report(for: .claudeCode, in: context()).needsUpdate, c.expected, c.name)
        }
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

    /// 安装把落地的版本记进这一家自己的台账；装第二家不能把第一家的记录顶掉。
    func testInstallRecordsTheVersionItLandedOn() throws {
        try HookInstaller.install(.claudeCode, in: context())

        XCTAssertEqual(
            HookInstaller.installedVersion(of: .claudeCode, in: context()),
            HookMarketplace.version(for: .claudeCode, command: shim.path))
        XCTAssertNil(HookInstaller.installedVersion(of: .codex, in: context()))

        try HookInstaller.install(.codex, in: context())
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

    /// 同一 `uninstall` + `arguments` 断言：agent × 配置里声明了什么 → 交给 CLI 的命令序列。
    func testUninstallRunsOnlyWhatIsDeclared() throws {
        struct Case {
            let name: String
            let agent: HookAgent
            let config: String?
            let expected: [[String]]
        }
        let cases: [Case] = [
            // 先卸插件再撤 marketplace 声明，否则用户配置里留下一条孤儿条目
            Case(name: "claude uninstall removes plugin then marketplace", agent: .claudeCode, config: claudeInstalled,
                 expected: [["plugin", "uninstall", "lightty@lightty"],
                            ["plugin", "marketplace", "remove", "lightty"]]),
            // Codex 的子命令叫 remove
            Case(name: "codex uninstall uses remove", agent: .codex, config: codexInstalled,
                 expected: [["plugin", "remove", "lightty@lightty"],
                            ["plugin", "marketplace", "remove", "lightty"]]),
            // 只声明了 marketplace：对着不存在的插件跑 remove 会非零退出，那种噪音不该变成"卸载失败"
            Case(name: "uninstall only runs what is actually declared", agent: .codex,
                 config: """
                     [marketplaces.lightty]
                     source_type = "local"
                     """,
                 expected: [["plugin", "marketplace", "remove", "lightty"]]),
            // 没碰过的配置：无事可做就不跑 CLI
            Case(name: "uninstall on untouched config runs nothing", agent: .claudeCode, config: nil, expected: []),
        ]
        for c in cases {
            recordLock.lock(); recorded = []; recordLock.unlock()
            try? FileManager.default.removeItem(at: configs[c.agent]!)
            if let config = c.config { try write(c.agent, config) }

            let outcome = try HookInstaller.uninstall(c.agent, in: context())

            XCTAssertEqual(arguments, c.expected, c.name)
            XCTAssertTrue(outcome.removed, c.name)
            XCTAssertEqual(outcome.commands.isEmpty, c.expected.isEmpty, c.name)
        }
    }

    func testUninstallClearsTheLedger() throws {
        try write(.claudeCode, claudeInstalled)
        try HookInstaller.install(.claudeCode, in: context())

        try HookInstaller.uninstall(.claudeCode, in: context())

        XCTAssertNil(HookInstaller.installedVersion(of: .claudeCode, in: context()))
    }

    // MARK: - 铁律：安装器从不写 agent 配置

    /// 装 / 探测 / 卸载全程，以及 CLI 失败那一侧，agent 配置目录前后快照必须一模一样。
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

        // CLI 失败时同样一个字节都不动。
        failure = HookCLIError.failed(
            command: "claude plugin install", status: 1, output: "boom")
        XCTAssertThrowsError(try HookInstaller.install(.claudeCode, in: context()))
        XCTAssertEqual(try configSnapshot(), before, "CLI 失败后安装器改动了 agent 配置目录")
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
