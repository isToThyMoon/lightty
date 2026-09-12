import XCTest
@testable import lightty

/// 登录 shell PATH 解析。真正跑 shell 的用例只用系统自带的 `/bin/sh`，
/// 不依赖用户的 zsh 配置；缓存相关的用例不触碰用户偏好。
final class LoginShellPathTests: XCTestCase {
    func testExtractTakesTextBetweenMarkers() {
        let marker = "M"
        XCTAssertEqual(LoginShellPath.extract("rc noise\nM/a:/bM\n", marker: marker), "/a:/b")
        // rc 文件中途崩掉、只打出一个标记：不能把半截当结果
        XCTAssertNil(LoginShellPath.extract("M/a:/b", marker: marker))
        XCTAssertNil(LoginShellPath.extract("", marker: marker))
    }

    func testParseDropsEmptyAndDuplicateEntriesKeepingOrder() {
        XCTAssertEqual(LoginShellPath.parse("/b::/a:/b:/c:"), ["/b", "/a", "/c"])
        XCTAssertEqual(LoginShellPath.parse(""), [])
    }

    func testResolveRunsTheLoginShellAndReturnsItsPath() throws {
        let resolved = try XCTUnwrap(
            LoginShellPath.resolve(shell: "/bin/sh", environment: ["PATH": "/usr/bin:/bin"], timeout: 5))
        XCTAssertTrue(resolved.contains("/usr/bin"), "\(resolved)")
        XCTAssertTrue(resolved.contains("/bin"), "\(resolved)")
    }

    func testResolvePassesMarkerSoUserRcFilesCanSkipSlowWork() throws {
        // 用一个假 shell：把 -c 收到的脚本原样交给 /bin/sh，但先检查标记变量。
        let shell = try makeFakeShell(
            """
            #!/bin/sh
            [ "$LIGHTTY_RESOLVING_PATH" = "1" ] || exit 1
            PATH="/fake/bin:$PATH"
            exec /bin/sh -c "$2"
            """)
        let resolved = try XCTUnwrap(
            LoginShellPath.resolve(shell: shell.path, environment: ["PATH": "/usr/bin"], timeout: 5))
        XCTAssertEqual(resolved.first, "/fake/bin")
    }

    func testResolveGivesUpOnAHangingShell() throws {
        let shell = try makeFakeShell(
            """
            #!/bin/sh
            exec sleep 30
            """)
        let started = Date()
        XCTAssertNil(LoginShellPath.resolve(shell: shell.path, environment: [:], timeout: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testResolveReturnsNilForMissingShell() {
        XCTAssertNil(LoginShellPath.resolve(shell: "/nonexistent/shell", environment: [:], timeout: 1))
    }

    func testSearchPathIncludesLoginShellDirectoriesAndVersionManagers() {
        let path = HookInstaller.searchPath()
        for directory in LoginShellPath.directories {
            XCTAssertTrue(path.contains(directory), "登录 shell 的 \(directory) 没进查找清单")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertTrue(path.contains("\(home)/.volta/bin"))
        XCTAssertTrue(path.contains("\(home)/Library/pnpm"))
        XCTAssertTrue(path.contains("\(home)/.asdf/shims"))
    }

    func testNvmVersionsAreListedNewestFirst() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        for version in ["v18.20.4", "v22.1.0", "v20.11.1"] {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(".nvm/versions/node/\(version)/bin"),
                withIntermediateDirectories: true)
        }
        XCTAssertEqual(HookInstaller.nvmBinDirectories(home: home.path), [
            "\(home.path)/.nvm/versions/node/v22.1.0/bin",
            "\(home.path)/.nvm/versions/node/v20.11.1/bin",
            "\(home.path)/.nvm/versions/node/v18.20.4/bin",
        ])
        XCTAssertEqual(HookInstaller.nvmBinDirectories(home: home.path + "/missing"), [])
    }

    private func makeFakeShell(_ script: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-shell-\(UUID().uuidString)")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
