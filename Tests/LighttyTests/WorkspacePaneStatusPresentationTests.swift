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

    private func status(_ state: PaneActivity, tool: String? = nil) -> PaneStatus {
        PaneStatus(ts: Date(timeIntervalSince1970: 0), state: state, tool: tool)
    }
}
