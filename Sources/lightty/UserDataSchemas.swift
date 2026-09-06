import Foundation
import LighttyCore

/// Register released schema steps here. Runtime models/stores know only the current shape.
enum UserDataSchemas {
    static func migration(for format: PersistenceFormat) -> JSONSchemaMigration {
        // First release: v1 only. Raise the affected format's version and add its steps here.
        JSONSchemaMigration(format: format.rawValue, currentVersion: format.currentVersion,
                            minimumVersion: 1, steps: [:])
    }

    static func validate(_ data: Data, as format: PersistenceFormat) throws {
        try format.validate(data)
        switch format {
        case .preferences:
            guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  document["values"] is [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        case .workspace: _ = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
        case .organization: _ = try JSONDecoder().decode(SessionOrganization.self, from: data)
        }
    }
}
