import AppKit

/// Matched Lucide outlines, bundled as vector PDFs (no SVG runtime or icon library dependency).
enum ProjectFolderIcons {
    private static let closed = load("project-folder")
    private static let open = load("project-folder-open")

    static func image(expanded: Bool) -> NSImage { expanded ? open : closed }

    private static func load(_ name: String) -> NSImage {
        guard let url = Bundle.module.url(forResource: name, withExtension: "pdf"),
              let image = NSImage(contentsOf: url) else {
            preconditionFailure("Missing bundled project icon: \(name)")
        }
        image.isTemplate = true
        return image
    }
}
