import XCTest
import LighttyCore
@testable import lightty

/// `HookMarketplace` 生成的是**两家 agent 的 CLI 会当真去读的清单**。
/// 树形错一处、事件 key 大小写错一个字母，症状都是"hook 静默不触发"——
/// 没有比这更难在真机上定位的失败。所以这里逐文件、逐键地钉死。
///
/// 全部用例都生成到临时目录，`HookMarketplace.root`（`~/.lightty/marketplace`）
/// 在这里永远不该出现。
final class HookMarketplaceTests: XCTestCase {
    private var root: URL!
    private let shim = "/Users/tester/.lightty/bin/lightty-hook"

    private let expectedFiles = [
        ".agents/plugins/marketplace.json",
        ".claude-plugin/marketplace.json",
        "plugins/lightty/.claude-plugin/plugin.json",
        "plugins/lightty/.codex-plugin/plugin.json",
        "plugins/lightty/hooks.json",
        "plugins/lightty/hooks/hooks.json",
        // 两家共用这一份：布局和 frontmatter 格式一致，只有调用写法不同，
        // 而调用是敲进终端时的事，不落在这棵树上
        "plugins/lightty/skills/handoff/SKILL.md",
    ]

    override func setUpWithError() throws {
        // 先解掉 /var → /private/var 这层 symlink：目录遍历回来的是解析后的路径，
        // 不统一的话相对路径会算成 "/privateplugins/…" 这种鬼东西
        root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("hook-marketplace-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 工具

    @discardableResult
    private func generate(_ command: String? = nil) throws -> HookMarketplace.Generation {
        try HookMarketplace.generate(command: command ?? shim, root: root)
    }

    /// 递归列出树里的**全部**文件（相对 root），排序后可直接比对
    private func tree() throws -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        else { return [] }
        // 遍历回来的 URL 与 root 可能一个带 /private 一个不带，两边都标准化再相减
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var found: [String] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            found.append(path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path)
        }
        return found.sorted()
    }

