import XCTest
@testable import lightty

final class TabSidebarWidthTests: XCTestCase {
    func testClosingRequiresOvershootingMinimumWidth() {
        XCTAssertFalse(TabSidebarSizing.shouldClose(
            rawWidth: TabSidebarSizing.minimumWidth - TabSidebarSizing.closeOvershoot))
        XCTAssertTrue(TabSidebarSizing.shouldClose(
            rawWidth: TabSidebarSizing.minimumWidth
                - TabSidebarSizing.closeOvershoot - 1))
    }

    /// 宽度落在 [minimumWidth, maximumWidth] 里：钳制函数与偏好读写都守这一条。
    func testWidthPreferenceClampsToSizingRangeAndRoundTrips() throws {
        // 钳制：越界一点就贴回边界
        XCTAssertEqual(
            TabSidebarSizing.clampedWidth(TabSidebarSizing.minimumWidth - 1),
            TabSidebarSizing.minimumWidth)
        XCTAssertEqual(
            TabSidebarSizing.clampedWidth(TabSidebarSizing.maximumWidth + 1),
            TabSidebarSizing.maximumWidth)

        // 偏好：默认为最小值、写入读回、超大钳到最大值
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
