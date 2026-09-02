import XCTest
@testable import lightty

final class TaskSidebarTests: XCTestCase {
    func testDormantTaskClickChoosesAnOpenDestination() {
        XCTAssertEqual(
            TaskSidebar.activation(hasRunningPane: false),
            .chooseDestination,
            "A dormant task click must ask where to open it")
    }

    func testRunningTaskClickStillJumpsDirectly() {
        XCTAssertEqual(
            TaskSidebar.activation(hasRunningPane: true),
            .jump)
    }

    func testDestinationPickerOffersAllThreeOpenLocations() {
        XCTAssertEqual(
            TaskSidebar.OpenDestination.allCases,
            [.currentWorkspace, .newWorkspace, .newWindow])
    }
}
