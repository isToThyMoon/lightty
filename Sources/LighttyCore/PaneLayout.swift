import CoreGraphics
import Foundation

/// 分屏的排布方向。
public enum PaneAxis: Sendable, Equatable {
    /// 子节点左右并排，分隔线是竖线。
    case horizontal
    /// 子节点上下堆叠，分隔线是横线。
    case vertical
}

/// 相对目标 pane 的落点边：新 pane 放在目标的哪一侧。
public enum PaneEdge: Sendable, Equatable, CaseIterable {
    case left, right, top, bottom

    public var axis: PaneAxis { self == .left || self == .right ? .horizontal : .vertical }
    /// 放在目标之前（左 / 上）还是之后（右 / 下）。
    public var placesBefore: Bool { self == .left || self == .top }
}

/// 一个标签页内 pane 的排布：值类型的树，叶子是 pane 的身份，分支带比例。
///
/// 为什么要有它：以前视图层级本身就是模型，每个移动都是一串 NSSplitView 手术——
/// 摘子视图、解包、同步强制布局、再推到下一拍去摆分隔线。任何一步出岔子（包括
/// AppKit 自己的约束求解器在连续改动 NSSplitView 子视图时报内部不一致），树就停在
/// 改到一半的样子。现在所有变换都是纯函数：先算出完整的新树，确认合法，再一次性
/// 交给视图渲染，中间态不存在。
///
/// 语义对齐 Ghostty 上游的 `SplitTree`：插入**无条件**把目标叶子原位包成二叉分屏
/// （内部对半分，外层尺寸不动，同方向也不压平）；移除时兄弟节点接管空出来的位置。
public indirect enum PaneLayout: Sendable, Equatable {
    case pane(UUID)
    case split(PaneAxis, [Branch])

    public struct Branch: Sendable, Equatable {
        /// 在同一分屏内占可用长度的比例；同一分屏内各分支之和为 1。
        public var weight: Double
        public var node: PaneLayout

        public init(weight: Double, node: PaneLayout) {
            self.weight = weight
            self.node = node
        }
    }

    /// 从外部数据（快照）建分屏：比例缺失、非法或数量对不上时均分；少于两个子节点
    /// 的分屏没有意义，直接退化成那个子节点。
    public static func split(_ axis: PaneAxis, weights: [Double], children: [PaneLayout]) -> PaneLayout? {
        guard !children.isEmpty else { return nil }
        guard children.count > 1 else { return children[0] }
        let valid = weights.count == children.count && weights.allSatisfy { $0.isFinite && $0 > 0 }
        let raw = valid ? weights : Array(repeating: 1, count: children.count)
        let total = raw.reduce(0, +)
        return .split(axis, zip(raw, children).map { Branch(weight: $0 / total, node: $1) })
    }

    // MARK: - 查询

    /// 树序（左→右、上→下）的全部 pane。
    public var panes: [UUID] {
        switch self {
        case .pane(let id): return [id]
        case .split(_, let branches): return branches.flatMap(\.node.panes)
        }
    }

    public func contains(_ id: UUID) -> Bool {
        switch self {
        case .pane(let pane): return pane == id
        case .split(_, let branches): return branches.contains { $0.node.contains(id) }
        }
    }

    /// pane 在树里的分支下标路径；不在树里返回 nil。
    public func path(of id: UUID) -> [Int]? {
        switch self {
        case .pane(let pane): return pane == id ? [] : nil
        case .split(_, let branches):
            for (index, branch) in branches.enumerated() {
                if let rest = branch.node.path(of: id) { return [index] + rest }
            }
            return nil
        }
    }

    public func node(at path: [Int]) -> PaneLayout? {
        guard let first = path.first else { return self }
        guard case .split(_, let branches) = self, branches.indices.contains(first) else { return nil }
        return branches[first].node.node(at: Array(path.dropFirst()))
    }

    // MARK: - 结构变换

    /// 移除一个 pane。空出来的比例交给相邻兄弟（优先前一个），只剩一个子节点的
    /// 分屏解包成那个子节点，它原样接管分屏在上一层的位置。
    /// 树被移空返回 nil；pane 不在树里时原样返回。
    public func removing(_ id: UUID) -> PaneLayout? {
        switch self {
        case .pane(let pane):
            return pane == id ? nil : self
        case .split(let axis, var branches):
            guard let index = branches.firstIndex(where: { $0.node.contains(id) }) else { return self }
            if let remaining = branches[index].node.removing(id) {
                branches[index].node = remaining
                return .split(axis, branches)
            }
            let freed = branches.remove(at: index).weight
            guard !branches.isEmpty else { return nil }
            guard branches.count > 1 else { return branches[0].node }
            branches[index > 0 ? index - 1 : 0].weight += freed
            return .split(axis, branches)
        }
    }

    /// 把 pane 插到目标旁边：目标叶子原位包成二叉分屏，两半对半分。
    /// 目标不在树里、或 pane 已经在树里时返回 nil——调用方据此判定命令无效。
    public func inserting(_ id: UUID, beside target: UUID, edge: PaneEdge) -> PaneLayout? {
        guard contains(target), !contains(id) else { return nil }
        return replacingLeaf(target) { leaf in
            let new = PaneLayout.pane(id)
            let pair = edge.placesBefore ? [new, leaf] : [leaf, new]
            return .split(edge.axis, pair.map { Branch(weight: 0.5, node: $0) })
        }
    }

    /// 每个分屏内各分支等分（equalize_splits）。
    public func equalized() -> PaneLayout {
        switch self {
        case .pane: return self
        case .split(let axis, let branches):
            let weight = 1 / Double(branches.count)
            return .split(axis, branches.map { Branch(weight: weight, node: $0.node.equalized()) })
        }
    }

    private func replacingLeaf(_ id: UUID, with transform: (PaneLayout) -> PaneLayout) -> PaneLayout {
        switch self {
        case .pane(let pane):
            return pane == id ? transform(self) : self
        case .split(let axis, let branches):
            return .split(axis, branches.map {
                Branch(weight: $0.weight, node: $0.node.replacingLeaf(id, with: transform))
            })
        }
    }

    private func replacing(at path: [Int], with replacement: PaneLayout) -> PaneLayout {
        guard let first = path.first else { return replacement }
        guard case .split(let axis, var branches) = self, branches.indices.contains(first) else { return self }
        branches[first].node = branches[first].node.replacing(at: Array(path.dropFirst()), with: replacement)
        return .split(axis, branches)
    }
}

