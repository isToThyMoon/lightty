import XCTest
@testable import lightty

/// 通用包要能自己迁到单架构包，否则分架构发包只惠及新安装，
/// 已经装好的那些永远留着两份 Node 运行时（各约 110MB）。
final class UpdateFeedTests: XCTestCase {
    private let base = "https://github.com/isToThyMoon/lightty/releases/latest/download"

    func testUniversalFeedIsRedirectedToTheRunningArchitecture() {
        XCTAssertEqual(UpdateFeed.feed(replacing: "\(base)/appcast.xml", flavor: "arm64"),
                       "\(base)/appcast-arm64.xml")
        XCTAssertEqual(UpdateFeed.feed(replacing: "\(base)/appcast.xml", flavor: "x64"),
                       "\(base)/appcast-x64.xml")
    }

    func testPerArchitectureFeedsAreLeftAlone() {
        // 单架构包的 Info.plist 已经指向自己的源，不该再被改写。
        XCTAssertNil(UpdateFeed.feed(replacing: "\(base)/appcast-arm64.xml", flavor: "arm64"))
        XCTAssertNil(UpdateFeed.feed(replacing: "\(base)/appcast-x64.xml", flavor: "x64"))
    }

    func testUnknownOrMissingFeedFallsBackToTheBundledValue() {
        XCTAssertNil(UpdateFeed.feed(replacing: nil, flavor: "arm64"))
        XCTAssertNil(UpdateFeed.feed(replacing: "https://example.com/updates.rss", flavor: "arm64"))
        // 只替换文件名，不去拼主机与路径：地址只有打包脚本一处来源。
        XCTAssertEqual(UpdateFeed.feed(replacing: "https://example.com/a/appcast.xml", flavor: "x64"),
                       "https://example.com/a/appcast-x64.xml")
    }

    func testFlavorMatchesThePackagingScriptNames() {
        #if arch(arm64)
        XCTAssertEqual(UpdateFeed.flavor, "arm64")
        #else
        XCTAssertEqual(UpdateFeed.flavor, "x64")
        #endif
    }
}
