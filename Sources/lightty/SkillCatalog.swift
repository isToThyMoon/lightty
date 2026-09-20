import Foundation

/// Installation provenance, independent of the user's personal organization.
/// Plugin-provided skills are not listed here: a plugin's contents belong to the
/// plugin, and the Plugins page reads them from `PluginCatalog`.
enum SkillOrigin: String, Codable, Sendable {
    case installed, local, builtIn
}

struct SkillLocation: Equatable, Sendable {
    let label: String
    let url: URL
}

struct SkillRecord: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let summary: String
    let content: String
    let fileURL: URL
    let sourceID: String
    let sourceTitle: String
    let sourceURL: URL?
    let origin: SkillOrigin
    var locations: [SkillLocation]
    let issue: String?
    /// Claude Code 的使用计数；Codex 不记这个，所以这里为 nil 只代表「没有记录」，
    /// 不代表「没用过」。
    var usage: UsageRecord? = nil
}

struct SkillCatalogSnapshot: Sendable {
    var skills: [SkillRecord]
    var warnings: [String]
}

/// Reads existing installations. Never writes lock files, links, or skill contents.
struct SkillCatalog {
    private let home: URL
    private let environment: [String: String]

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.home = home
        self.environment = environment
    }

    func scan() -> SkillCatalogSnapshot {
        var reader = Reader()
        let shared = home.appendingPathComponent(".agents/skills")
        let codex = environmentURL("CODEX_HOME") ?? home.appendingPathComponent(".codex")
        let lock = environmentURL("XDG_STATE_HOME")?.appendingPathComponent("skills/.skill-lock.json")
            ?? home.appendingPathComponent(".agents/.skill-lock.json")
        let sources = reader.lockSources(at: lock)
        reader.scanSkills(at: shared, label: "Shared", source: .local, lockSources: sources)
        for (label, root) in [
            ("Claude", home.appendingPathComponent(".claude/skills")),
            ("Codex", codex.appendingPathComponent("skills")),
            ("Cursor", home.appendingPathComponent(".cursor/skills")),
        ] {
            reader.scanSkills(at: root, label: label, source: .local)
        }
        reader.scanSkills(at: codex.appendingPathComponent("skills/.system"), label: "Codex built-in",
                          source: Source(id: "builtin:codex", title: "Codex", url: nil, origin: .builtIn))
        let usage = ClaudeUsage.read(home: home).skills
        for (id, record) in reader.records {
            reader.records[id]?.usage = usage[record.name]
        }
        return SkillCatalogSnapshot(skills: reader.records.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }, warnings: reader.warnings)
    }

    private func environmentURL(_ key: String) -> URL? {
        guard let path = environment[key], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private struct Source {
        let id: String
        let title: String
        let url: URL?
        let origin: SkillOrigin
        static let local = Source(id: "local", title: "Local", url: nil, origin: .local)
    }

    private struct Reader {
        var records: [String: SkillRecord] = [:]
        var warnings: [String] = []
        private let files = FileManager.default

        mutating func lockSources(at url: URL) -> [String: Source] {
            guard let json = jsonObject(at: url) else { return [:] }
            guard let skills = json["skills"] as? [String: Any] else {
                warnings.append("Invalid skills lock: \(url.path)")
                return [:]
            }
            var result: [String: Source] = [:]
            for (name, value) in skills {
                guard let entry = value as? [String: Any], let source = entry["source"] as? String,
                      !source.isEmpty else {
                    warnings.append("Invalid source for \(name): \(url.path)")
                    continue
                }
                let sourceLink = entry["sourceBaseUrl"] as? String ?? entry["sourceUrl"] as? String
                let link = sourceLink.flatMap(URL.init(string:))
                    ?? (entry["sourceType"] as? String == "github" ? URL(string: "https://github.com/\(source)") : nil)
                let title = entry["sourceType"] as? String == "local"
                    ? URL(fileURLWithPath: source).lastPathComponent
                    : (source == "open.feishu.cn" ? "Lark CLI" : source)
                result[name] = Source(id: "installed:\(source)", title: title,
                                      url: link, origin: .installed)
            }
            return result
        }

        mutating func scanSkills(at root: URL, label: String, source: Source,
                                 lockSources: [String: Source] = [:]) {
            for child in directories(at: root) {
                addSkill(at: child, label: label, source: lockSources[child.lastPathComponent] ?? source)
            }
        }

        mutating func addSkill(at directory: URL, label: String, source: Source) {
            let file = directory.appendingPathComponent("SKILL.md")
            // Resolve the directory first: Foundation leaves the parent link intact
            // when resolving a full path whose SKILL.md leaf does not exist.
            let canonical = directory.resolvingSymlinksInPath()
                .appendingPathComponent("SKILL.md").resolvingSymlinksInPath().standardizedFileURL
            let id = canonical.path
            let location = SkillLocation(label: label, url: file)
            if var existing = records[id] {
                if !existing.locations.contains(location) { existing.locations.append(location) }
                records[id] = existing
                return
            }
            var content = ""
            var issues: [String] = []
            do {
                let attributes = try files.attributesOfItem(atPath: canonical.path)
                if (attributes[.size] as? NSNumber)?.intValue ?? 0 > 2_000_000 {
                    issues.append("SKILL.md exceeds the 2 MB preview limit.")
                } else {
                    content = try String(contentsOf: canonical, encoding: .utf8)
                }
            } catch {
                if !files.fileExists(atPath: file.path) {
                    issues.append("SKILL.md is missing or its symbolic link is broken.")
                } else {
                    issues.append("Cannot read SKILL.md: \(error.localizedDescription)")
                }
            }
            let metadata = SkillMetadata.parse(content)
            if let problem = metadata.issue { issues.append(problem) }
            records[id] = SkillRecord(id: id, name: metadata.name ?? directory.lastPathComponent,
                                      summary: metadata.summary ?? "", content: content, fileURL: canonical,
                                      sourceID: source.id, sourceTitle: source.title, sourceURL: source.url,
                                      origin: source.origin, locations: [location],
                                      issue: issues.isEmpty ? nil : issues.joined(separator: "\n"))
        }

        private mutating func directories(at root: URL) -> [URL] {
            guard files.fileExists(atPath: root.path) else { return [] }
            do {
                return try files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                     options: [.skipsHiddenFiles]).filter { url in
                    // Inspect the link itself before asking about its target. Broken
                    // and cyclic links can fail directory resolution but still need a row.
                    if (try? files.destinationOfSymbolicLink(atPath: url.path)) != nil { return true }
                    return (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            } catch {
                warnings.append("Cannot scan \(root.path): \(error.localizedDescription)")
                return []
            }
        }

        private mutating func jsonObject(at url: URL) -> [String: Any]? {
            guard files.fileExists(atPath: url.path) else { return nil }
            do {
                guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                    warnings.append("Invalid metadata: \(url.path)")
                    return nil
                }
                return object
            } catch {
                warnings.append("Cannot read metadata \(url.path): \(error.localizedDescription)")
                return nil
            }
        }
    }
}

