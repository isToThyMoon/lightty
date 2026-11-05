import Foundation
import Testing
@testable import lightty

/// 写用户 Agent 配置的边界：这些写法都来自用户自己的文件（Windows 同步来的换行、
/// dotfile 管理的符号链接、TOML 的点号写法），写坏了 Agent 就读不了配置。
struct ConfigFileEditTests {
    private let id = "tool@store"

    @Test func crlfPluginTableIsEditedInPlaceAndKeepsItsLineEndings() throws {
        let text = "model = \"x\"\r\n\r\n[plugins.\"tool@store\"]\r\nenabled = true # mine\r\n"
        #expect(TOMLTextEdit.pluginEnabled(id: id, in: text) == true)
        let updated = try TOMLTextEdit.setPluginEnabled(false, id: id, in: text)
        #expect(updated == "model = \"x\"\r\n\r\n[plugins.\"tool@store\"]\r\nenabled = false # mine\r\n")
    }

    @Test func crlfFileGetsNewLinesInItsOwnStyle() throws {
        let noValue = "[plugins.\"tool@store\"]\r\nother = 1\r\n"
        #expect(try TOMLTextEdit.setPluginEnabled(true, id: id, in: noValue)
            == "[plugins.\"tool@store\"]\r\nenabled = true\r\nother = 1\r\n")
        let noTable = "model = \"x\"\r\n"
        #expect(try TOMLTextEdit.setPluginEnabled(true, id: id, in: noTable)
            == "model = \"x\"\r\n\r\n[plugins.\"tool@store\"]\r\nenabled = true\r\n")
    }

    @Test func crlfMCPServerReadsAndWritesLikeAnyOther() throws {
        let text = "[mcp_servers.notion]\r\nenabled = false\r\ncommand = \"x\"\r\n"
        #expect(!TOMLTextEdit.mcpEnabled(name: "notion", in: text))
        #expect(TOMLTextEdit.mcpServers(in: text).map(\.name) == ["notion"])
        #expect(TOMLTextEdit.mcpServers(in: text).flatMap(\.lines).allSatisfy { !$0.contains("\r") })
        #expect(try TOMLTextEdit.setMCPEnabled(true, name: "notion", in: text)
            == "[mcp_servers.notion]\r\nenabled = true\r\ncommand = \"x\"\r\n")
    }

    /// 这些写法里再追加 `[plugins."tool@store"]` 就是重复定义，Codex 读不了整份配置。
    @Test(arguments: [
        "plugins.\"tool@store\".enabled = true\n",
        "plugins = { \"other@store\" = { enabled = true } }\n",
        "[plugins]\n\"tool@store\".enabled = true\n",
        "[plugins]\n\"tool@store\" = { enabled = true }\n",
    ])
    func declarationsOutsideItsOwnTableAreRefused(text: String) {
        #expect(throws: PluginWriteError.self) {
            try TOMLTextEdit.setPluginEnabled(false, id: id, in: text)
        }
    }

    @Test func dottedDeclarationsReadTheirRealState() throws {
        #expect(TOMLTextEdit.pluginEnabled(id: id, in: "plugins.\"tool@store\".enabled = true\n") == true)
        #expect(TOMLTextEdit.pluginEnabled(id: id, in: "[plugins]\n\"tool@store\".enabled = true\n") == true)
        // 别的 section 里的同名路径不是这个插件。
        #expect(TOMLTextEdit.pluginEnabled(id: id, in: "[other]\nplugins.\"tool@store\".enabled = true\n") == nil)
        // 另一个插件的点号写法不妨碍给这个插件新建表，TOML 允许。
        let other = "plugins.\"other@store\".enabled = true\n"
        #expect(try TOMLTextEdit.setPluginEnabled(true, id: id, in: other).contains("[plugins.\"tool@store\"]"))
    }

    @Test func crlfJSONKeepsItsIndentAndLineEndings() throws {
        let text = "{\r\n  \"a\": 1\r\n}\r\n"
        #expect(try JSONTextEdit.setBoolean(true, at: ["b"], in: text) == "{\r\n  \"b\": true,\r\n  \"a\": 1\r\n}\r\n")
    }

    @Test func aSymlinkedConfigStaysALinkAndItsBackupKeepsTheOriginalText() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dotfiles = root.appendingPathComponent("dotfiles.toml")
        try "enabled = true\n".write(to: dotfiles, atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("config.toml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dotfiles)

        try ConfigFile.rewrite(link, empty: "", edit: { _ in "enabled = false\n" }, verify: { _ in true })

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == dotfiles.path)
        #expect(try String(contentsOf: dotfiles, encoding: .utf8) == "enabled = false\n")
        let backup = root.appendingPathComponent("config.toml.lightty-backup")
        #expect(try String(contentsOf: backup, encoding: .utf8) == "enabled = true\n")
        // 备份若还是链接，下一次写入就把它也改了，原件就没了。
        let type = try FileManager.default.attributesOfItem(atPath: backup.path)[.type] as? FileAttributeType
        #expect(type == .typeRegular)
    }

    @Test func aBackupThatCannotBeMadeStopsTheWrite() throws {
        let root = try makeRoot()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let config = root.appendingPathComponent("config.toml")
        try "enabled = true\n".write(to: config, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        var edited = false
        #expect(throws: PluginWriteError.self) {
            try ConfigFile.rewrite(config, empty: "", edit: { _ in edited = true; return "x" }, verify: { _ in true })
        }
        #expect(!edited)
        #expect(try String(contentsOf: config, encoding: .utf8) == "enabled = true\n")
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("config-edit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
