import XCTest
@testable import lightty

final class TabSidebarWidthTests: XCTestCase {
    func testWidthRangeUsesCurrentWidthAsMinimumAndTwiceThatAsMaximum() {
        XCTAssertEqual(TabSidebarSizing.minimumWidth, ShellStyle.tabColumnWidth)
        XCTAssertEqual(
            TabSidebarSizing.maximumWidth,
            ShellStyle.tabColumnWidth * 2)
        XCTAssertEqual(
            TabSidebarSizing.clampedWidth(TabSidebarSizing.minimumWidth - 1),
            TabSidebarSizing.minimumWidth)
        XCTAssertEqual(
            TabSidebarSizing.clampedWidth(TabSidebarSizing.maximumWidth + 1),
            TabSidebarSizing.maximumWidth)
    }

    func testClosingRequiresOvershootingMinimumWidth() {
        XCTAssertFalse(TabSidebarSizing.shouldClose(
            rawWidth: TabSidebarSizing.minimumWidth - TabSidebarSizing.closeOvershoot))
        XCTAssertTrue(TabSidebarSizing.shouldClose(
            rawWidth: TabSidebarSizing.minimumWidth
                - TabSidebarSizing.closeOvershoot - 1))
    }

    func testWidthPreferenceDefaultsClampsAndRoundTrips() throws {
        let suiteName = "TabSidebarWidthTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            TabSidebarWidthPreference.width(in: defaults),
            TabSidebarSizing.minimumWidth)

        TabSidebarWidthPreference.setWidth(310, in: defaults)
        XCTAssertEqual(TabSidebarWidthPreference.width(in: defaults), 310)

        defaults.set(10_000.0, forKey: TabSidebarWidthPreference.defaultsKey)
        XCTAssertEqual(
            TabSidebarWidthPreference.width(in: defaults),
            TabSidebarSizing.maximumWidth)
    }
}
