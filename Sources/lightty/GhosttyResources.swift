import Foundation

/// Resolves libghostty's non-code assets before `ghostty_init` snapshots the environment.
///
/// GhosttyKit is a static library: themes, terminfo and shell integration files are not
/// embedded in the archive. The official app discovers them inside its own bundle, while a
/// SwiftPM executable must explicitly point libghostty at either its packaged resources or
/// the vendor build tree used during development. This is a resource-location adapter only:
/// it never parses, loads, or mutates terminal configuration.
enum GhosttyResources {
    private static let environmentKey = "GHOSTTY_RESOURCES_DIR"

    @discardableResult
    static func configureEnvironmentIfNeeded() -> URL? {
        if let explicit = ProcessInfo.processInfo.environment[environmentKey], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit, isDirectory: true)
        }

        for candidate in candidates() where isValid(candidate) {
            let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
            setenv(environmentKey, resolved.path, 0)
            return resolved
        }
        return nil
    }

    private static func candidates() -> [URL] {
        var result: [URL] = []

        // Packaged app contract: Contents/Resources/ghostty/{themes,terminfo,...}
        if let resources = Bundle.main.resourceURL {
            result.append(resources.appendingPathComponent("ghostty", isDirectory: true))
        }

        // SwiftPM development contract: walk up from the executable, independent of cwd,
        // until the repository's vendor build output is found.
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            .resolvingSymlinksInPath().deletingLastPathComponent()
        while directory.path != "/" {
            result.append(directory.appendingPathComponent(
                "vendor/ghostty/zig-out/share/ghostty", isDirectory: true))
            result.append(directory.appendingPathComponent(
                "zig-out/share/ghostty", isDirectory: true))
            result.append(directory.appendingPathComponent("share/ghostty", isDirectory: true))
            directory.deleteLastPathComponent()
        }

        return result
    }

    private static func isValid(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let themes = url.appendingPathComponent("themes", isDirectory: true).path
        return FileManager.default.fileExists(atPath: themes, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
