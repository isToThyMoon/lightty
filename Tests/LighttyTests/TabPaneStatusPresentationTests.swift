import XCTest
import LighttyCore
@testable import lightty

final class TabPaneStatusPresentationTests: XCTestCase {
    /// 状态 → 详情行的查表。
    func testDetailLineByState() {
        // 带工具名、且 detail 被截断（契约 §4.2：detail 长度不可信，读方必须截断）
        let line = TabPaneStatusPresentation.detailLine(
            for: status(.tool, tool: "Bash", detail: String(repeating: "x", count: 500)))
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.hasPrefix(L("Running %@", "Bash")))
        XCTAssertLessThan(line!.count, 200)

        // 空闲与无状态没有详情行
        let silent: [(name: String, status: PaneStatus?)] = [
            ("idle", status(.idle)),
            ("nil", nil),
        ]
        for c in silent {
            XCTAssertNil(TabPaneStatusPresentation.detailLine(for: c.status), c.name)
        }
    }

    private func status(
        _ state: PaneActivity, tool: String? = nil, detail: String? = nil
    ) -> PaneStatus {
        PaneStatus(ts: Date(timeIntervalSince1970: 0), state: state, tool: tool, detail: detail)
    }
}
