import Foundation

/// 对用户 JSON 配置的定点手术：只重写 `path` 指向的那一个布尔值，其余字节原样保留。
/// 不做「读成对象 → 改 → 再序列化」的往返——那会打乱键序、抹掉缩进风格，
/// 还会把我们不认识的键按自己的规则重排。
enum JSONTextEdit {
    static func setBoolean(_ value: Bool, at path: [String], in text: String) throws -> String {
        guard !path.isEmpty else { return text }
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}\n" : text
        var chars = Array(source)
        var parser = Parser(chars: chars)
        let root: Node
        do {
            root = try parser.parseValue()
        } catch {
            throw PluginWriteError.unsupportedShape(path: "JSON", detail: "the document could not be scanned")
        }
        guard root.isObject else {
            throw PluginWriteError.unsupportedShape(path: "JSON", detail: "the top level is not an object")
        }
        var node = root
        var depth = 0
        while depth < path.count - 1, let member = node.members.first(where: { $0.key == path[depth] }) {
            guard member.value.isObject else {
                throw PluginWriteError.unsupportedShape(path: "JSON", detail: "\(path[depth]) is not an object")
            }
            node = member.value
            depth += 1
        }
        let literal = value ? "true" : "false"
        if depth == path.count - 1, let member = node.members.first(where: { $0.key == path[depth] }) {
            chars.replaceSubrange(member.value.start..<member.value.end, with: Array(literal))
            return String(chars)
        }
        // 缺失的那几层一次补齐，例如 `"enabledPlugins": {"name@market": true}`。
        var insertion = literal
        for key in path[(depth + 1)...].reversed() {
            insertion = "{\"\(escape(key))\": \(insertion)}"
        }
        return String(insert(key: path[depth], literal: insertion, into: node, chars: chars))
    }

    /// 校验用的独立实现：走标准解析，不复用上面的扫描器。
    static func boolean(at path: [String], in text: String) -> Bool? {
        guard let data = text.data(using: .utf8),
              var current = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in path.dropLast() {
            guard let next = current[key] as? [String: Any] else { return nil }
            current = next
        }
        guard let last = path.last else { return nil }
        return current[last] as? Bool
    }

    private static func escape(_ key: String) -> String {
        key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func insert(key: String, literal: String, into node: Node, chars: [Character]) -> [Character] {
        var chars = chars
        let member = "\"\(escape(key))\": \(literal)"
        if let first = node.members.first {
            // 成员各占一行时沿用它们的缩进，挤在一行里时也跟着挤在一行里。
            if let indent = ownLineIndent(before: first.keyStart, in: chars) {
                chars.insert(contentsOf: Array(member + ",\n" + indent), at: first.keyStart)
            } else {
                chars.insert(contentsOf: Array(member + ", "), at: first.keyStart)
            }
            return chars
        }
        let outer = lineIndent(containing: node.start, in: chars)
        chars.replaceSubrange((node.start + 1)..<(node.end - 1),
                              with: Array("\n" + outer + "  " + member + "\n" + outer))
        return chars
    }

    /// 行首到 `position` 只有空白时返回那段空白；否则返回 nil，表示这一行还有别的内容。
    private static func ownLineIndent(before position: Int, in chars: [Character]) -> String? {
        var start = position
        while start > 0, chars[start - 1] != "\n" { start -= 1 }
        let prefix = chars[start..<position]
        guard prefix.allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil }
        return String(prefix)
    }

    private static func lineIndent(containing position: Int, in chars: [Character]) -> String {
        var start = position
        while start > 0, chars[start - 1] != "\n" { start -= 1 }
        var end = start
        while end < chars.count, chars[end] == " " || chars[end] == "\t" { end += 1 }
        return String(chars[start..<end])
    }

    private final class Node {
        let start: Int
        var end = 0
        let isObject: Bool
        var members: [(key: String, keyStart: Int, value: Node)] = []
        init(start: Int, isObject: Bool) {
            self.start = start
            self.isObject = isObject
        }
    }

    private struct ScanError: Error {}

    /// 只求每个值的字节区间，不构造任何 Swift 值。
    private struct Parser {
        let chars: [Character]
        var index = 0

        mutating func parseValue() throws -> Node {
            skipSpace()
            guard index < chars.count else { throw ScanError() }
            let start = index
            switch chars[index] {
            case "{":
                let node = Node(start: start, isObject: true)
                index += 1
                skipSpace()
                if index < chars.count, chars[index] == "}" {
                    index += 1
                    node.end = index
                    return node
                }
                while true {
                    skipSpace()
                    guard index < chars.count, chars[index] == "\"" else { throw ScanError() }
                    let keyStart = index
                    let key = try parseString()
                    skipSpace()
                    guard index < chars.count, chars[index] == ":" else { throw ScanError() }
                    index += 1
                    node.members.append((key, keyStart, try parseValue()))
                    skipSpace()
                    guard index < chars.count else { throw ScanError() }
                    if chars[index] == "," { index += 1; continue }
                    guard chars[index] == "}" else { throw ScanError() }
                    index += 1
                    node.end = index
                    return node
                }
            case "[":
                let node = Node(start: start, isObject: false)
                index += 1
                skipSpace()
                if index < chars.count, chars[index] == "]" {
                    index += 1
                    node.end = index
                    return node
                }
                while true {
                    _ = try parseValue()
                    skipSpace()
                    guard index < chars.count else { throw ScanError() }
                    if chars[index] == "," { index += 1; continue }
                    guard chars[index] == "]" else { throw ScanError() }
                    index += 1
                    node.end = index
                    return node
                }
            case "\"":
                _ = try parseString()
            default:
                while index < chars.count, !",}] \t\r\n".contains(chars[index]) { index += 1 }
                guard index > start else { throw ScanError() }
            }
            let node = Node(start: start, isObject: false)
            node.end = index
            return node
        }

        private mutating func skipSpace() {
            while index < chars.count, chars[index].isWhitespace { index += 1 }
        }

        private mutating func parseString() throws -> String {
            let start = index
            index += 1
            while index < chars.count {
                if chars[index] == "\\" { index += 2; continue }
                if chars[index] == "\"" {
                    index += 1
                    let literal = String(chars[start..<index])
                    guard let data = literal.data(using: .utf8),
                          let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String
                    else { throw ScanError() }
                    return value
                }
                index += 1
            }
            throw ScanError()
        }
    }
}

