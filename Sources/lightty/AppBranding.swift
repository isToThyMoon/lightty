import AppKit

enum AppBranding {
    /// Shared by About, native alerts and the running application's Dock icon.
    /// Follows the variant last passed to `install`; before that, the factory one.
    static var icon: NSImage? { image(for: variant) }

    private static var variant = AppIconPreference.factory
    private static var images: [AppIconPreference: NSImage] = [:]

    /// Callers that run before data migration pass nothing: preferences are not readable yet.
    static func install(_ variant: AppIconPreference = .factory, on application: NSApplication) {
        self.variant = variant
        if let icon { application.applicationIconImage = icon }
    }

    static func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.icon = icon
        return alert
    }

    private static func image(for variant: AppIconPreference) -> NSImage? {
        if let cached = images[variant] { return cached }
        let image = Bundle.module
            .url(forResource: variant.resourceName, withExtension: "svg")
            .flatMap { NSImage(contentsOf: $0) }
        images[variant] = image
        return image
    }
}
