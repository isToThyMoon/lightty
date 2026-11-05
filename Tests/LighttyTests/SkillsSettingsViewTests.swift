import AppKit
import Testing
@testable import lightty

@Suite(.serialized)
@MainActor
struct SkillsSettingsViewTests {
    private func fixture(localize: @escaping (String) -> String = { L($0) }) throws -> (SkillsSettingsView, URL) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skills-view-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func skill(_ name: String, source: String = "mattpocock/skills", origin: SkillOrigin = .installed,
                   summary: String = "Review code for clear interfaces and maintainable behavior.",
                   title: String? = nil) throws -> SkillRecord {
            let file = root.appendingPathComponent(name + "/SKILL.md")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let content = """
            ---
            name: \(name)
            description: \(summary)
            ---

            # \(name)

            Read the changes, understand the intent, and review the code against the project's conventions.

            ## Start with the problem

            Describe the behavior that changed. Follow the data from its input to the user-visible result.

            ## Review checklist

            - Keep interfaces small and responsibilities clear.
            - Look for failure paths and missing validation.
            - Prefer a concrete example over an abstract recommendation.

            ## Example

            ```swift
            struct Review {
                let findings: [Finding]
                let summary: String
            }
            ```

            Report actionable findings with a file path and a reason.
            """
            try content.write(to: file, atomically: true, encoding: .utf8)
            return SkillRecord(id: name, name: name, summary: summary, content: content, fileURL: file,
                               sourceID: source, sourceTitle: title ?? source,
                               sourceURL: URL(string: "https://example.com/skills"),
                               origin: origin, locations: [.init(label: "Shared", url: file), .init(label: "Claude", url: file)], issue: nil)
        }
        let records = try [
            skill("code-review"), skill("codebase-design", summary: "Design deep modules with small, useful interfaces."),
            skill("diagnosing-bugs", summary: "Investigate a bug with evidence and a repeatable test."),
            skill("research", summary: "Find primary sources and summarize what they establish."),
            skill("tdd", summary: "Build behavior through red, green, and refactor."),
            skill("lark-doc", source: "Lark CLI", summary: "读取、创建和编辑飞书云文档。"),
            skill("lark-im", source: "Lark CLI", summary: "收发消息和管理群聊。"),
            skill("weekly-summary", source: "Local", origin: .local, summary: "整理本周工作，记录关键进展。"),
            skill("skill-creator", source: "Codex", origin: .builtIn),
        ]
        let store = SkillOrganization(fileURL: root.appendingPathComponent("organization.json"))
        let view = SkillsSettingsView(organization: store, snapshot: .init(skills: records, warnings: []),
                                     preferences: FilePreferences(fileURL: root.appendingPathComponent("layout.json")), localize: localize)
        return (view, root)
    }

    @Test(arguments: ["en", "zh-Hans"])
    func threeColumnsRemainUsableAndRenderInBothAppearances(language: String) throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/lightty/Resources")
        let bundle = try #require(Bundle(url: resources.appendingPathComponent("\(language).lproj")))
        let (view, root) = try fixture { bundle.localizedString(forKey: $0, value: $0, table: nil) }
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsView(page: .skills, skillsView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 760),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = settings
        defer { window.contentView = nil; window.close() }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            settings.appearance = NSAppearance(named: appearance)
            for width in [CGFloat(1280), 1080, 900] {
                window.setContentSize(NSSize(width: width, height: 760))
                settings.needsLayout = true
                settings.layoutSubtreeIfNeeded()
                let text = try #require(descendants(view).compactMap { $0 as? NSTextView }.first { $0.identifier?.rawValue == "skill-document" })
                #expect(text.string.contains("Start with the problem"))
                #expect(!text.isEditable)
                if let path = ProcessInfo.processInfo.environment["LIGHTTY_UI_SNAPSHOT_DIR"] {
                    let directory = URL(fileURLWithPath: path)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try captureSettingsWindow(window, to: directory.appendingPathComponent(
                        "settings-skills-\(language)-\(appearance.rawValue)-\(Int(width)).png"))
                }
            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
