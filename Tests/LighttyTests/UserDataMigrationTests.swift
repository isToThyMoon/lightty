import XCTest
import LighttyCore
@testable import lightty

final class UserDataMigrationTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("migration-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func seed(_ root: URL) throws -> [String: Data] {
        let files = [
            "preferences.json": Data(#"{"version":1,"values":{"lightty.accent":"pink"},"extension":true}"#.utf8),
            "session.json": Data(#"{"version":1,"windows":[]}"#.utf8),
            "session-library.json": Data(#"{"version":1,"projects":[],"assignments":[],"archivedSessions":[],"archivedProjects":[]}"#.utf8)
        ]
        for (name, data) in files { try data.write(to: root.appendingPathComponent(name)) }
        return files
    }

    func testStartupConvertsAllFilesBeforeCurrentStoresReadAndDoesNotRepeat() throws {
        let root = try directory()
        let originals = try seed(root)
        let tasks = root.appendingPathComponent("tasks")
        try FileManager.default.createDirectory(at: tasks, withIntermediateDirectories: true)
        let handoff = tasks.appendingPathComponent("example.md")
        let body = Data("Handoff stays byte-identical, even without JSON headers.".utf8)
        try body.write(to: handoff)
        let backup = try XCTUnwrap(UserDataMigration.run(in: root))
        for (name, bytes) in originals { XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent(name)), bytes) }
        for format in PersistenceFormat.allCases {
            let url = root.appendingPathComponent(format.fileName)
            try UserDataSchemas.validate(Data(contentsOf: url), as: format)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("session.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("session-library.json").path))
        XCTAssertEqual(try Data(contentsOf: handoff), body)
        XCTAssertEqual(FilePreferences(fileURL: root.appendingPathComponent("preferences.json")).string(forKey: "lightty.accent"), "pink")
        XCTAssertNotNil(WorkspaceStore(fileURL: root.appendingPathComponent("workspace.json")).load())
        let before = try Data(contentsOf: root.appendingPathComponent("preferences.json"))
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("workspace.json").path)
        XCTAssertNil(try UserDataMigration.run(in: root, hasOtherInstance: { true }), "No conversion needed on subsequent launches")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("preferences.json")), before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("workspace.json").path)[.modificationDate] as? Date,
                       attributes[.modificationDate] as? Date)
    }

    func testInvalidOrFutureFilePreventsAllConversions() throws {
        for invalid in ["broken", #"{"format":"lightty.organization","version":99,"projects":[],"assignments":[]}"#] {
            let root = try directory()
            let originals = try seed(root)
            let badFile = root.appendingPathComponent("session-library.json")
            try Data(invalid.utf8).write(to: badFile)
            XCTAssertThrowsError(try UserDataMigration.run(in: root))
            for name in ["preferences.json", "session.json"] {
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), originals[name])
            }
            XCTAssertEqual(try Data(contentsOf: badFile), Data(invalid.utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("backups").path))
        }
    }

    func testOtherRunningInstanceBlocksUpgradeWithoutWritingData() throws {
        let root = try directory(), originals = try seed(root)
        XCTAssertThrowsError(try UserDataMigration.run(in: root, hasOtherInstance: { true }))
        for (name, bytes) in originals { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), bytes) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("backups").path))
    }

    func testInterruptedRenameCanRetryButConflictingCurrentFileIsNeverOverwritten() throws {
        let root = try directory()
        let originals = try seed(root)
        let target = root.appendingPathComponent("workspace.json")
        let current = try JSONEncoder().encode(WorkspaceSnapshot(windows: []))
        try current.write(to: target) // interruption after writing the new name
        XCTAssertNotNil(try UserDataMigration.run(in: root))
        XCTAssertEqual(try Data(contentsOf: target), current)
        // An old build later creates a different snapshot: never replace the current one.
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: originals["session.json"]!) as? [String: Any])
        old["extension"] = "different"
        let changed = try JSONSerialization.data(withJSONObject: old)
        try changed.write(to: root.appendingPathComponent("session.json"))
        XCTAssertThrowsError(try UserDataMigration.run(in: root))
        XCTAssertEqual(try Data(contentsOf: target), current)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("session.json")), changed)
    }

    func testFreshInstallNeedsNoMigration() throws {
        let root = try directory()
        XCTAssertNil(try UserDataMigration.run(in: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("backups").path))
    }

}
