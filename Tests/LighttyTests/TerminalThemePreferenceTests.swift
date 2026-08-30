import XCTest
@testable import lightty

final class TerminalThemePreferenceTests: XCTestCase {
    func testBuiltInThemeIsOnByDefaultAndCanBeDisabled() {
        let suiteName = "TerminalThemePreferenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(TerminalThemePreference.usesBuiltInTheme(in: defaults))

        TerminalThemePreference.setUsesBuiltInTheme(false, in: defaults)
        XCTAssertFalse(TerminalThemePreference.usesBuiltInTheme(in: defaults))
    }
}
