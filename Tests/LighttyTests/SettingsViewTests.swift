import AppKit
import XCTest
@testable import lightty

@MainActor
final class SettingsViewTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        suiteName = "settings-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        // 语言是进程级状态，跑完必须复位，否则后续用例的 L() 会变成中文。
        LanguagePreference.set(.system)
        NSApp.appearance = nil
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testAppearancePreferenceRoundTripsAndApplies() {
        XCTAssertEqual(AppearancePreference.current(in: defaults), .system)
        AppearancePreference.set(.dark, in: defaults)
        XCTAssertEqual(AppearancePreference.current(in: defaults), .dark)
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)
        AppearancePreference.set(.system, in: defaults)
        XCTAssertNil(NSApp.appearance)
    }

    func testLanguagePreferenceSwitchesLocalizedStrings() {
        LanguagePreference.set(.simplifiedChinese, in: defaults)
        XCTAssertEqual(L("Appearance"), "外观")
        XCTAssertEqual(L("Back to app"), "返回应用")
        LanguagePreference.set(.english, in: defaults)
        XCTAssertEqual(L("Appearance"), "Appearance")
    }

    /// 设置页：左栏导航 + 右侧页面；切页只换右侧，选中态跟随。
    func testSettingsViewNavigatesBetweenPages() {
        let view = SettingsView(page: .appearance)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.currentPage, .appearance)
        XCTAssertTrue(labels(in: view).contains(L("Appearance")))
        XCTAssertTrue(labels(in: view).contains(L("Theme")))
        XCTAssertTrue(labels(in: view).contains(L("Use the built-in Lightty terminal theme")))
        XCTAssertFalse(labels(in: view).contains(L("Agent status hooks")))
        XCTAssertTrue(labels(in: view).contains(L("Back to app")))

        view.showPage(.general)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.currentPage, .general)
        XCTAssertTrue(labels(in: view).contains(L("Language")))
        XCTAssertFalse(labels(in: view).contains(L("Theme")))
        XCTAssertFalse(labels(in: view).contains(L("Use the built-in Lightty terminal theme")))
        XCTAssertTrue(labels(in: view).contains(L("Agent status hooks")))
    }

    /// 语言变更通知到达后页面文案就地重建。
    func testSettingsViewRebuildsOnLanguageChange() {
        let view = SettingsView(page: .general)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        view.layoutSubtreeIfNeeded()
        LanguagePreference.set(.simplifiedChinese, in: defaults)
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(labels(in: view).contains("通用"))
        XCTAssertTrue(labels(in: view).contains("返回应用"))
    }

    /// 重点色偏好：带色相的档位同时接管导航色；默认/白退回内置导航蓝。
    func testAccentPreferenceDrivesShellColors() {
        defer { AccentPreference.set(.default, in: defaults); FilePreferences.shared.removeObject(forKey: AccentPreference.defaultsKey) }
        func rgb(_ color: NSColor) -> [Int] {
            let c = color.usingColorSpace(.sRGB)!
            return [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
        }
        AccentPreference.set(.pink)
        XCTAssertEqual(AccentPreference.current(), .pink)
        XCTAssertEqual(rgb(ShellStyle.accent), rgb(AccentPreference.pink.color))
        XCTAssertEqual(rgb(ShellStyle.navigationAccent), rgb(ShellStyle.accent), "有色相：导航跟重点色")

        AccentPreference.set(.default)
        XCTAssertNotEqual(rgb(ShellStyle.navigationAccent), rgb(ShellStyle.accent), "无色相：导航退回蔚蓝")
        XCTAssertFalse(AccentPreference.white.hasHue)
        XCTAssertEqual(AccentPreference.allCases.count, 8)
        FilePreferences.shared.removeObject(forKey: AccentPreference.defaultsKey)
        XCTAssertEqual(AccentPreference.current(), .pink, "出厂重点色是粉色")
    }

    /// 自绘控件：下拉标题跟随选中项并回调；开关翻转并回调。
    func testShellControlsReportChanges() {
        let dropdown = ShellDropdown(
            options: [.init(id: "a", title: "Alpha"), .init(id: "b", title: "Beta")],
            selectedID: "a")
        var picked: [String] = []
        dropdown.onChange = { picked.append($0) }
        XCTAssertEqual(dropdown.selectedTitle, "Alpha")
        dropdown.select("b")
        XCTAssertEqual(dropdown.selectedTitle, "Beta")
        dropdown.select("b")  // 重选同项不重复回调
        dropdown.select("zzz")  // 未知项忽略
        XCTAssertEqual(picked, ["b"])

        let toggle = ShellToggle(isOn: false)
        var states: [Bool] = []
        toggle.onChange = { states.append($0) }
        XCTAssertTrue(toggle.accessibilityPerformPress())
        XCTAssertTrue(toggle.isOn)
        XCTAssertEqual(states, [true])
    }

    private func labels(in view: NSView) -> [String] {
        view.subviews.flatMap { child -> [String] in
            let own = (child as? NSTextField).map { [$0.stringValue] } ?? []
            return own + labels(in: child)
        }
    }
}
