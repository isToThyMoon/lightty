import XCTest
@testable import LighttyCore

final class JSONSchemaMigrationTests: XCTestCase {
    func testSequentialTransformsLeaveOnlyCurrentFieldsAndPreserveUnknowns() throws {
        let migration = JSONSchemaMigration(format: "lightty.preferences", currentVersion: 3, minimumVersion: 1, steps: [
            1: { $0["appearance"] = $0.removeValue(forKey: "theme") },
            2: { $0["appearance"] = ["mode": $0["appearance"] ?? "system"] }
        ])
        let original = Data(#"{"format":"lightty.preferences","version":1,"theme":"dark","extension":true}"#.utf8)
        let converted = try migration.convert(original)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: converted) as? [String: Any])
        XCTAssertEqual(result["version"] as? Int, 3)
        XCTAssertNil(result["theme"])
        XCTAssertEqual((result["appearance"] as? [String: String])?["mode"], "dark")
        XCTAssertEqual(result["extension"] as? Bool, true)
        XCTAssertEqual(try migration.convert(converted), converted)
    }

    func testMissingStepsUnsupportedVersionsAndWrongFileTypesFail() {
        let migration = JSONSchemaMigration(format: "lightty.workspace", currentVersion: 3, minimumVersion: 2)
        for data in [
            #"{"format":"lightty.workspace","version":1}"#,
            #"{"format":"lightty.workspace","version":2}"#, // missing 2 → 3
            #"{"format":"lightty.workspace","version":4}"#,
            #"{"format":"lightty.preferences","version":3}"#,
            #"{"format":"lightty.workspace","version":true}"#,
            #"{"format":"lightty.workspace","version":2.5}"#,
            #"{"format":"lightty.workspace","version":0}"#, "broken"
        ] { XCTAssertThrowsError(try migration.convert(Data(data.utf8))) }
    }
}
