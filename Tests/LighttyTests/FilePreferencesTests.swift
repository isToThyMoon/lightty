import Foundation
import XCTest
@testable import lightty

final class FilePreferencesTests: XCTestCase {
    private func temporaryFile() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("preferences-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("preferences.json")
    }
    func testFreshPreferencesAndRemovedValuesStayRemoved() throws {
        let file = try temporaryFile()
        let store = FilePreferences(fileURL: file)
        XCTAssertNil(store.lastError)
        store.set("blue", forKey: "lightty.accent")
        XCTAssertEqual(store.string(forKey: "lightty.accent"), "blue")
        XCTAssertNil(store.object(forKey: "AppleLanguages"))
        store.removeObject(forKey: "lightty.accent")
        store.flush()
        let reopened = FilePreferences(fileURL: file)
        XCTAssertNil(reopened.object(forKey: "lightty.accent"))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }
    func testAtomicMergeAndUnknownFieldsSurvive() throws {
        let file = try temporaryFile()
        try Data(#"{"format":"lightty.preferences","version":1,"extensions":{"example":true},"values":{"future.option":[1,2]}}"#.utf8).write(to: file)
        let first = FilePreferences(fileURL: file), second = FilePreferences(fileURL: file)
        first.set("dark", forKey: "lightty.appearance")
        second.set("en", forKey: "lightty.language")
        first.flush()
        second.flush()
        let read = FilePreferences(fileURL: file)
        XCTAssertEqual(read.string(forKey: "lightty.appearance"), "dark")
        XCTAssertEqual(read.string(forKey: "lightty.language"), "en")
        XCTAssertNotNil(read.object(forKey: "future.option"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertNotNil(document["extensions"])
    }
    func testNewerOrCorruptFilesNeverGetOverwritten() throws {
        for payload in [#"{"format":"lightty.preferences","version":99,"values":{}}"#,
                        #"{"format":"lightty.workspace","version":1,"values":{}}"#,
                        #"{"version":1,"values":{}}"#, "broken"] {
            let file = try temporaryFile()
            let bytes = Data(payload.utf8)
            try bytes.write(to: file)
            let store = FilePreferences(fileURL: file)
            XCTAssertNotNil(store.lastError)
            store.set("pink", forKey: "lightty.accent")
            store.flush()
            XCTAssertEqual(try Data(contentsOf: file), bytes)
            let snapshot = WorkspaceStore(fileURL: file)
            XCTAssertNil(snapshot.load())
            snapshot.write(WorkspaceSnapshot(windows: []))
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    /// 设置文件的位置可以被环境变量换掉：门禁脚本和调试要摆一份假设置，不能碰
    /// 用户真实的 ~/.lightty/preferences.json。测试进程始终走临时目录，覆盖不生效。
    func testPreferencesDirectoryCanBeRedirectedWithoutTouchingTheRealOne() {
        let home = URL(fileURLWithPath: "/fixture/home")
        XCTAssertEqual(FilePreferences.rootDirectory(testing: false, environment: [:], home: home).path,
                       "/fixture/home/.lightty")
        XCTAssertEqual(FilePreferences.rootDirectory(testing: false,
                                                     environment: ["LIGHTTY_PREFERENCES_DIR": "/scratch/prefs"],
                                                     home: home).path,
                       "/scratch/prefs")
        // 空值不算覆盖，仍然回到真实目录。
        XCTAssertEqual(FilePreferences.rootDirectory(testing: false,
                                                     environment: ["LIGHTTY_PREFERENCES_DIR": ""],
                                                     home: home).path,
                       "/fixture/home/.lightty")
        let testing = FilePreferences.rootDirectory(testing: true,
                                                    environment: ["LIGHTTY_PREFERENCES_DIR": "/scratch/prefs"],
                                                    home: home)
        XCTAssertNotEqual(testing.path, "/scratch/prefs")
        XCTAssertTrue(testing.lastPathComponent.hasPrefix("lightty-preferences-tests-"))
    }
}
