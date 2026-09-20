import XCTest
@testable import lightty

final class RelativeTimeTests: XCTestCase {
    func testFutureTimestampIsPresentedAsJustNowInsteadOfZeroSecondsInTheFuture() {
        let text = RelativeTime.text(Date(timeIntervalSinceNow: 0.25), localize: { $0 })

        // Task files can be written by another process while the clocks cross by
        // a fraction of a second. That must not leak a misleading "0 seconds
        // from now" status into the Handoff UI.
        XCTAssertEqual(text, "just now")
    }
}