// MARK: - 几何

/// 渲染一棵排布树得到的几何：每个 pane 的 frame 与每条分隔线。坐标系原点在左上，
/// y 向下（渲染视图是 flipped 的），与"左→右、上→下"的树序一致。
public struct PaneLayoutGeometry: Sendable, Equatable {
    public struct Divider: Sendable, Equatable {
        /// 所属分屏在树里的路径。
        public var path: [Int]
        /// 位于第 index 与 index+1 个分支之间。
        public var index: Int
        public var axis: PaneAxis
        /// 可见线条的矩形（厚度即分隔线粗细）。
        public var rect: CGRect

        public init(path: [Int], index: Int, axis: PaneAxis, rect: CGRect) {
            self.path = path
            self.index = index
            self.axis = axis
            self.rect = rect
        }
    }

    public var panes: [UUID: CGRect] = [:]
    public var dividers: [Divider] = []
    /// 每个分屏节点占的矩形，按路径索引；拖分隔线时换算比例要用。
    public var splits: [[Int]: CGRect] = [:]
}

extension PaneLayout {
    /// 在 rect 里摆出整棵树。边界先按累计比例算出、再对齐到物理像素，每个子节点的
    /// 范围由相邻边界夹出——不是各自四舍五入，所以 pane 与分隔线之间不会出现
    /// 一像素的缝或重叠；最后一个子节点的末端钉死在 rect 边上，不累积漂移。
    public func geometry(in rect: CGRect, dividerThickness: CGFloat, scale: CGFloat) -> PaneLayoutGeometry {
        var result = PaneLayoutGeometry()
        let pixel = scale > 0 ? scale : 1
        let thickness = max(1 / pixel, (dividerThickness * pixel).rounded() / pixel)
        place(in: rect, path: [], thickness: thickness, pixel: pixel, into: &result)
        return result
    }

