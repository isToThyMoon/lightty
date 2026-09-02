import CoreText
import CryptoKit
import Foundation

enum TerminalFontDownloadPhase {
    case downloading(Double)
    case installing
}

enum TerminalFontDownloadError: LocalizedError {
    case alreadyDownloading
    case badResponse
    case checksumMismatch
    case malformedArchive(String)
    case extractionFailed(Int32)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .alreadyDownloading:
            return "A font download is already running."
        case .badResponse:
            return "The font server returned an invalid response."
        case .checksumMismatch:
            return "The downloaded font archive failed verification."
        case .malformedArchive(let detail):
            return "The font archive is incomplete (\(detail))."
        case .extractionFailed(let status):
            return "The font archive could not be extracted (status \(status))."
        case .cancelled:
            return "The font download was cancelled."
        }
    }
}

/// Optional downloader/installer for Lightty's default terminal font.
///
/// The app itself stays small. A verified upstream archive is downloaded only after the
/// user accepts, then four terminal faces are installed through the normal per-user path
/// (`~/Library/Fonts`). macOS discovers fonts from that standard path; Ghostty then consumes
/// the family through ordinary system font discovery. Lightty owns no private font path and
/// performs no dynamic font registration.
final class TerminalFontManager {
    static let shared = TerminalFontManager()

    static let familyName = "Maple Mono NF CN"
    static let archiveURL = URL(string:
        "https://github.com/subframe7536/Maple-font/releases/download/v7.9/MapleMono-NF-CN-unhinted.zip"
    )!
    static let archiveSHA256 = "ab88522932cf4015dffeaef6dedc59a22a5fefecdcc6e583d9fcd997da5b7cac"

    static let faceFiles = [
        "MapleMono-NF-CN-Regular.ttf": "Regular",
        "MapleMono-NF-CN-Bold.ttf": "Bold",
        "MapleMono-NF-CN-Italic.ttf": "Italic",
        "MapleMono-NF-CN-BoldItalic.ttf": "Bold Italic",
    ]

    private let fileManager = FileManager.default
    private var downloadTask: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?

    private(set) var isLighttyFontAvailable = false
    var isDownloading: Bool { downloadTask != nil }

    private init() {}

    func refreshAvailability() {
        isLighttyFontAvailable = Self.hasAvailableFamily()
    }

    func download(
        progress: @escaping (TerminalFontDownloadPhase) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard downloadTask == nil else {
            completion(.failure(TerminalFontDownloadError.alreadyDownloading))
            return
        }

        let task = URLSession.shared.downloadTask(with: Self.archiveURL) { [weak self] url, response, error in
            guard let self else { return }

            if let error = error as? URLError, error.code == .cancelled {
                self.finishDownload(.failure(TerminalFontDownloadError.cancelled), completion: completion)
                return
            }
            if let error {
                self.finishDownload(.failure(error), completion: completion)
                return
            }
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let url
            else {
                self.finishDownload(.failure(TerminalFontDownloadError.badResponse), completion: completion)
                return
            }

            DispatchQueue.main.async { progress(.installing) }
            do {
                try self.installArchive(at: url)
                self.isLighttyFontAvailable = true
                self.finishDownload(.success(()), completion: completion)
            } catch {
                self.finishDownload(.failure(error), completion: completion)
            }
        }

        progressObservation = task.progress.observe(\.fractionCompleted, options: [.new]) {
            _, change in
            guard let value = change.newValue, value.isFinite else { return }
            DispatchQueue.main.async { progress(.downloading(value)) }
        }
        downloadTask = task
        task.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    private func finishDownload(
        _ result: Result<Void, Error>,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        DispatchQueue.main.async {
            self.progressObservation = nil
            self.downloadTask = nil
            completion(result)
        }
    }

    private var userFontDirectory: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Fonts", isDirectory: true)
    }

    private static func hasAvailableFamily() -> Bool {
        let families = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        return families.contains(familyName)
    }

    private func installArchive(at archive: URL) throws {
        guard try Self.sha256(of: archive) == Self.archiveSHA256 else {
            throw TerminalFontDownloadError.checksumMismatch
        }

        let staging = fileManager.temporaryDirectory.appendingPathComponent(
            ".MapleMono-NF-CN-\(UUID().uuidString)", isDirectory: true)
        let expanded = staging.appendingPathComponent("expanded", isDirectory: true)
        try fileManager.createDirectory(at: expanded, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, expanded.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw TerminalFontDownloadError.extractionFailed(ditto.terminationStatus)
        }

        let files = try indexedFiles(under: expanded)
        var validatedFonts: [(name: String, source: URL)] = []
        for (name, expectedStyle) in Self.faceFiles {
            guard let source = files[name] else {
                throw TerminalFontDownloadError.malformedArchive("missing \(name)")
            }
            try Self.validateFont(source, expectedStyle: expectedStyle)
            validatedFonts.append((name, source))
        }
        guard let license = files["LICENSE.txt"] else {
            throw TerminalFontDownloadError.malformedArchive("missing LICENSE.txt")
        }

        // 在触碰 ~/Library/Fonts 之前先完成整包校验；损坏或缺文件的归档不能
        // 产生“只装了一半字面”的系统字体状态。
        try fileManager.createDirectory(at: userFontDirectory, withIntermediateDirectories: true)
        for (name, source) in validatedFonts {
            let destination = userFontDirectory.appendingPathComponent(name)
            try installFileAtomically(from: source, to: destination)
        }
        try installFileAtomically(
            from: license,
            to: userFontDirectory.appendingPathComponent("MapleMono-NF-CN-OFL.txt"))
    }

    private func installFileAtomically(from source: URL, to destination: URL) throws {
        let incoming = destination.deletingLastPathComponent().appendingPathComponent(
            ".lightty-\(UUID().uuidString)-\(destination.lastPathComponent)")
        try fileManager.copyItem(at: source, to: incoming)
        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: incoming)
            } else {
                try fileManager.moveItem(at: incoming, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: incoming)
            throw error
        }
    }

    private func indexedFiles(under root: URL) throws -> [String: URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return [:] }

        var result: [String: URL] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true { result[url.lastPathComponent] = url }
        }
        return result
    }

    private static func validateFont(_ url: URL, expectedStyle: String) throws {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL)
                as? [CTFontDescriptor],
              let descriptor = descriptors.first,
              let family = CTFontDescriptorCopyAttribute(
                descriptor, kCTFontFamilyNameAttribute) as? String,
              let style = CTFontDescriptorCopyAttribute(
                descriptor, kCTFontStyleNameAttribute) as? String,
              family == familyName,
              style == expectedStyle
        else {
            throw TerminalFontDownloadError.malformedArchive(
                "unexpected font metadata in \(url.lastPathComponent)")
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