    private func json(_ relativePath: String) throws -> [String: Any] {
        let url = root.appendingPathComponent(relativePath)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any],
            "\(relativePath) 不是合法 JSON 对象")
    }

    /// 某个 hooks.json 里 event → 该事件下所有 command 值
    private func hooks(_ relativePath: String) throws -> [String: [String]] {
        let root = try XCTUnwrap(try json(relativePath)["hooks"] as? [String: Any])
        return root.compactMapValues { value in
            (value as? [Any] ?? []).flatMap { group -> [String] in
                guard let entry = group as? [String: Any],
                      let inner = entry["hooks"] as? [Any] else { return [] }
                return inner.compactMap { ($0 as? [String: Any])?["command"] as? String }
            }
        }
    }

    private func modificationDates() throws -> [String: Date] {
        var dates: [String: Date] = [:]
        for path in try tree() {
            let url = root.appendingPathComponent(path)
            dates[path] = try FileManager.default
                .attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        }
        return dates
    }

    // MARK: - 目录树

    func testGeneratesExactlyTheExpectedTree() throws {
        try generate()
        // 多一个文件都可能被 CLI 当成另一个插件，少一个就是某一家读不到 hook
        XCTAssertEqual(try tree(), expectedFiles)
    }

    func testMarketplaceManifestsCarryRequiredKeys() throws {
        try generate()

        let claude = try json(".claude-plugin/marketplace.json")
        XCTAssertEqual(claude["name"] as? String, "lightty")
        XCTAssertNotNil(claude["owner"] as? [String: Any], "Claude Code 的清单缺 owner")
        let claudePlugins = try XCTUnwrap(claude["plugins"] as? [[String: Any]])
        XCTAssertEqual(claudePlugins.first?["name"] as? String, "lightty")
        XCTAssertEqual(claudePlugins.first?["source"] as? String, "./plugins/lightty")

        let codex = try json(".agents/plugins/marketplace.json")
        XCTAssertEqual(codex["name"] as? String, "lightty")
        let codexPlugins = try XCTUnwrap(codex["plugins"] as? [[String: Any]])
        let source = try XCTUnwrap(codexPlugins.first?["source"] as? [String: Any])
        XCTAssertEqual(source["source"] as? String, "local")
        XCTAssertEqual(source["path"] as? String, "./plugins/lightty")
    }

    func testPluginManifestsCarryRequiredKeys() throws {
        let generation = try generate()

        let claude = try json("plugins/lightty/.claude-plugin/plugin.json")
        XCTAssertEqual(claude["name"] as? String, "lightty")
        XCTAssertEqual(claude["version"] as? String, generation.version(for: .claudeCode))

        let codex = try json("plugins/lightty/.codex-plugin/plugin.json")
        XCTAssertEqual(codex["name"] as? String, "lightty")
        XCTAssertEqual(codex["version"] as? String, generation.version(for: .codex))
        // Codex 不认 hooks/ 目录约定，清单里不指路就等于没有 hook
        XCTAssertEqual(codex["hooks"] as? String, "./hooks.json")

        // 两份清单都要指向同一个 skills 目录：漏一份就是那一家看不见技能，
        // 而症状同样是静默的——用户敲 `/lightty:handoff` 什么都不会发生
        XCTAssertEqual(claude["skills"] as? String, "./skills/")
        XCTAssertEqual(codex["skills"] as? String, "./skills/")
    }

    /// 这一层只管一件事：树上那份就是协议里那份，中间没有被重新拼过。
    ///
    /// SKILL.md 的内容长什么样（frontmatter 单行、不带 `disable-model-invocation`）
    /// 是 `HandoffProtocol` 的事，由 `HandoffProtocolTests` 在正确的那一层守。
    /// 早先这里也抄了一份，写法还写死了"frontmatter 恰好两行"——将来正当加一个键
    /// 会挂在这儿，报错信息却说 description 折行了，把人往错方向带。
    func testSkillDocumentIsShippedVerbatim() throws {
        try generate()

        let url = root.appendingPathComponent("plugins/lightty/skills/handoff/SKILL.md")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), HandoffProtocol.skillDocument)
    }

    func testEachManifestCarriesItsOwnVersion() throws {
        try generate()

        let claude = try json("plugins/lightty/.claude-plugin/plugin.json")["version"] as? String
        let codex = try json("plugins/lightty/.codex-plugin/plugin.json")["version"] as? String
        // 两家事件表不同，版本就该不同；相同说明版本又被混在一起算了
        XCTAssertNotEqual(claude, codex)
    }

    // MARK: - hook 定义

    func testBothHookFilesCarryEveryEventWithTheShimPath() throws {
        try generate()

        for (path, agent) in [
            ("plugins/lightty/hooks/hooks.json", HookAgent.claudeCode),
            ("plugins/lightty/hooks.json", HookAgent.codex),
        ] {
            let hooks = try self.hooks(path)
            XCTAssertEqual(
                hooks.keys.sorted(), agent.events.sorted(), "\(path) 的事件表不完整")
            for event in agent.events {
                XCTAssertEqual(hooks[event], [shim], "\(path) 的 \(event) 没指向 shim")
            }
        }
    }

    func testInterruptIsCodexOnly() throws {
        try generate()

        XCTAssertNil(try hooks("plugins/lightty/hooks/hooks.json")["Interrupt"])
        XCTAssertEqual(try hooks("plugins/lightty/hooks.json")["Interrupt"], [shim])
    }

    func testEventKeysArePascalCase() throws {
        try generate()

        for path in ["plugins/lightty/hooks/hooks.json", "plugins/lightty/hooks.json"] {
            for event in try hooks(path).keys {
                // 实测：snake_case / camelCase 都不触发，只有 PascalCase 有效
                XCTAssertTrue(
                    event.first?.isUppercase == true && !event.contains("_"),
                    "\(path) 的事件 key 不是 PascalCase: \(event)")
            }
        }
    }

    func testHookEntriesCarryNoMatcher() throws {
        try generate()
        // 缺省即匹配全部；写死 matcher 会让部分工具调用不上报状态
        let groups = try XCTUnwrap(
            (try json("plugins/lightty/hooks/hooks.json")["hooks"] as? [String: Any])?[
                "PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 1)
        XCTAssertNil(groups.first?["matcher"])
    }

    // MARK: - 幂等

    func testRegenerationRewritesNothing() throws {
        let first = try generate()
        XCTAssertEqual(first.rewritten.sorted(), expectedFiles, "首次生成应写出全部文件")
        XCTAssertTrue(first.changed)
        let dates = try modificationDates()

        let second = try generate()

        XCTAssertTrue(second.rewritten.isEmpty, "内容没变却重写了: \(second.rewritten)")
        XCTAssertFalse(second.changed)
        // mtime 变了会让两家 CLI 的快照无端刷新，进而向用户弹更新提示
        XCTAssertEqual(try modificationDates(), dates, "内容没变却动了 mtime")
        for agent in HookAgent.allCases {
            XCTAssertEqual(first.version(for: agent), second.version(for: agent))
        }
    }

    // MARK: - shim 路径变化

    func testChangedShimPathPropagatesEverywhere() throws {
        try generate()
        let other = "/Applications/lightty.app/Contents/MacOS/lightty-hook"

        let generation = try generate(other)

        XCTAssertEqual(
            try hooks("plugins/lightty/hooks/hooks.json")["Stop"], [other])
        XCTAssertEqual(try hooks("plugins/lightty/hooks.json")["Stop"], [other])
        // 只有两份 hooks 与带版本的两份插件清单需要重写，marketplace 清单不含路径
        XCTAssertEqual(generation.rewritten.sorted(), [
            "plugins/lightty/.claude-plugin/plugin.json",
            "plugins/lightty/.codex-plugin/plugin.json",
            "plugins/lightty/hooks.json",
            "plugins/lightty/hooks/hooks.json",
        ])
    }

    // MARK: - 版本 = 内容哈希

    func testVersionTracksHookContent() throws {
        for agent in HookAgent.allCases {
            let a = HookMarketplace.version(for: agent, command: shim)
            let b = HookMarketplace.version(for: agent, command: "/somewhere/else/lightty-hook")

            XCTAssertEqual(
                a, HookMarketplace.version(for: agent, command: shim), "同样的内容算出了不同版本")
            XCTAssertNotEqual(a, b, "内容变了版本却没变——两家 CLI 不会重新拷贝插件")
        }
    }

    func testVersionIsSemverWithBuildMetadata() throws {
        // `0.1.0+3f2a1c9d`：`claude plugin validate` 零警告接受这个形状，
        // 且 `claude plugin update` 会把 build metadata 的变化当成"有新版本"
        let version = HookMarketplace.version(for: .claudeCode, command: shim)
        let parts = version.split(separator: "+")
        XCTAssertEqual(parts.count, 2, "版本串不是 base+metadata 形状: \(version)")
        XCTAssertEqual(String(parts[0]), HookMarketplace.baseVersion)
        XCTAssertEqual(parts[1].count, 8)
        XCTAssertTrue(
            parts[1].allSatisfy { $0.isHexDigit && !$0.isUppercase }, "哈希段含非法字符")
    }

    func testSharedHookChangeMovesBothVersions() throws {
        // 用户期望的流程：lightty 升级改了 hooks 逻辑 → **两边**都提示 Update，
        // 各点各的。事件表的事实来源是单一的（HookAgent.events 里那个 shared 数组
        // 加一个各家专有的尾巴），所以改共享部分必须让两家版本一起动。
        //
        // 上面那条用例守的是反面（只改一家不波及另一家）；这条守正面。
        // 两条都在，才说明版本粒度既不过粗也不过细。
        let sharedTail = "PreCompact"   // 假装新增一个两家都支持的事件
        for agent in HookAgent.allCases {
            let before = HookMarketplace.version(for: agent, command: shim)
            let after = HookMarketplace.version(
                hooks: HookMarketplace.hooksDocument(
                    events: agent.events + [sharedTail], command: shim),
                manifests: HookMarketplace.manifestBytes(for: agent))
            XCTAssertNotEqual(
                before, after,
                "共享事件表变了，\(agent.rawValue) 的版本却没动——那一行不会提示 Update")
        }

        // shim 路径同理：它写进两份 hooks 文档，动它两家都得重装
        for agent in HookAgent.allCases {
            XCTAssertNotEqual(
                HookMarketplace.version(for: agent, command: shim),
                HookMarketplace.version(for: agent, command: "/elsewhere/lightty-hook"),
                "\(agent.rawValue) 对 shim 路径变化不敏感")
        }
    }

    func testSkillChangeMovesBothVersions() throws {
        // 技能不进版本哈希是个**没有症状**的 bug：改了 SKILL.md 的文字，版本
        // 纹丝不动，两家 CLI 都不会重新拷贝，新文案永远到不了用户手上——而开发
        // 者这边文件明明是新的。所以这条必须守住。
        //
        // 技能两家共用一份，所以它一变，两家的版本都得跟着动。
        let edited = Data((HandoffProtocol.skillDocument + "\nOne more line.\n").utf8)
        for agent in HookAgent.allCases {
            let before = HookMarketplace.version(for: agent, command: shim)
            let after = HookMarketplace.version(
                hooks: HookMarketplace.hooksDocument(for: agent, command: shim), skill: edited,
                manifests: HookMarketplace.manifestBytes(for: agent))
            XCTAssertNotEqual(
                before, after,
                "SKILL.md 变了，\(agent.rawValue) 的版本却没动——新技能装不下去")
        }
    }

    func testOneAgentsEventChangeDoesNotMoveTheOthersVersion() throws {
        // hooks 那一半必须**只由这一家自己的文档**决定。混着算的话，改 Claude
        // Code 的事件表会把 Codex 的版本也顶掉，用户那一行凭空冒出"有更新"，
        // 点下去装的还是同样的东西。
        //
        // （另一半是两家共用的 SKILL.md，它一变两家一起动——那是对的，
        // 见 testSkillChangeMovesBothVersions。）
        for agent in HookAgent.allCases {
            XCTAssertEqual(
                HookMarketplace.version(for: agent, command: shim),
                HookMarketplace.version(
                    hooks: HookMarketplace.hooksDocument(events: agent.events, command: shim),
                    manifests: HookMarketplace.manifestBytes(for: agent)),
                "\(agent.rawValue) 的版本掺进了自己 hooks、那份技能、自己两份清单之外的东西")
        }

        // 给 Claude Code 加一个事件（模拟升级改了事件表）：它自己的版本必须变，
        // 而 Codex 的输入压根没被碰过，版本自然纹丝不动。
        let claudeNow = HookMarketplace.version(for: .claudeCode, command: shim)
        let claudeAfter = HookMarketplace.version(
            hooks: HookMarketplace.hooksDocument(
                events: HookAgent.claudeCode.events + ["PreCompact"], command: shim),
            manifests: HookMarketplace.manifestBytes(for: .claudeCode))
        XCTAssertNotEqual(claudeNow, claudeAfter, "改了事件表版本却没动")
        XCTAssertNotEqual(
            claudeAfter, HookMarketplace.version(for: .codex, command: shim))
    }

    /// 清单也必须进版本哈希，理由和技能一模一样：`skills` / `hooks` 指向哪儿、
    /// description、Codex 那份的 `interface` 与 `policy`——改任何一个都改变了
    /// "装进去的是什么"，而两家 CLI 只按版本串决定要不要重新拷贝。清单不进哈希，
    /// 就是"只改清单 → 版本纹丝不动 → 用户 cache 里还是旧的"，**没有任何症状**。
    ///
    /// 2026-09-09 之前正是如此：那天改了两份清单的 description、加了 `skills` 键，
    /// 全都没进哈希；当时没出事只是因为 SKILL.md 同时进了哈希，把版本顶起来了。
    func testManifestChangeMovesThatAgentsVersionOnly() throws {
        for agent in HookAgent.allCases {
            let before = HookMarketplace.version(for: agent, command: shim)
            var edited = HookMarketplace.manifestBytes(for: agent)
            edited.append(contentsOf: Data(#"{"interface":{"category":"新加的键"}}"#.utf8))
            let after = HookMarketplace.version(
                hooks: HookMarketplace.hooksDocument(for: agent, command: shim),
                manifests: edited)
            XCTAssertNotEqual(
                before, after,
                "\(agent.rawValue) 的清单变了版本却没动——CLI 不会重新拷贝，用户 cache 里还是旧清单")
        }

        // 跨家独立：清单按家分开喂，改一家不该顶掉另一家
        var claudeEdited = HookMarketplace.manifestBytes(for: .claudeCode)
        claudeEdited.append(contentsOf: Data("x".utf8))
        XCTAssertNotEqual(
            HookMarketplace.version(for: .codex, command: shim),
            HookMarketplace.version(
                hooks: HookMarketplace.hooksDocument(for: .claudeCode, command: shim),
                manifests: claudeEdited),
            "改 Claude Code 的清单不该动 Codex 的版本")
    }

    /// 版本串**只能**由那三样算出来。这条是上面几条的合围：任何人把生产路径改成
    /// 少喂一样（比如把 manifests 换成固定常量），它立刻不等而挂。
    func testProductionVersionIsExactlyTheThreeInputs() throws {
        for agent in HookAgent.allCases {
            XCTAssertEqual(
                HookMarketplace.version(for: agent, command: shim),
                HookMarketplace.version(
                    hooks: HookMarketplace.hooksDocument(for: agent, command: shim),
                    skill: HookMarketplace.skillDocument,
                    manifests: HookMarketplace.manifestBytes(for: agent)))
        }
    }

    /// `files(command:)` 的注释写着「顺序稳定，测试直接对着断言」，但别处那几条
    /// 都先 `.sorted()` 过，这个承诺一直没人看守。它不是白写的：`Generation.rewritten`
    /// 按这个顺序产出，调用方和日志都读它。
    func testFileOrderIsStable() throws {
        let paths = HookMarketplace.files(command: shim).map(\.path)
        XCTAssertEqual(paths, [
            ".claude-plugin/marketplace.json",
            ".agents/plugins/marketplace.json",
            "plugins/lightty/.claude-plugin/plugin.json",
            "plugins/lightty/.codex-plugin/plugin.json",
            "plugins/lightty/hooks/hooks.json",
            "plugins/lightty/hooks.json",
            "plugins/lightty/skills/handoff/SKILL.md",
        ])
    }

    func testPluginIDMatchesTheFormBothCLIsRequire() throws {
        // Codex 的 `plugin add` **强制**要求 plugin@marketplace 形式
        XCTAssertEqual(HookMarketplace.pluginID, "lightty@lightty")
    }

    // MARK: - 真实位置不能被测试碰到

    func testRealRootIsNeverTheTestTarget() throws {
        XCTAssertTrue(HookMarketplace.root.path.hasSuffix(".lightty/marketplace"))
        XCTAssertFalse(HookMarketplace.root.path.hasPrefix(root.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: HookMarketplace.root.path)
                && root.path.hasPrefix(HookMarketplace.root.path))
    }
}