/// 对 Codex `config.toml` 的按行定点编辑：找到（或补出）`[plugins."<id>"]` 一张表，
/// 只动里面的 `enabled`。仓库没有 TOML 依赖，也不该为一个布尔值把整份文档往返一遍——
/// 那会连注释、键序和用户自己的排版一起丢掉。
enum TOMLTextEdit {
    /// 配置里登记过的插件。值是 `enabled`；表在但没写 `enabled` 记为 false，
    /// 不替 Codex 猜一个默认开启。表不在则整个键不存在，那是「只有缓存」。
    static func plugins(in text: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        var current: String?
        for line in text.components(separatedBy: "\n") {
            if let header = header(of: line) {
                current = pluginID(inHeader: header)
                if let current { result[current] = result[current] ?? false }
                continue
            }
            guard let current, let value = enabledValue(in: line) else { continue }
            result[current] = value
        }
        return result
    }

    static func pluginEnabled(id: String, in text: String) -> Bool? { plugins(in: text)[id] }

    static func setPluginEnabled(_ value: Bool, id: String, in text: String) throws -> String {
        var lines = text.components(separatedBy: "\n")
        let literal = value ? "true" : "false"
        var tableStart: Int?
        var tableEnd = lines.count
        var insidePlainPlugins = false
        for (index, line) in lines.enumerated() {
            guard let header = header(of: line) else {
                // `[plugins]` 里用行内表写同一个插件的文件不在我们的编辑口径内：
                // 再追加一张同名表就是重复键。宁可报错，也不把用户的配置改坏。
                if insidePlainPlugins, key(of: line) == id {
                    throw PluginWriteError.unsupportedShape(
                        path: "config.toml", detail: "\(id) is declared inside a [plugins] table")
                }
                continue
            }
            insidePlainPlugins = header == "plugins"
            if tableStart != nil {
                tableEnd = index
                break
            }
            if pluginID(inHeader: header) == id { tableStart = index }
        }
        guard let tableStart else {
            var result = text
            if !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
            if !result.isEmpty { result += "\n" }
            return result + "[plugins.\"\(id)\"]\nenabled = \(literal)\n"
        }
        // 按键名认，不按值认：值写成别的东西时也该被改写，而不是再补一行重复键。
        for index in (tableStart + 1)..<tableEnd where key(of: lines[index]) == "enabled" {
            let line = lines[index]
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            // 行尾注释是用户写给自己的，跟着保留。
            let comment = line.firstIndex(of: "#").map { " " + String(line[$0...]) } ?? ""
            lines[index] = indent + "enabled = " + literal + comment
            return lines.joined(separator: "\n")
        }
        lines.insert("enabled = " + literal, at: tableStart + 1)
        return lines.joined(separator: "\n")
    }

