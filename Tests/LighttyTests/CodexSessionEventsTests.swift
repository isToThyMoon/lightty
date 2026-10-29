import Foundation
import XCTest
@testable import lightty

final class CodexSessionEventsTests: XCTestCase {
    private func isShown(_ wire: [String: Any]) -> Bool {
        CodexSessionEvents.Thread(wire).isShownInTerminal
    }

    /// 合成载荷：广播和补查必须对同一状态给出相同解释，新增字段不影响已知字段。
    func testSnapshotsAndNotificationsShareActivitySemantics() throws {
        let cases: [(String, [String: Any], PaneStatusStore.CodexActivity?)] = [
            ("active without flags", ["type": "active"], .active),
            ("approval", ["type": "active", "activeFlags": ["waitingOnApproval"]], .waiting),
            ("question", ["type": "active", "activeFlags": ["waitingOnUserInput"]], .waiting),
            ("new flag alongside known flag", ["type": "active", "activeFlags": ["future", "waitingOnUserInput"]], .waiting),
            ("unknown flag alone", ["type": "active", "activeFlags": ["future"]], .active),
            ("idle", ["type": "idle"], .idle),
            ("unknown state still carries identity", ["type": "future"], nil),
            ("missing state still carries identity", [:], nil),
        ]
        for (name, status, activity) in cases {
            let snapshot = CodexSessionEvents.Thread(["id": "thread", "cwd": "/fixture",
                "createdAt": 100.0, "status": status, "futureField": true])
            XCTAssertEqual(snapshot.activity, activity, name)
            XCTAssertEqual(snapshot.createdAt, Date(timeIntervalSince1970: 100), name)
            XCTAssertEqual(try CodexSessionEvents.decode("thread/status/changed", params: [
                "threadId": "thread", "status": status, "futureField": true,
            ]), .activityChanged(threadID: "thread", activity: activity), name)
        }
    }

    func testLifecycleEnvelopesDistinguishUnrelatedAndMalformedMessages() throws {
        let outcomes: [(String, PaneStatusStore.CodexActivity?)] = [
            ("completed", .completed), ("interrupted", .interrupted), ("failed", .failed), ("future", nil),
        ]
        for (status, activity) in outcomes {
            XCTAssertEqual(try CodexSessionEvents.decode("turn/completed", params: [
                "threadId": "thread", "turn": ["status": status],
            ]), .turnCompleted(threadID: "thread", activity: activity))
        }
        XCTAssertEqual(try CodexSessionEvents.decode("thread/closed", params: ["threadId": "thread"]), .closed("thread"))
        XCTAssertEqual(try CodexSessionEvents.decode("thread/name/updated", params: ["threadId": "thread"]), .renamed("thread"))
        let wire: [String: Any] = ["id": "thread", "status": ["type": "active"]]
        XCTAssertEqual(try CodexSessionEvents.decode("thread/started", params: ["thread": wire]), .started(.init(wire)))
        // 不订阅的新增广播可以任意形状；认识的方法缺身份/容器不能误报为有效事件。
        XCTAssertNil(try CodexSessionEvents.decode("future/notification", params: [:]))
        for method in CodexSessionEvents.Method.allCases {
            XCTAssertThrowsError(try CodexSessionEvents.decode(method.rawValue, params: [:]), method.rawValue)
        }
        XCTAssertThrowsError(try CodexSessionEvents.decode("turn/completed", params: ["threadId": "thread", "turn": "invalid"]))
    }

    /// 后台进程自己建的会话不上任何 pane：实测生成标题时建了一个同目录的临时会话，
    /// 配上去会把真正会话的记录挤掉，回合的 Stop 跟着丢了。
    func testOnlyUserThreadsBelongToATerminal() {
        XCTAssertTrue(isShown(["id": "a", "threadSource": "user", "ephemeral": false]))
        XCTAssertTrue(isShown(["id": "a"]), "旧版本没有来源字段")
        XCTAssertFalse(isShown(["id": "a", "threadSource": "thread_title", "ephemeral": true]))
        XCTAssertFalse(isShown(["id": "a", "threadSource": "user", "ephemeral": true]))
        XCTAssertFalse(isShown(["id": "a", "threadSource": "subagent"]))
        XCTAssertFalse(isShown(["id": "a", "parentThreadId": "b"]))
        XCTAssertTrue(isShown(["id": "a", "parentThreadId": NSNull()]))
    }

}
