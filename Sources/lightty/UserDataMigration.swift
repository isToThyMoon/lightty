import Foundation
import LighttyCore
import Darwin

/// Startup gate, before preferences, workspace restore or organization reads.
/// Each file is atomic; the app starts only after the entire migration succeeds.
enum UserDataMigration {
    enum Failure: LocalizedError {
        case running, unsupported(String), conflict(String), changed(String), write
        var errorDescription: String? {
            switch self {
            case .running: return "Quit other lightty instances, then reopen lightty to upgrade its data."
            case .unsupported(let name): return "Unsupported or damaged data file: \(name). Original data was preserved."
            case .conflict(let name): return "Both development and current files exist with different contents: \(name). Neither was overwritten."
            case .changed(let name): return "File changed during conversion: \(name). Close lightty and retry; backups were preserved."
            case .write: return "Could not write converted data. Original files and backups were preserved."
            }
        }
    }
    private struct Plan {
        let source: URL
        let target: URL
        let original: Data
        let converted: Data
        let existingTarget: Data?
    }

    /// Returns a backup directory when an upgrade occurred; nil on fresh/current data.
    static func run(in root: URL, hasOtherInstance: () -> Bool = { false }) throws -> URL? {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = Darwin.open(root.appendingPathComponent(".migration.lock").path, O_CREAT | O_RDWR, mode_t(0o600))
        guard lock >= 0 else { throw Failure.write }
        defer { Darwin.close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw Failure.running }
        defer { flock(lock, LOCK_UN) }
        let legacyNames: [PersistenceFormat: String] = [
            .preferences: "preferences.json", .workspace: "session.json", .organization: "session-library.json"
        ]
        // Validate the entire input set before making any changes.
        let plans: [Plan] = try PersistenceFormat.allCases.compactMap { format in
            let legacy = root.appendingPathComponent(legacyNames[format]!)
            let target = root.appendingPathComponent(format.fileName)
            let source = fm.fileExists(atPath: legacy.path) ? legacy : target
            guard fm.fileExists(atPath: source.path) else {
                return nil
            }
            let original = try Data(contentsOf: source)
            guard var document = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                throw Failure.unsupported(source.lastPathComponent)
            }
            var input = original
            // Bootstrap only the known, headerless development names. This is not a
            // released version chain and can be removed after development data is retired.
            if document["format"] == nil {
                guard source == legacy, let version = document["version"] as? NSNumber,
                      CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1 else {
                    throw Failure.unsupported(source.lastPathComponent)
                }
                document["format"] = format.rawValue
                input = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
            }
            let converted: Data
            do {
                converted = try UserDataSchemas.migration(for: format).convert(input)
                try UserDataSchemas.validate(converted, as: format)
            } catch { throw Failure.unsupported(source.lastPathComponent) }
            if source == target, converted == original { return nil }
            let existing = fm.fileExists(atPath: target.path) ? try Data(contentsOf: target) : nil
            if source != target, let existing {
                try UserDataSchemas.validate(existing, as: format)
                guard try JSONSerialization.jsonObject(with: existing) as? NSDictionary
                    == JSONSerialization.jsonObject(with: converted) as? NSDictionary else {
                    throw Failure.conflict(target.lastPathComponent)
                }
            }
            return Plan(source: source, target: target, original: original, converted: converted, existingTarget: existing)
        }
        guard !plans.isEmpty else { return nil }
        guard !hasOtherInstance() else { throw Failure.running }
        let backup = root.appendingPathComponent("backups/migration-\(UUID().uuidString)")
        try fm.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Back up every original before replacing any file. A failed run keeps this directory.
        for plan in plans { try writeExclusive(plan.original, to: backup.appendingPathComponent(plan.source.lastPathComponent)) }
        for plan in plans {
            guard try Data(contentsOf: plan.source) == plan.original else { throw Failure.changed(plan.source.lastPathComponent) }
            let current = fm.fileExists(atPath: plan.target.path) ? try Data(contentsOf: plan.target) : nil
            guard current == plan.existingTarget else { throw Failure.changed(plan.target.lastPathComponent) }
            if plan.source == plan.target || plan.existingTarget == nil {
                let staged = backup.appendingPathComponent("converted-" + plan.target.lastPathComponent)
                try writeExclusive(plan.converted, to: staged)
                guard Darwin.rename(staged.path, plan.target.path) == 0 else { throw Failure.write }
            }
        }
        // Old names are no longer live inputs. Their byte-exact copies remain in backup.
        for plan in plans where plan.source != plan.target {
            guard try Data(contentsOf: plan.source) == plan.original else { throw Failure.changed(plan.source.lastPathComponent) }
            try fm.removeItem(at: plan.source)
        }
        return backup
    }

    private static func writeExclusive(_ data: Data, to url: URL) throws {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard fd >= 0 else { throw Failure.write }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }
}