    private func place(in rect: CGRect, path: [Int], thickness: CGFloat, pixel: CGFloat,
                       into result: inout PaneLayoutGeometry) {
        switch self {
        case .pane(let id):
            result.panes[id] = rect
        case .split(let axis, let branches):
            result.splits[path] = rect
            let horizontal = axis == .horizontal
            let start = horizontal ? rect.minX : rect.minY
            let end = horizontal ? rect.maxX : rect.maxY
            let available = max(0, (end - start) - thickness * CGFloat(branches.count - 1))
            var cumulative = 0.0
            var childStart = start
            for (index, branch) in branches.enumerated() {
                cumulative += branch.weight
                let isLast = index == branches.count - 1
                let exact = start + CGFloat(cumulative) * available + thickness * CGFloat(index)
                let childEnd = isLast ? end : max(childStart, (exact * pixel).rounded() / pixel)
                let childRect = horizontal
                    ? CGRect(x: childStart, y: rect.minY, width: childEnd - childStart, height: rect.height)
                    : CGRect(x: rect.minX, y: childStart, width: rect.width, height: childEnd - childStart)
                branch.node.place(in: childRect, path: path + [index], thickness: thickness,
                                  pixel: pixel, into: &result)
                guard !isLast else { break }
                let line = horizontal
                    ? CGRect(x: childEnd, y: rect.minY, width: thickness, height: rect.height)
                    : CGRect(x: rect.minX, y: childEnd, width: rect.width, height: thickness)
                result.dividers.append(.init(path: path, index: index, axis: axis, rect: line))
                childStart = childEnd + thickness
            }
        }
    }

    /// 把第 path 个分屏里第 index 条分隔线拖到 position（分隔线起点在 rect 坐标系里的
    /// 位置）。只重分相邻两个分支的合计长度，其余分支不动；两侧都不小于 minimumSize，
    /// 合计长度连两个最小值都放不下时对半分。
    public func movingDivider(at path: [Int], index: Int, to position: CGFloat, in rect: CGRect,
                              dividerThickness: CGFloat, scale: CGFloat, minimumSize: CGFloat) -> PaneLayout {
        let geometry = geometry(in: rect, dividerThickness: dividerThickness, scale: scale)
        guard case .split(let axis, var branches)? = node(at: path),
              branches.indices.contains(index + 1) else { return self }
        let horizontal = axis == .horizontal
        let childRects = (0..<branches.count).compactMap { child -> CGRect? in
            let childPath = path + [child]
            if case .pane(let id)? = node(at: childPath) { return geometry.panes[id] }
            return geometry.splits[childPath]
        }
        guard childRects.count == branches.count else { return self }
        let lead = childRects[index], trail = childRects[index + 1]
        let leadStart = horizontal ? lead.minX : lead.minY
        let combined = horizontal ? lead.width + trail.width : lead.height + trail.height
        guard combined > 0 else { return self }
        let size: CGFloat = combined < minimumSize * 2
            ? combined / 2
            : min(max(position - leadStart, minimumSize), combined - minimumSize)
        let pairWeight = branches[index].weight + branches[index + 1].weight
        branches[index].weight = pairWeight * Double(size / combined)
        branches[index + 1].weight = pairWeight - branches[index].weight
        return replacing(at: path, with: .split(axis, branches))
    }

    /// resize_split：把 pane 朝 edge 那侧的边界外推 amount。只看离 pane 最近的同轴
    /// 分屏；pane 在那一侧已经贴边（没有兄弟）时不动——与 Ghostty 一致，不再往上找。
    public func resizing(_ id: UUID, toward edge: PaneEdge, by amount: CGFloat, in rect: CGRect,
                         dividerThickness: CGFloat, scale: CGFloat, minimumSize: CGFloat) -> PaneLayout {
        guard var path = path(of: id) else { return self }
        let geometry = geometry(in: rect, dividerThickness: dividerThickness, scale: scale)
        while let childIndex = path.popLast() {
            guard case .split(let axis, let branches)? = node(at: path), axis == edge.axis else { continue }
            let dividerIndex = edge.placesBefore ? childIndex - 1 : childIndex
            guard branches.indices.contains(dividerIndex), branches.indices.contains(dividerIndex + 1),
                  let divider = geometry.dividers.first(where: { $0.path == path && $0.index == dividerIndex })
            else { return self }
            let current = axis == .horizontal ? divider.rect.minX : divider.rect.minY
            return movingDivider(at: path, index: dividerIndex,
                                 to: current + (edge.placesBefore ? -amount : amount),
                                 in: rect, dividerThickness: dividerThickness, scale: scale,
                                 minimumSize: minimumSize)
        }
        return self
    }
}
