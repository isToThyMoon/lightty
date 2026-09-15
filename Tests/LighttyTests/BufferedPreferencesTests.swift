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

    /// 写失败后 lastError 保留、文件不被覆盖；修复后再写一次才成功。
    /// set/remove/flush/reopen 的基本语义在 FilePreferencesTests 里。
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
