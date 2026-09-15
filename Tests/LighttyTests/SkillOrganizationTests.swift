import Foundation
import Testing

@testable import lightty

struct SkillOrganizationTests {
    @Test func persistsIndependentAnnotations() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("nested/organization.json")
        let organization = SkillOrganization(fileURL: file)
        #expect(organization.loadError == nil)
        #expect(organization.annotation(for: "unknown") == SkillAnnotation())

        try organization.setFavorite(true, for: "first")
        try organization.setMine(true, for: "first")
        try organization.setMine(true, for: "second")
        try organization.setFavorite(false, for: "first")

        let restored = SkillOrganization(fileURL: file)
        #expect(restored.loadError == nil)
        #expect(restored.annotation(for: "first") == SkillAnnotation(isMine: true))
        #expect(restored.annotation(for: "second") == SkillAnnotation(isMine: true))
        try restored.setMine(false, for: "first")
        let reopened = SkillOrganization(fileURL: file)
        #expect(reopened.annotation(for: "first") == SkillAnnotation())
        #expect(reopened.annotation(for: "second").isMine)
    }

    @Test(arguments: [
        "not JSON",
        #"{"version":2,"annotations":{}}"#,
        #"{"version":1,"annotations":{"first":{"favorite":"yes","isMine":false}}}"#,
    ])
    func preservesUnreadableDocument(contents: String) throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("organization.json")
        let original = Data(contents.utf8)
        try original.write(to: file)

        let organization = SkillOrganization(fileURL: file)
        #expect(organization.loadError != nil)
        #expect(throws: (any Error).self) {
            try organization.setFavorite(true, for: "first")
        }
        #expect(throws: (any Error).self) {
            try organization.setMine(true, for: "first")
        }
        #expect(organization.annotation(for: "first") == SkillAnnotation())
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func failedSaveKeepsPreviousState() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("organization.json")
        let organization = SkillOrganization(fileURL: file)
        try organization.setFavorite(true, for: "first")

        // 用同名目录可靠制造写入失败，不依赖运行用户的文件权限。
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            try organization.setMine(true, for: "first")
        }
        #expect(organization.annotation(for: "first") == SkillAnnotation(favorite: true))

        try FileManager.default.removeItem(at: file)
        try organization.setMine(true, for: "first")
        let restored = SkillOrganization(fileURL: file)
        #expect(restored.annotation(for: "first") == SkillAnnotation(favorite: true, isMine: true))
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lightty-skill-organization-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
