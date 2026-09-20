import Foundation
import Testing
@testable import lightty

struct SkillCatalogTests {
    @Test func sharedLinksMergeButIndependentNamesDoNotInheritSources() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.skill(".agents/skills/review", name: "code-review")
        try fixture.json(".agents/.skill-lock.json", ["version": 3, "skills": [
            "review": ["source": "example/skills", "sourceType": "github"],
        ]])
        try fixture.link(".claude/skills/review", target: "../../.agents/skills/review")
        try fixture.skill(".cursor/skills/review", name: "code-review")
        let snapshot = fixture.scan()
        #expect(snapshot.warnings.isEmpty)
        #expect(snapshot.skills.count == 2)
        let shared = try #require(snapshot.skills.first { $0.origin == .installed })
        #expect(shared.sourceTitle == "example/skills")
        #expect(shared.sourceURL?.absoluteString == "https://github.com/example/skills")
        #expect(Set(shared.locations.map(\.label)) == ["Shared", "Claude"])
        #expect(shared.id == fixture.url(".agents/skills/review/SKILL.md").resolvingSymlinksInPath().path)
        #expect(snapshot.skills.filter { $0.origin == .local }.count == 1)
    }

    @Test func xdgAndCodexHomeSelectOnlyTheirConfiguredRoots() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.skill(".agents/skills/doc", name: "doc")
        try fixture.json(".agents/.skill-lock.json", ["skills": ["doc": ["source": "stale/source"]]])
        try fixture.skill(".codex/skills/old", name: "old")
        try fixture.skill("custom-codex/skills/.system/builtin", name: "builtin")
        let environment = ["XDG_STATE_HOME": fixture.url("state").path, "CODEX_HOME": fixture.url("custom-codex").path]
        let first = fixture.scan(environment)
        #expect(first.skills.count == 2)
        #expect(first.skills.first { $0.name == "doc" }?.origin == .local)
        #expect(first.skills.first { $0.name == "builtin" }?.origin == .builtIn)
        try fixture.json("state/skills/.skill-lock.json", ["skills": ["doc": [
            "source": "open.feishu.cn", "sourceBaseUrl": "https://open.feishu.cn/lark-cli/skills/regular",
        ]]])
        let record = try #require(fixture.scan(environment).skills.first { $0.name == "doc" })
        #expect(record.sourceTitle == "Lark CLI")
        #expect(record.origin == .installed)
    }

    @Test func usageComesFromClaudeCodeAndIsAbsentRatherThanZeroElsewhere() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.skill(".agents/skills/lark-doc", name: "lark-doc")
        try fixture.skill(".agents/skills/never-run", name: "never-run")
        try fixture.skill(".codex/skills/.system/imagegen", name: "imagegen")
        try fixture.json(".claude.json", ["skillUsage": [
            "lark-doc": ["usageCount": 7, "lastUsedAt": 1_789_462_013_523],
            "never-run": ["usageCount": 0, "lastUsedAt": 1_789_462_013_523],
        ]])
        let skills = fixture.scan().skills
        let used = try #require(skills.first { $0.name == "lark-doc" })
        #expect(used.usage?.count == 7)
        #expect(used.usage?.lastUsed != nil)
        #expect(try #require(skills.first { $0.name == "never-run" }).usage?.count == 0)
        // Codex 的内置技能在 Claude 的统计里本来就没有记录，nil 说的是「没有记录」，
        // 不是「没用过」。
        #expect(try #require(skills.first { $0.name == "imagegen" }).usage == nil)
    }

    @Test func damagedInstallationsAndMetadataAreVisible() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.directory(".agents/skills/incomplete")
        try fixture.link(".claude/skills/broken", target: "missing-target")
        try fixture.write(".agents/.skill-lock.json", "{invalid json")
        try fixture.write(".agents/skills/unclosed/SKILL.md", "---\nname: never\n")
        try fixture.skill(".agents/skills/.hidden", name: "hidden")
        let snapshot = fixture.scan()
        #expect(snapshot.skills.count == 3)
        #expect(snapshot.skills.allSatisfy { $0.issue != nil })
        #expect(snapshot.warnings.count == 1)
        #expect(snapshot.skills.first { $0.name == "unclosed" }?.issue?.contains("not closed") == true)
    }

    @Test func incompleteSharedSkillStillMergesItsAgentLinks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.directory(".agents/skills/incomplete")
        try fixture.json(".agents/.skill-lock.json", ["version": 3, "skills": [
            "incomplete": ["source": "example/skills", "sourceType": "github"],
        ]])
        try fixture.link(".claude/skills/incomplete", target: "../../.agents/skills/incomplete")
        let snapshot = fixture.scan()
        #expect(snapshot.skills.count == 1)
        let skill = try #require(snapshot.skills.first)
        #expect(skill.origin == .installed)
        #expect(skill.sourceTitle == "example/skills")
        #expect(Set(skill.locations.map(\.label)) == ["Shared", "Claude"])
        #expect(skill.fileURL == fixture.url(".agents/skills/incomplete")
            .resolvingSymlinksInPath().appendingPathComponent("SKILL.md"))
        #expect(skill.issue?.contains("missing") == true)
    }

    @Test func brokenAndCyclicParentLinksRemainVisibleWithoutRecursion() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.link(".claude/skills/broken", target: "missing-target")
        try fixture.link(".claude/skills/cycle", target: "cycle")
        let snapshot = fixture.scan()
        #expect(snapshot.skills.count == 2)
        #expect(Set(snapshot.skills.map(\.name)) == ["broken", "cycle"])
        #expect(snapshot.skills.allSatisfy { $0.issue?.contains("missing") == true })
    }

    @Test func commonFrontmatterScalarsPreserveNamesAndDescriptions() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(".agents/skills/folded/SKILL.md", "\u{feff}---\r\nname: 'reader''s tool' # comment\r\ndescription: >-\r\n  First line\r\n  second line.\r\n---\r\n# Body\r\n")
        try fixture.write(".agents/skills/literal/SKILL.md", "---\nname: \"Quoted tool\" # comment\ndescription: |\n  First line\n  second line.\n---\n")
        try fixture.write(".agents/skills/plain/SKILL.md", "---\nname: plain # comment\ndescription: A description:\n  with continuation.\n---\n")
        let snapshot = fixture.scan()
        #expect(snapshot.skills.allSatisfy { $0.issue == nil })
        #expect(snapshot.skills.first { $0.name == "reader's tool" }?.summary == "First line second line.")
        #expect(snapshot.skills.first { $0.name == "Quoted tool" }?.summary == "First line\nsecond line.")
        #expect(snapshot.skills.first { $0.name == "plain" }?.summary == "A description: with continuation.")
        #expect(snapshot.skills.first { $0.name == "reader's tool" }?.content.contains("# Body") == true)
    }

    @Test func emptyHomeDoesNotInventInstallations() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let snapshot = fixture.scan()
        #expect(snapshot.skills.isEmpty)
        #expect(snapshot.warnings.isEmpty)
    }

    private struct Fixture {
        let home: URL
        init() throws {
            home = FileManager.default.temporaryDirectory.appendingPathComponent("skill-catalog-\(UUID())")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }
        func url(_ path: String) -> URL { home.appendingPathComponent(path) }
        func directory(_ path: String) throws {
            try FileManager.default.createDirectory(at: url(path), withIntermediateDirectories: true)
        }
        func write(_ path: String, _ text: String) throws {
            try FileManager.default.createDirectory(at: url(path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url(path), atomically: true, encoding: .utf8)
        }
        func skill(_ path: String, name: String) throws {
            try write("\(path)/SKILL.md", "---\nname: \(name)\ndescription: Test description.\n---\n# Instructions\n")
        }
        func json(_ path: String, _ value: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: value)
            try write(path, String(decoding: data, as: UTF8.self))
        }
        func link(_ path: String, target: String) throws {
            try FileManager.default.createDirectory(at: url(path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: url(path).path, withDestinationPath: target)
        }
        func scan(_ environment: [String: String] = [:]) -> SkillCatalogSnapshot {
            SkillCatalog(home: home, environment: environment).scan()
        }
        func remove() { try? FileManager.default.removeItem(at: home) }
    }
}
