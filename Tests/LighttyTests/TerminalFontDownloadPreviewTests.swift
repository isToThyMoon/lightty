import XCTest
@testable import lightty

final class TerminalFontDownloadPreviewTests: XCTestCase {
    func testPreviewCompletesThroughDownloadingAndInstallingPhases() {
        let completed = expectation(description: "preview completed")
        let preview = TerminalFontDownloadPreview(stepDelay: 0.002)
        var sawDownload = false
        var sawInstall = false

        preview.start { phase in
            switch phase {
            case .downloading:
                sawDownload = true
            case .installing:
                sawInstall = true
            }
        } completion: { result in
            if case .failure(let error) = result {
                XCTFail("preview failed: \(error)")
            }
            XCTAssertTrue(sawDownload)
            XCTAssertTrue(sawInstall)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 1)
        XCTAssertFalse(preview.isRunning)
    }

    func testCancellingPreviewCompletesOnceWithoutFurtherPhases() {
        let cancelled = expectation(description: "preview cancelled")
        let preview = TerminalFontDownloadPreview(stepDelay: 0.05)
        var completionCount = 0
        var phaseCount = 0

        preview.start { _ in
            phaseCount += 1
        } completion: { result in
            completionCount += 1
            guard case .failure(TerminalFontDownloadError.cancelled) = result else {
                XCTFail("expected cancellation")
                return
            }
            cancelled.fulfill()
        }
        preview.cancel()

        wait(for: [cancelled], timeout: 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(phaseCount, 1)
        XCTAssertFalse(preview.isRunning)
    }
}
