import Foundation

struct SkillAnnotation: Codable, Equatable {
    var favorite: Bool = false
    var isMine: Bool = false
}

/// lightty 自己的组织信息；不改安装器记录或技能文件。
final class SkillOrganization {
    /// 所有设置窗口共享同一份状态，避免各自持有旧快照后互相覆盖收藏。
    static let shared = SkillOrganization()

    private struct Document: Codable {
        var version: Int = 1
        var annotations: [String: SkillAnnotation]
    }

    private enum OrganizationError: LocalizedError {
        case unsupportedVersion(Int)
        case unreadableDocument(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                return "Unsupported skills organization version: \(version)."
            case .unreadableDocument(let reason):
                return "Skills organization could not be loaded. The existing file has been preserved. \(reason)"
            }
        }
    }

    private let fileURL: URL
    private var annotations: [String: SkillAnnotation] = [:]
    private(set) var loadError: String?

    init(fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".lightty/skills-organization.json")) {
        self.fileURL = fileURL
        do {
            let data = try Data(contentsOf: fileURL)
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1 else {
                throw OrganizationError.unsupportedVersion(document.version)
            }
            annotations = document.annotations
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // 尚未保存过组织信息是正常的首次使用。
        } catch {
            loadError = error.localizedDescription
        }
    }

    func annotation(for id: String) -> SkillAnnotation {
        annotations[id] ?? SkillAnnotation()
    }

    func setFavorite(_ value: Bool, for id: String) throws {
        var annotation = annotation(for: id)
        annotation.favorite = value
        try save(annotation, for: id)
    }

    func setMine(_ value: Bool, for id: String) throws {
        var annotation = annotation(for: id)
        annotation.isMine = value
        try save(annotation, for: id)
    }

    private func save(_ annotation: SkillAnnotation, for id: String) throws {
        if let loadError {
            throw OrganizationError.unreadableDocument(loadError)
        }
        var updated = annotations
        if annotation == SkillAnnotation() {
            updated.removeValue(forKey: id)
        } else {
            updated[id] = annotation
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(annotations: updated))
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
        // 写入成功后才发布新状态，调用方失败时无需回滚 UI。
        annotations = updated
    }
}
