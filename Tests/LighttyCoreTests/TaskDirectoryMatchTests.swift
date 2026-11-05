import LighttyCore
import XCTest

final class TaskDirectoryMatchTests: XCTestCase {
    func testRelatedDirectories() {
        let home = "/Users/me"
        let cases: [(task: String, terminal: String, related: Bool, why: String)] = [
            ("/Users/me/app", "/Users/me/app", true, "同一目录"),
            ("/Users/me/app", "/Users/me/app/src", true, "终端在任务目录里面"),
            ("/Users/me/app/src", "/Users/me/app/", true, "任务在终端目录里面，结尾斜杠不影响"),
            ("/Users/me/app", "/Users/me/app-two", false, "只是名字前缀相同"),
            ("/Users/me", "/Users/me/app", false, "侧栏新建的任务写家目录，不能算所有项目的相关任务"),
            ("/Users/me/app", "/Users/me", false, "在家目录开的终端不能把所有任务都判成此目录"),
            ("/Users/me", "/Users/me", true, "家目录只认精确相等"),
            ("/", "/tmp", false, "根目录同理"),
        ]
        for c in cases {
            XCTAssertEqual(TaskDirectoryMatch.isRelated(taskDirectory: c.task, terminalDirectory: c.terminal, home: home),
                           c.related, c.why)
        }
    }
}
