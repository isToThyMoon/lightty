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

    /// 两种失败都返回 nil：shell 挂住（超时放弃，不能等 30 秒）、shell 路径不存在。
    func testResolveReturnsNilWhenTheShellHangsOrIsMissing() throws {
        let shell = try makeFakeShell(
            """
            #!/bin/sh
            exec sleep 30
            """)
        let started = Date()
        XCTAssertNil(LoginShellPath.resolve(shell: shell.path, environment: [:], timeout: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertNil(LoginShellPath.resolve(shell: "/nonexistent/shell", environment: [:], timeout: 1))
    }

    /// `HookInstaller.searchPath()` 恰好是三段：进程 PATH → 登录 shell 的 PATH → 系统目录，
    /// 按这个顺序、不重复、没有第四个来源。
    ///
    /// 「没有第四个来源」是这条的重点：写死的 homebrew / nvm / volta 目录清单已经删了。
    /// 它凭空多出来的目录会让设置页说"已检测到"，而 pane 里的登录 shell 根本敲不出那个 CLI。
    func testSearchPathIsOnlyTheProcessPathTheLoginShellAndSystemDirectories() {
        let process = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        let system = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

        let path = HookInstaller.searchPath()

        XCTAssertEqual(path.count, Set(path).count, "PATH 里有重复目录")
        XCTAssertEqual(Set(path), Set(process + LoginShellPath.directories + system),
                       "查找清单里有三段之外的目录，或漏了某一段")
        // 同一个目录出现在多段里时算最靠前的那一段：用户显式给的 PATH 优先，
        // 登录 shell（版本管理器都在这儿）次之，系统目录兜底
        func segment(_ directory: String) -> Int {
            if process.contains(directory) { return 0 }
            if LoginShellPath.directories.contains(directory) { return 1 }
            return 2
        }
        XCTAssertEqual(path.map(segment), path.map(segment).sorted(), "三段的顺序乱了：\(path)")
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
