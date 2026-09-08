import AppKit

enum AppBranding {
    /// Shared by About, native alerts and the running application's Dock icon.
    static let icon: NSImage? = Bundle.module
        .url(forResource: "lightty-icon", withExtension: "svg")
        .flatMap { NSImage(contentsOf: $0) }

    static func install(on application: NSApplication) {
        if let icon { application.applicationIconImage = icon }
    }

    static func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.icon = icon
        return alert
    }
}
