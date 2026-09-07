import Foundation

/// Independent, released document contracts. App versions never select a JSON schema.
public enum PersistenceFormat: String, CaseIterable {
    case preferences = "lightty.preferences"
    case workspace = "lightty.workspace"
    case organization = "lightty.organization"

    public var currentVersion: Int {
        switch self {
        case .preferences: return 1
        case .workspace: return 1
        case .organization: return 1
        }
    }
    public var fileName: String {
        switch self {
        case .preferences: return "preferences.json"
        case .workspace: return "workspace.json"
        case .organization: return "organization.json"
        }
    }
    public var relativePath: String { ".lightty/" + fileName }

    /// Check the discriminator before decoding payloads or writing to an existing file.
    /// Future breaking versions get an explicit migration at the storage seam, not
    /// compatibility branches in models/views. No fictitious pre-release version chain.
    public func validate(_ data: Data) throws {
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard header.format == rawValue, header.version == currentVersion else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
    private struct Header: Decodable { let format: String; let version: Int }
}
