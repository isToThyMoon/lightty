import XCTest
@testable import lightty

/// 通用包要能自己迁到单架构包，否则分架构发包只惠及新安装，
/// 已经装好的那些永远留着两份 Node 运行时（各约 110MB）。
final class UpdateFeedTests: XCTestCase {
    private let base = "https://github.com/isToThyMoon/lightty/releases/latest/download"

    /// `feed(replacing:flavor:)` 是纯函数：输入 → 输出的查表。
    func testFeedRewriteTable() {
        let cases: [(name: String, input: String?, flavor: String, expected: String?)] = [
            // 通用包的源改写到当前架构
            ("universal → arm64", "\(base)/appcast.xml", "arm64", "\(base)/appcast-arm64.xml"),
            ("universal → x64", "\(base)/appcast.xml", "x64", "\(base)/appcast-x64.xml"),
            // 单架构包的 Info.plist 已经指向自己的源，不该再被改写
            ("arm64 feed left alone", "\(base)/appcast-arm64.xml", "arm64", nil),
            ("x64 feed left alone", "\(base)/appcast-x64.xml", "x64", nil),
            // 缺失或认不出的源回落到打包进去的值
            ("missing feed", nil, "arm64", nil),
            ("unknown feed", "https://example.com/updates.rss", "arm64", nil),
            // 只替换文件名，不去拼主机与路径：地址只有打包脚本一处来源
            ("only the file name is rewritten", "https://example.com/a/appcast.xml", "x64",
             "https://example.com/a/appcast-x64.xml"),
        ]
        for c in cases {
            XCTAssertEqual(UpdateFeed.feed(replacing: c.input, flavor: c.flavor), c.expected, c.name)
        }
    }

    func testFlavorMatchesThePackagingScriptNames() {
        #if arch(arm64)
        XCTAssertEqual(UpdateFeed.flavor, "arm64")
        #else
        XCTAssertEqual(UpdateFeed.flavor, "x64")
        #endif
    }
}