/// Small frontmatter reader for the scalar fields used by Agent Skills. Retains
/// the original document for preview; unsupported YAML is never rewritten.
/// Shared with `PluginCatalog`: a plugin's skills carry the same frontmatter.
struct SkillMetadata {
    var name: String?
    var summary: String?
    var issue: String?

    static func parse(_ text: String) -> Self {
        guard !text.isEmpty else { return Self() }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}"))
            .components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return Self(issue: "SKILL.md has no YAML frontmatter.")
        }
        guard let end = lines.indices.dropFirst().first(where: {
            ["---", "..."].contains(lines[$0].trimmingCharacters(in: .whitespaces))
        }) else { return Self(issue: "SKILL.md frontmatter is not closed.") }
        var result = Self()
        var index = 1
        while index < end {
            let line = lines[index]
            index += 1
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard key == "name" || key == "description" else { continue }
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("|") || value.hasPrefix(">") {
                let folded = value.hasPrefix(">")
                var block: [String] = []
                while index < end && (lines[index].hasPrefix(" ") || lines[index].hasPrefix("\t") || lines[index].isEmpty) {
                    block.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                value = block.joined(separator: folded ? " " : "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                // YAML plain/quoted scalars may continue on indented lines.
                while index < end && (lines[index].hasPrefix(" ") || lines[index].hasPrefix("\t")) {
                    value += " " + lines[index].trimmingCharacters(in: .whitespaces)
                    index += 1
                }
                if let decoded = scalar(value) { value = decoded }
                else { result.issue = "Unsupported or malformed frontmatter scalar: \(key)."; continue }
            }
            if !value.isEmpty {
                if key == "name" { result.name = value } else { result.summary = value }
            }
        }
        return result
    }

    private static func scalar(_ value: String) -> String? {
        if value.hasPrefix("\"") {
            // JSON string decoding handles the common YAML double-quoted escapes.
            var escaped = false
            var closing: String.Index?
            for index in value.indices.dropFirst() {
                let character = value[index]
                if escaped { escaped = false; continue }
                if character == "\\" { escaped = true; continue }
                if character == "\"" { closing = index; break }
            }
            guard let closing else { return nil }
            let tail = value[value.index(after: closing)...].trimmingCharacters(in: .whitespaces)
            guard tail.isEmpty || tail.hasPrefix("#"),
                  let data = String(value[...closing]).data(using: .utf8),
                  let string = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String else { return nil }
            return string
        }
        if value.hasPrefix("'") {
            guard let closing = value.dropFirst().lastIndex(of: "'") else { return nil }
            let tail = value[value.index(after: closing)...].trimmingCharacters(in: .whitespaces)
            guard tail.isEmpty || tail.hasPrefix("#") else { return nil }
            return String(value[value.index(after: value.startIndex)..<closing]).replacingOccurrences(of: "''", with: "'")
        }
        guard !value.hasPrefix("["), !value.hasPrefix("{"), !value.hasPrefix("&"), !value.hasPrefix("*") else { return nil }
        return String(value.components(separatedBy: " #").first ?? value).trimmingCharacters(in: .whitespaces)
    }
}
