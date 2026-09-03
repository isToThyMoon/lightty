import XCTest
import LighttyCore
@testable import lightty

final class WorkspacePaneStatusPresentationTests: XCTestCase {
    func testToolKeepsThinkingPresentation() {
        let thinking = status(.thinking)
        let tool = status(.tool, tool: "Edit")

        XCTAssertEqual(
            WorkspacePaneStatusPresentation.text(for: tool),
            WorkspacePaneStatusPresentation.text(for: thinking))
    }

    func testActionableAndFinishedStatesRemainDistinct() {
        XCTAssertEqual(
            WorkspacePaneStatusPresentation.text(for: status(.attention)),
            L("Needs you"))
        XCTAssertEqual(
            WorkspacePaneStatusPresentation.text(for: status(.done)),
            L("Finished"))
        XCTAssertNil(
            WorkspacePaneStatusPresentation.text(for: status(.idle)))
    }

    func testDetailLineCarriesToolAndTruncatedDetail() {
        let line = WorkspacePaneStatusPresentation.detailLine(
            for: status(.tool, tool: "Bash", detail: String(repeating: "x", count: 500)))
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.hasPrefix(L("Running %@", "Bash")))
        // 契约 §4.2：detail 长度不可信，读方必须截断
        XCTAssertLessThan(line!.count, 200)
    }

    func testDetailLineSilentForIdleAndNil() {
        XCTAssertNil(WorkspacePaneStatusPresentation.detailLine(for: status(.idle)))
        XCTAssertNil(WorkspacePaneStatusPresentation.detailLine(for: nil))
    }

    private func status(
        _ state: PaneActivity, tool: String? = nil, detail: String? = nil
    ) -> PaneStatus {
        PaneStatus(ts: Date(timeIntervalSince1970: 0), state: state, tool: tool, detail: detail)
    }
}
