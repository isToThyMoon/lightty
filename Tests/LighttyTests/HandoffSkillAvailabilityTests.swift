import XCTest

import LighttyCore
@testable import lightty

/// `HookInstaller.handoffSkillAvailable(for:in:)` 是全套交接设计里**风险最高的一个布尔值**。
///
/// 它决定按钮往终端里敲什么：真 → 敲技能调用（`/lightty:handoff <路径>`），
/// 假 → 敲一整段自带全部契约的指令。判错的代价不对称——
///
/// - 该真判成假：多敲十几行字，难看，但活儿照做
/// - **该假判成真**：技能名在那家 CLI 里不存在，两家都**静默失败**——什么都不会
///   发生，也没有任何报错。用户点了按钮，以为在写，其实一个字都没写
///
/// 而 2026-09-09 那次改动（把 `SKILL.md` 折进版本哈希）恰好让**所有既有安装**都
/// 进入 `state == .installed && needsUpdate == true`：装是装了，但 CLI 缓存里那份
/// 是旧的，根本没有 `skills/` 目录。只看 `state == .installed` 就会全员踩中第二种。
final class HandoffSkillAvailabilityTests: XCTestCase {
    private var dir: URL!
    private var ledger: URL!
    private var shim: URL!
    private var configs: [HookAgent: URL] = [:]

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("handoff-skill-\(UUID().uuidString)", isDirectory: true)
        ledger = dir.appendingPathComponent("hook-plugins", isDirectory: true)
        shim = dir.appendingPathComponent("bin/lightty-hook")
        configs = [
            .claudeCode: dir.appendingPathComponent("claude/settings.json"),
            .codex: dir.appendingPathComponent("codex/config.toml"),
        ]
        for file in configs.values {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(
            at: shim.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: shim)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func context(cliPresent: Bool = true) -> HookInstaller.Context {
        HookInstaller.Context(
            marketplaceRoot: dir.appendingPathComponent("marketplace", isDirectory: true),
            shimPath: shim,
            stateDirectory: ledger,
            executable: { cliPresent ? "/fake/bin/\($0.executableName)" : nil },
            configFile: { [configs] in configs[$0]! },
            run: { _, _ in "ok" })
    }

    /// 写出「两家都已声明安装」的配置。台账另写，用来控制 needsUpdate。
    private func declareInstalled() throws {
        try Data(#"{"extraKnownMarketplaces":{"lightty":{}},"enabledPlugins":{"lightty@lightty":true}}"#.utf8)
            .write(to: configs[.claudeCode]!)
        try Data("""
            [marketplaces.lightty]
            [plugins."lightty@lightty"]
            enabled = true
            """.utf8).write(to: configs[.codex]!)
    }

    /// 台账写成 `version`，让 `needsUpdate` 为假；写别的值则为真。
    private func recordLedger(_ agent: HookAgent, version: String) throws {
        try FileManager.default.createDirectory(at: ledger, withIntermediateDirectories: true)
        try Data(version.utf8).write(
            to: HookInstaller.versionFile(for: agent, in: context()))
    }

    private func sessionAgent(for agent: HookAgent) -> SessionAgent {
        agent == .codex ? .codex : .claude
    }

    /// 回到「没装、没台账」的起点，让表里每一行都从同一状态出发。
    private func resetFixture() throws {
        try? FileManager.default.removeItem(at: ledger)
        for file in configs.values { try? FileManager.default.removeItem(at: file) }
    }

    private enum Ledger { case current, stale, missing }

    /// 同一个布尔函数、同一套 fixture，只差「装没装 × 台账 × CLI 在不在」。
    /// 唯一为真的情形是装了且缓存里就是当前内容；其余全部必须为假。
    func testHandoffSkillIsAvailableOnlyForACurrentInstall() throws {
        struct Case {
            let name: String
            let installed: Bool
            let ledger: Ledger
            let cliPresent: Bool
            let expected: Bool
        }
        let cases: [Case] = [
            // 装了、且缓存里就是当前内容——这是唯一该敲技能调用的情形。
            Case(name: "installed and current", installed: true, ledger: .current, cliPresent: true, expected: true),
            // **这行是主角。** 装了，但装进去的是旧内容——技能是后加的，旧缓存里没有它。
            // 只看 `state == .installed` 的写法会在这里返回真，于是按钮静默失败。
            Case(name: "stale install", installed: true, ledger: .stale, cliPresent: true, expected: false),
            // 台账缺失也算旧：我们不知道 CLI 缓存里是什么，就不能拿静默失败去赌。
            Case(name: "missing ledger", installed: true, ledger: .missing, cliPresent: true, expected: false),
            // 压根没装。
            Case(name: "not installed", installed: false, ledger: .missing, cliPresent: true, expected: false),
            // 装了也记了台账，但 CLI 都找不到，谈不上技能可用。
            Case(name: "missing CLI", installed: true, ledger: .current, cliPresent: false, expected: false),
        ]
        for c in cases {
            try resetFixture()
            if c.installed { try declareInstalled() }
            for agent in HookAgent.allCases {
                switch c.ledger {
                case .current:
                    try recordLedger(agent, version: HookInstaller.report(for: agent, in: context()).version)
                case .stale:
                    try recordLedger(agent, version: "0.1.0+deadbeef")
                    let report = HookInstaller.report(for: agent, in: context())
                    XCTAssertEqual(report.state, .installed, "\(c.name): 前提没造对：应当是已装状态")
                    XCTAssertTrue(report.needsUpdate, "\(c.name): 前提没造对：应当是需要更新")
                case .missing:
                    break
                }
                XCTAssertEqual(
                    HookInstaller.handoffSkillAvailable(
                        for: sessionAgent(for: agent), in: context(cliPresent: c.cliPresent)),
                    c.expected,
                    "\(c.name) / \(agent.rawValue)：技能可用性判错了")
            }
        }
    }
}
