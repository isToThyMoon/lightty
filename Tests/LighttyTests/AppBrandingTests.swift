import AppKit
import Testing
@testable import lightty

@MainActor
@Test func brandedAlertsUseAppIcon() throws {
    _ = NSApplication.shared
    let icon = try #require(AppBranding.icon)
    #expect(icon.isValid)
    for style in [NSAlert.Style.informational, .warning, .critical] {
        let alert = AppBranding.makeAlert()
        alert.alertStyle = style
        #expect(alert.icon === icon)
        #expect(alert.alertStyle == style)
    }
}
