import Foundation

/// Pure version conversion. Callers back up/write files only after all conversions validate.
public struct JSONSchemaMigration {
    public typealias Document = [String: Any]
    public typealias Step = (inout Document) throws -> Void
    public let format: String
    public let currentVersion: Int
    public let minimumVersion: Int
    private let steps: [Int: Step]

    public enum Failure: Error, Equatable {
        case wrongFormat, invalidVersion, unsupportedVersion(Int), missingStep(Int)
    }
    /// A step keyed by N converts N → N+1; version/discriminator changes belong to this runner.
    public init(format: String, currentVersion: Int, minimumVersion: Int, steps: [Int: Step] = [:]) {
        self.format = format
        self.currentVersion = currentVersion
        self.minimumVersion = minimumVersion
        self.steps = steps
    }

    public func convert(_ data: Data) throws -> Data {
        guard var document = try JSONSerialization.jsonObject(with: data) as? Document,
              document["format"] as? String == format else { throw Failure.wrongFormat }
        let version = try JSONDecoder().decode(Version.self, from: data).version
        guard version >= 1 else { throw Failure.invalidVersion }
        guard version >= minimumVersion, version <= currentVersion else { throw Failure.unsupportedVersion(version) }
        // No rewrite, backup or timestamp churn on subsequent launches.
        guard version < currentVersion else { return data }
        for from in version..<currentVersion {
            guard let step = steps[from] else { throw Failure.missingStep(from) }
            try step(&document)
            document["format"] = format
            document["version"] = from + 1
        }
        return try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    }
    private struct Version: Decodable { let version: Int }
}
