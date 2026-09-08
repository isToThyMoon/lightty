import Foundation
import Darwin
import LighttyCore

/// The same interface accepts isolated UserDefaults suites in existing preference tests.
protocol PreferenceStorage {
    func object(forKey key: String) -> Any?
    func string(forKey key: String) -> String?
    func stringArray(forKey key: String) -> [String]?
    func bool(forKey key: String) -> Bool
    func double(forKey key: String) -> Double
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    func register(defaults: [String: Any])
}
extension UserDefaults: PreferenceStorage {}

/// One app-owned file, independent of executable/bundle identity.
/// Atomic writes merge with disk under an interprocess lock; only the current format is read.
final class FilePreferences: PreferenceStorage {
    static let failureNotification = Notification.Name("lighttyPreferencesStorageFailed")
    /// 设置文件所在目录。LIGHTTY_PREFERENCES_DIR 供调试与门禁脚本换一份假设置，
    /// 不必碰用户真实的 ~/.lightty/preferences.json（与 LIGHTTY_TASK_DIR 同式）。
    /// 只换这一个文件：pane 运行时目录等仍在 ~/.lightty，不足以让第二个实例安全共存。
    static func rootDirectory(testing: Bool, environment: [String: String], home: URL) -> URL {
        if testing {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("lightty-preferences-tests-\(getpid())")
        }
        if let override = environment["LIGHTTY_PREFERENCES_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return home.appendingPathComponent(".lightty")
    }

    static let shared: FilePreferences = {
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        let root = rootDirectory(testing: testing,
                                 environment: ProcessInfo.processInfo.environment,
                                 home: FileManager.default.homeDirectoryForCurrentUser)
        return FilePreferences(fileURL: root.appendingPathComponent(PersistenceFormat.preferences.fileName))
    }()

    let fileURL: URL
    private var values: [String: Any] = [:]
    private var registered: [String: Any] = [:]
    private var envelope: [String: Any] = ["format": PersistenceFormat.preferences.rawValue,
                                           "version": PersistenceFormat.preferences.currentVersion]
    private let mutex = NSRecursiveLock()
    private let writer = DispatchQueue(label: "lightty.preferences.writer", qos: .utility)
    private enum Edit { case set(Any), remove }
    private var pending: [String: Edit] = [:]
    private var writeScheduled = false
    private var writeGeneration = 0
    private var storageError: Error?
    var lastError: Error? {
        mutex.lock(); defer { mutex.unlock() }
        return storageError
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        do {
            try withFileLock {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    values = try read()
                } else {
                    try write([:])
                }
            }
        } catch { storageError = error }
    }

    func object(forKey key: String) -> Any? {
        mutex.lock(); defer { mutex.unlock() }
        return values[key] ?? registered[key]
    }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    func bool(forKey key: String) -> Bool { (object(forKey: key) as? NSNumber)?.boolValue ?? false }
    func double(forKey key: String) -> Double { (object(forKey: key) as? NSNumber)?.doubleValue ?? 0 }
    func register(defaults: [String: Any]) {
        mutex.lock(); defer { mutex.unlock() }
        registered.merge(defaults) { _, new in new }
    }
    func removeObject(forKey key: String) { set(nil, forKey: key) }
    func set(_ value: Any?, forKey key: String) {
        mutex.lock(); defer { mutex.unlock() }
        values[key] = value
        pending[key] = value.map(Edit.set) ?? .remove
        guard !writeScheduled else { return }
        writeScheduled = true
        writeGeneration += 1
        let generation = writeGeneration
        // One bounded batch per burst; the caller never waits for a file lock or fsync.
        writer.asyncAfter(deadline: .now() + 0.05) { self.persistPending(generation: generation) }
    }

    /// Explicit durability boundary for shutdown and callers that must reopen the file.
    func flush() {
        writer.sync { persistPending() }
    }

    // Confined to writer after initialization. Never hold the cache mutex during disk I/O.
    private func persistPending(generation: Int? = nil) {
        mutex.lock()
        if let generation, !writeScheduled || generation != writeGeneration {
            mutex.unlock()
            return
        }
        let edits = pending
        pending.removeAll(keepingCapacity: true)
        writeScheduled = false
        mutex.unlock()
        guard !edits.isEmpty else { return }
        do {
            try withFileLock {
                // A missing/damaged file after initialization is not permission to erase it.
                var latest = try read()
                for (key, edit) in edits {
                    switch edit {
                    case .set(let value): latest[key] = value
                    case .remove: latest.removeValue(forKey: key)
                    }
                }
                try write(latest)
            }
            mutex.lock()
            storageError = nil
            mutex.unlock()
        } catch {
            mutex.lock()
            let firstFailure = storageError == nil
            storageError = error
            // Retry on a later edit / flush, without spinning on an unreadable file.
            pending.merge(edits) { newer, _ in newer }
            mutex.unlock()
            if firstFailure {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Self.failureNotification, object: self)
                }
            }
        }
    }
    private func read() throws -> [String: Any] {
        let data = try Data(contentsOf: fileURL)
        try PersistenceFormat.preferences.validate(data)
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = document["values"] as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        envelope = document
        return values
    }
    private func write(_ values: [String: Any]) throws {
        var document = envelope
        document["values"] = values
        guard JSONSerialization.isValidJSONObject(document) else { throw CocoaError(.propertyListWriteInvalid) }
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        let temporary = fileURL.deletingLastPathComponent().appendingPathComponent(".preferences-\(UUID()).tmp")
        let fd = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, mode_t(0o600))
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard Darwin.rename(temporary.path, fileURL.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    private func withFileLock(_ body: () throws -> Void) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(fileURL.appendingPathExtension("lock").path, O_CREAT | O_RDWR, mode_t(0o600))
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(fd, LOCK_UN) }
        try body()
    }
}
