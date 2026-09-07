import Foundation
import Testing
@testable import lightty

struct BufferedPreferencesTests {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("preferences.json"))
    }

    @Test func editsAreImmediatelyReadableAndFlushPersistsLatestValue() throws {
        try fixture { file in
            let store = FilePreferences(fileURL: file)
            defer { store.flush() }
            for value in 0..<100 { store.set(value, forKey: "counter") }
            #expect(store.double(forKey: "counter") == 99)
            store.set("temporary", forKey: "removed")
            store.removeObject(forKey: "removed")
            store.flush()
            let reopened = FilePreferences(fileURL: file)
            #expect(reopened.double(forKey: "counter") == 99)
            #expect(reopened.object(forKey: "removed") == nil)
            #expect(store.lastError == nil)
        }
    }

    @Test func failedBatchSurvivesUntilExplicitRetry() throws {
        try fixture { file in
            let store = FilePreferences(fileURL: file)
            let original = try Data(contentsOf: file)
            let corrupt = Data("broken".utf8)
            try corrupt.write(to: file)
            store.set("first", forKey: "choice")
            store.flush()
            #expect(store.lastError != nil)
            #expect(try Data(contentsOf: file) == corrupt)
            try original.write(to: file)
            store.set("latest", forKey: "choice")
            store.flush()
            #expect(store.lastError == nil)
            #expect(FilePreferences(fileURL: file).string(forKey: "choice") == "latest")
        }
    }
}