    // MARK: - 独立 MCP server

    /// `[mcp_servers.<name>]` 连同它的子表（`.env` 之类）的原文。值不解析：
    /// 展示用原文，判断只看少数几个键，为此写一个 TOML 解析器换不来什么。
    static func mcpServers(in text: String) -> [(name: String, lines: [String])] {
        var result: [(name: String, lines: [String])] = []
        var slots: [String: Int] = [:]
        var current: String?
        for line in text.components(separatedBy: "\n") {
            if let header = header(of: line) {
                current = serverName(inHeader: header)
                guard let current else { continue }
                if slots[current] == nil {
                    slots[current] = result.count
                    result.append((current, []))
                }
            }
            guard let current, let slot = slots[current] else { continue }
            result[slot].lines.append(line)
        }
        return result
    }

    /// 写了 `enabled = false` 才算停用。这一条和插件相反：登记过的 server 默认就是
    /// 开着的，否则 config.toml 里没写 enabled 的那些永远用不了。
    /// 只认主表里的键，子表（`.env`）里同名的环境变量不作数。
    static func mcpEnabled(name: String, in text: String) -> Bool {
        var inTable = false
        for line in text.components(separatedBy: "\n") {
            if let header = header(of: line) {
                inTable = isServerTable(header, name: name)
                continue
            }
            guard inTable, let value = enabledValue(in: line) else { continue }
            return value
        }
        return true
    }

    static func setMCPEnabled(_ value: Bool, name: String, in text: String) throws -> String {
        var lines = text.components(separatedBy: "\n")
        let literal = value ? "true" : "false"
        var tableStart: Int?
        var tableEnd = lines.count
        for (index, line) in lines.enumerated() {
            guard let header = header(of: line) else { continue }
            if tableStart != nil { tableEnd = index; break }
            if isServerTable(header, name: name) { tableStart = index }
        }
        // 不替用户新建一张表：这一页只改已登记的 server，没登记的该由 Agent 自己写。
        guard let tableStart else {
            throw PluginWriteError.unsupportedShape(path: "config.toml",
                                                    detail: "\(name) has no [mcp_servers] table")
        }
        for index in (tableStart + 1)..<tableEnd where key(of: lines[index]) == "enabled" {
            let line = lines[index]
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            let comment = line.firstIndex(of: "#").map { " " + String(line[$0...]) } ?? ""
            lines[index] = indent + "enabled = " + literal + comment
            return lines.joined(separator: "\n")
        }
        lines.insert("enabled = " + literal, at: tableStart + 1)
        return lines.joined(separator: "\n")
    }

