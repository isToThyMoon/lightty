import XCTest
@testable import LighttyCore

final class SplitSnapshotTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()

    /// 已发布的线格式：一份用户手里的快照原样读得进来，再写出去逐字节同形。
    func testTheWireFormatStaysReadable() throws {
        let json = """
        {"children":[{"kind":"pane","pane":"left"},{"children":[{"kind":"pane","pane":"top"},\
        {"kind":"pane","pane":"bottom"}],"fractions":[0.5,0.5],"kind":"split","vertical":false}],\
        "fractions":[0.3,0.7],"kind":"split","vertical":true}
        """
        let tree = try JSONDecoder().decode(SplitSnapshot<String>.self, from: Data(json.utf8))
        XCTAssertEqual(tree, .split(vertical: true, fractions: [0.3, 0.7], children: [
            .pane("left"), .split(vertical: false, fractions: [0.5, 0.5], children: [.pane("top"), .pane("bottom")]),
        ]))
        XCTAssertEqual(tree.leaves, ["left", "top", "bottom"])
        XCTAssertEqual(tree.firstLeaf, "left")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(String(decoding: try encoder.encode(tree), as: UTF8.self), json)
        XCTAssertThrowsError(try JSONDecoder().decode(SplitSnapshot<String>.self,
            from: Data(#"{"kind":"split","vertical":true,"fractions":[],"children":[]}"#.utf8)))
    }

    /// vertical 沿用 NSSplitView 的含义：分隔线竖着 = 左右并排 = `.horizontal`。
    func testVerticalMeansSideBySide() throws {
        let layout = try XCTUnwrap(PaneLayout.split(.horizontal, weights: [0.3, 0.7], children: [
            .pane(a), try XCTUnwrap(PaneLayout.pane(b).inserting(c, beside: b, edge: .bottom)),
        ]))
        let names = [a: "a", b: "b", c: "c"]
        let snapshot = try XCTUnwrap(SplitSnapshot(layout) { names[$0] })
        guard case .split(true, let fractions, let children) = snapshot,
              case .split(false, _, _) = children[1] else { return XCTFail("左右分屏套上下分屏") }
        XCTAssertEqual(fractions, [0.3, 0.7])

        let ids = Dictionary(uniqueKeysWithValues: names.map { ($1, $0) })
        XCTAssertEqual(snapshot.layout { ids[$0] }, layout, "往返后比例、方向、树形一致")
    }

    func testMissingLeavesDropTheWholeTreeOnCaptureButOnlyTheLeafOnRestore() throws {
        let layout = try XCTUnwrap(PaneLayout.split(.horizontal, weights: [0.2, 0.3, 0.5],
            children: [.pane(a), .pane(b), .pane(c)]))
        XCTAssertNil(SplitSnapshot(layout) { $0 == b ? nil : "x" }, "半棵树不是用户留下的样子")

        let snapshot = SplitSnapshot<String>.split(vertical: true, fractions: [0.2, 0.3, 0.5],
                                                   children: [.pane("a"), .pane("gone"), .pane("c")])
        let restored = snapshot.layout { ["a": a, "c": c][$0] }
        XCTAssertEqual(restored, .split(.horizontal, [.init(weight: 0.5, node: .pane(a)), .init(weight: 0.5, node: .pane(c))]),
                       "少了一个孩子，比例作废改为均分")
        XCTAssertEqual(SplitSnapshot<String>.split(vertical: false, fractions: [0.5, 0.5],
                                                   children: [.pane("a"), .pane("gone")]).layout { ["a": a][$0] },
                       .pane(a), "只剩一个孩子的分屏退化成它")
        XCTAssertNil(SplitSnapshot<String>.pane("gone").layout { _ in nil })
    }
}
