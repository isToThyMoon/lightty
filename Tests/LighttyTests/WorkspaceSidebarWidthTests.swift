import XCTest
@testable import lightty

final class WorkspaceSidebarWidthTests: XCTestCase {
    func testWidthRangeUsesCurrentWidthAsMinimumAndTwiceThatAsMaximum() {
        XCTAssertEqual(WorkspaceSidebarSizing.minimumWidth, ShellStyle.workspaceColumnWidth)
        XCTAssertEqual(
            WorkspaceSidebarSizing.maximumWidth,
            ShellStyle.workspaceColumnWidth * 2)
        XCTAssertEqual(
            WorkspaceSidebarSizing.clampedWidth(WorkspaceSidebarSizing.minimumWidth - 1),
            WorkspaceSidebarSizing.minimumWidth)
        XCTAssertEqual(
            WorkspaceSidebarSizing.clampedWidth(WorkspaceSidebarSizing.maximumWidth + 1),
            WorkspaceSidebarSizing.maximumWidth)
    }

    func testClosingRequiresOvershootingMinimumWidth() {
        XCTAssertFalse(WorkspaceSidebarSizing.shouldClose(
            rawWidth: WorkspaceSidebarSizing.minimumWidth - WorkspaceSidebarSizing.closeOvershoot))
        XCTAssertTrue(WorkspaceSidebarSizing.shouldClose(
            rawWidth: WorkspaceSidebarSizing.minimumWidth
                - WorkspaceSidebarSizing.closeOvershoot - 1))
    }

    func testWidthPreferenceDefaultsClampsAndRoundTrips() throws {
        let suiteName = "WorkspaceSidebarWidthTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            WorkspaceSidebarWidthPreference.width(in: defaults),
            WorkspaceSidebarSizing.minimumWidth)

        WorkspaceSidebarWidthPreference.setWidth(310, in: defaults)
        XCTAssertEqual(WorkspaceSidebarWidthPreference.width(in: defaults), 310)

        defaults.set(10_000.0, forKey: WorkspaceSidebarWidthPreference.defaultsKey)
        XCTAssertEqual(
            WorkspaceSidebarWidthPreference.width(in: defaults),
            WorkspaceSidebarSizing.maximumWidth)
    }
}
