import Foundation
import LighttyCore
import Darwin

/// Adapter to the pinned official SDK. File-format knowledge stays in the SDK.
struct ClaudeSessionCatalog: SessionCatalogProvider {
    let source: SessionCatalogSource
    var helperDirectory: URL? = nil // Injected fixture/build artifact, never a user shell command.

    static var installedHelper: URL {
        if Bundle.main.bundleURL.pathExtension == "app", let resources = Bundle.main.resourceURL {
            return resources.appendingPathComponent("claude-session-helper")
        }
        // SwiftPM executable is in .build/<triple>/debug (or release).
        let executable = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).standardizedFileURL
        var directory = executable.deletingLastPathComponent()
        while directory.path != "/" {
            if directory.lastPathComponent == ".build" {
                return directory.appendingPathComponent("claude-session-helper")
            }
            directory.deleteLastPathComponent()
        }
        return executable.deletingLastPathComponent().appendingPathComponent("claude-session-helper")
    }

    func page(archived: Bool, cursor: String?, cancelled: () -> Bool) throws -> SessionCatalogPage {
        if cancelled() { throw CancellationError() }
        // Claude has no equivalent of Codex's archived_sessions catalog.
        if archived { return SessionCatalogPage(sessions: [], nextCursor: nil) }
        let helper = helperDirectory ?? Self.installedHelper
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x64"
        #endif
        let runtime = helper.appendingPathComponent("runtime-\(architecture)/node")
        let script = helper.appendingPathComponent("list-sessions.mjs")
        guard FileManager.default.isExecutableFile(atPath: runtime.path),
              FileManager.default.isReadableFile(atPath: script.path) else {
            throw SessionCatalogError.unavailable(L("Claude session helper is missing. Reinstall the app; for debug builds run node scripts/prepare-claude-helper.mjs."))
        }
        let offset = cursor ?? "0"
        guard let value = Int(offset), value >= 0, value < 50_000, String(value) == offset else {
            throw SessionCatalogError.tooLarge
        }
        if FileManager.default.fileExists(atPath: source.root.path),
           !FileManager.default.isReadableFile(atPath: source.root.path) {
            throw SessionCatalogError.unavailable(L("The CLI session directory is not readable."))
        }
        let data = try SessionHelperProcess.readPage(executable: runtime, arguments: [script.path, offset],
            directory: helper, environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
                                            "CLAUDE_CONFIG_DIR": source.root.path], cancelled: cancelled)
        return try Self.decode(data, source: source, offset: value)
    }

    static func decode(_ data: Data, source: SessionCatalogSource, offset: Int) throws -> SessionCatalogPage {
        struct Record: Decodable { let id: String; let title: String; let cwd: String?; let updatedAt: Double }
        struct Response: Decodable { let version: Int; let sessions: [Record]; let nextCursor: String? }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), response.version == 1,
              response.sessions.count <= 100 else { throw SessionCatalogError.protocolFailure }
        if let next = response.nextCursor {
            guard next == String(offset + 100), response.sessions.count == 100 else { throw SessionCatalogError.protocolFailure }
        }
        let rows = try response.sessions.map { row -> AgentSession in
            guard UUID(uuidString: row.id) != nil, row.updatedAt.isFinite else { throw SessionCatalogError.protocolFailure }
            return AgentSession(key: .init(agent: .claude, sourceRoot: source.root.path, nativeID: row.id),
                title: row.title, workingDirectory: row.cwd,
                updatedAt: Date(timeIntervalSince1970: row.updatedAt / 1000))
        }
        guard Set(rows.map(\.key)).count == rows.count else { throw SessionCatalogError.protocolFailure }
        return SessionCatalogPage(sessions: rows, nextCursor: response.nextCursor)
    }
}

/// One-shot child lifecycle, bounded output and deadline. No credentials or hook routing inherited.
enum SessionHelperProcess {
    static func readPage(executable: URL, arguments: [String], directory: URL,
                         environment: [String: String], cancelled: () -> Bool,
                         timeout: TimeInterval = 15, maximumBytes: Int = 1024 * 1024) throws -> Data {
        if cancelled() { throw CancellationError() }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        try? pipe.fileHandleForWriting.close()
        defer {
            if process.isRunning { process.terminate() }
            let deadline = Date().addingTimeInterval(0.2)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? pipe.fileHandleForReading.close()
        }
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var result = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cancelled() { throw CancellationError() }
            var buffer = [UInt8](repeating: 0, count: 16384)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                result.append(contentsOf: buffer.prefix(count))
                if result.count > maximumBytes { throw SessionCatalogError.tooLarge }
            } else if count == 0 {
                if !process.isRunning {
                    guard process.terminationStatus == 0 else { throw SessionCatalogError.protocolFailure }
                    return result
                }
                Thread.sleep(forTimeInterval: 0.005)
            } else if errno == EAGAIN || errno == EINTR { Thread.sleep(forTimeInterval: 0.005) }
            else { throw SessionCatalogError.protocolFailure }
        }
        throw SessionCatalogError.timeout
    }
}
