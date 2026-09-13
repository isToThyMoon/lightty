import Foundation

/// 工作区快照里一个标签页的分屏树：叶 = pane 的快照，节点 = 方向 + 各子项占比。
/// 叶子的内容归 app 层（命名、cwd、任务、会话），这里只管树形与它和 `PaneLayout`
/// 之间的换算，所以对叶子类型泛型。
///
/// 线格式是已发布的契约，不能改：`{"kind": "pane", "pane": …}` 与
/// `{"kind": "split", "vertical": …, "fractions": […], "children": […]}`。
/// `vertical` 沿用当年 NSSplitView.isVertical 的含义——**分隔线竖着**，也就是子项
/// 左右并排（`PaneAxis.horizontal`），与字面直觉相反。
public indirect enum SplitSnapshot<Leaf> {
    case pane(Leaf)
    case split(vertical: Bool, fractions: [Double], children: [SplitSnapshot<Leaf>])

    /// 树序第一个叶子（恢复时它就是窗口的 initialPane）
    public var firstLeaf: Leaf {
        switch self {
        case .pane(let leaf): return leaf
        case .split(_, _, let children): return children[0].firstLeaf
        }
    }

    public var leaves: [Leaf] {
        switch self {
        case .pane(let leaf): return [leaf]
        case .split(_, _, let children): return children.flatMap(\.leaves)
        }
    }
}

extension SplitSnapshot: Sendable where Leaf: Sendable {}
extension SplitSnapshot: Equatable where Leaf: Equatable {}

extension SplitSnapshot: Codable where Leaf: Codable {
    private enum CodingKeys: String, CodingKey { case kind, pane, vertical, fractions, children }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "pane":
            self = .pane(try c.decode(Leaf.self, forKey: .pane))
        case "split":
            let children = try c.decode([SplitSnapshot<Leaf>].self, forKey: .children)
            guard !children.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .children, in: c, debugDescription: "split without children")
            }
            self = .split(
                vertical: try c.decode(Bool.self, forKey: .vertical),
                fractions: try c.decode([Double].self, forKey: .fractions),
                children: children)
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "unknown node kind \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let leaf):
            try c.encode("pane", forKey: .kind)
            try c.encode(leaf, forKey: .pane)
        case .split(let vertical, let fractions, let children):
            try c.encode("split", forKey: .kind)
            try c.encode(vertical, forKey: .vertical)
            try c.encode(fractions, forKey: .fractions)
            try c.encode(children, forKey: .children)
        }
    }
}

// MARK: - 与排布树互换

extension SplitSnapshot {
    /// 排布树 → 快照树，比例直接取自模型。任何一个叶子取不到快照（视图已经不在），
    /// 整棵放弃——半棵树恢复出来的排布不是用户留下的样子。
    public init?(_ layout: PaneLayout, leaf: (UUID) -> Leaf?) {
        switch layout {
        case .pane(let id):
            guard let snapshot = leaf(id) else { return nil }
            self = .pane(snapshot)
        case .split(let axis, let branches):
            let children = branches.compactMap { SplitSnapshot($0.node, leaf: leaf) }
            guard children.count == branches.count else { return nil }
            self = .split(vertical: axis == .horizontal, fractions: branches.map(\.weight), children: children)
        }
    }

    /// 快照树 → 排布树。`pane` 按树序为每个叶子给出身份（通常顺手建好视图）；给不出
    /// 身份的叶子跳过，所在分屏的比例随之作废、改为均分，只剩一个孩子的分屏退化成那个孩子。
    public func layout(_ pane: (Leaf) -> UUID?) -> PaneLayout? {
        switch self {
        case .pane(let leaf):
            return pane(leaf).map(PaneLayout.pane)
        case .split(let vertical, let fractions, let children):
            let nodes = children.compactMap { $0.layout(pane) }
            let weights = nodes.count == children.count ? fractions : []
            return PaneLayout.split(vertical ? .horizontal : .vertical, weights: weights, children: nodes)
        }
    }
}