    private static func isServerTable(_ header: String, name: String) -> Bool {
        header == "mcp_servers.\(name)" || header == "mcp_servers.\"\(name)\""
    }

    /// 子表也归它的 server：`mcp_servers.node_repl.env` 属于 `node_repl`。
    private static func serverName(inHeader header: String) -> String? {
        guard header.hasPrefix("mcp_servers.") else { return nil }
        var rest = String(header.dropFirst("mcp_servers.".count)).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("\"") {
            guard let closing = rest.dropFirst().firstIndex(of: "\"") else { return nil }
            return String(rest[rest.index(after: rest.startIndex)..<closing])
        }
        if let dot = rest.firstIndex(of: ".") { rest = String(rest[..<dot]) }
        return rest.isEmpty ? nil : rest
    }

    /// 表头文字，不含方括号；不是表头返回 nil。
    private static func header(of line: String) -> String? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") else { return nil }
        if let comment = commentStart(of: trimmed) {
            trimmed = String(trimmed[..<comment]).trimmingCharacters(in: .whitespaces)
        }
        guard trimmed.hasSuffix("]") else { return nil }
        return String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }

    private static func pluginID(inHeader header: String) -> String? {
        guard header.hasPrefix("plugins.") else { return nil }
        let rest = String(header.dropFirst("plugins.".count)).trimmingCharacters(in: .whitespaces)
        for quote in ["\"", "'"] where rest.hasPrefix(quote) && rest.hasSuffix(quote) && rest.count >= 2 {
            return String(rest.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
        }
        return rest.isEmpty ? nil : rest
    }

    /// 赋值行的键，带引号的去引号；不是赋值行返回 nil。
    private static func key(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { return nil }
        let raw = String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces)
        for quote in ["\"", "'"] where raw.hasPrefix(quote) && raw.hasSuffix(quote) && raw.count >= 2 {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }

    private static func enabledValue(in line: String) -> Bool? {
        guard key(of: line) == "enabled" else { return nil }
        let value = line.drop { $0 != "=" }.dropFirst().trimmingCharacters(in: .whitespaces)
        let token = value.split(whereSeparator: { $0 == " " || $0 == "#" }).first.map(String.init)
        guard token == "true" || token == "false" else { return nil }
        return token == "true"
    }

    private static func commentStart(of line: String) -> String.Index? {
        var quote: Character?
        for index in line.indices {
            let character = line[index]
            if let open = quote {
                if character == open { quote = nil }
                continue
            }
            if character == "\"" || character == "'" { quote = character; continue }
            if character == "#" { return index }
        }
        return nil
    }
}

/// Agent 配置文件的写入口径，插件与 MCP server 共用。
enum ConfigFile {
    /// 备份一次、改一次、验一次、原子换一次。验不过就整份丢弃，绝不落地半成品。
    static func rewrite(_ url: URL, empty: String,
                         edit: (String) throws -> String,
                         verify: (String) -> Bool) throws {
        let files = FileManager.default
        var text = empty
        if files.fileExists(atPath: url.path) {
            do {
                text = try String(contentsOf: url, encoding: .utf8)
            } catch {
                throw PluginWriteError.unreadable(path: url.path, reason: error.localizedDescription)
            }
            // 首次改动前留一份原件；之后的改动不再覆盖这份备份。
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent(url.lastPathComponent + ".lightty-backup")
            if !files.fileExists(atPath: backup.path) {
                try? files.copyItem(at: url, to: backup)
            }
        }
        let updated = try edit(text)
        guard verify(updated) else { throw PluginWriteError.notApplied(path: url.path) }
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).lightty-\(UUID().uuidString)")
        do {
            try Data(updated.utf8).write(to: temp)
            if files.fileExists(atPath: url.path) {
                _ = try files.replaceItemAt(url, withItemAt: temp)
            } else {
                try files.moveItem(at: temp, to: url)
            }
        } catch {
            try? files.removeItem(at: temp)
            throw error
        }
    }
}
