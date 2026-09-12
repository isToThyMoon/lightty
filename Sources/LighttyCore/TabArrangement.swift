import Foundation

/// 一个标签页在编排里的样子：身份 + pane 排布。标题等展示信息归窗口层管，这里不关心。
public struct TabLayout: Sendable, Equatable {
    public let id: UUID
    public var layout: PaneLayout

    public init(id: UUID, layout: PaneLayout) {
        self.id = id
        self.layout = layout
    }
}

/// 窗口级的 pane / 标签页编排命令，全部是纯函数。
///
/// 每条命令要么返回完整的新编排，要么返回 nil 表示无效或无事可做，绝不产出中间态。
/// 视图层拿到结果后一次性渲染；跨窗口移动由调用方把"从源窗口移除"和"插进目标窗口"
/// 两步都算成功之后才提交，任一步无效就什么都不动。
/// 被移空的标签页在结果里直接消失，调用方比对前后身份就知道关掉了哪些。
public enum TabArrangement {
    public static func tabIndex(of pane: UUID, in tabs: [TabLayout]) -> Int? {
        tabs.firstIndex { $0.layout.contains(pane) }
    }

    // MARK: - 原子步骤

    /// 从编排里移除 pane，移空的标签页一并去掉。pane 不在任何标签页里返回 nil。
    public static func removing(_ pane: UUID, from tabs: [TabLayout]) -> [TabLayout]? {
        guard let index = tabIndex(of: pane, in: tabs) else { return nil }
        var result = tabs
        if let remaining = tabs[index].layout.removing(pane) {
            result[index].layout = remaining
        } else {
            result.remove(at: index)
        }
        return result
    }

    /// 把一个不在编排里的 pane 插到目标 pane 旁边。
    public static func inserting(_ pane: UUID, beside target: UUID, edge: PaneEdge,
                                 in tabs: [TabLayout]) -> [TabLayout]? {
        guard tabIndex(of: pane, in: tabs) == nil,
              let index = tabIndex(of: target, in: tabs),
              let layout = tabs[index].layout.inserting(pane, beside: target, edge: edge) else { return nil }
        var result = tabs
        result[index].layout = layout
        return result
    }

    /// 把一个不在编排里的 pane 并进指定标签页：接在树序最后一个 pane 的右侧。
    public static func inserting(_ pane: UUID, intoTab tabID: UUID, in tabs: [TabLayout]) -> [TabLayout]? {
        guard tabIndex(of: pane, in: tabs) == nil,
              let index = tabs.firstIndex(where: { $0.id == tabID }),
              let anchor = tabs[index].layout.panes.last else { return nil }
        return inserting(pane, beside: anchor, edge: .right, in: tabs)
    }

    // MARK: - 窗口内命令

    /// 把 pane 移到另一个 pane 旁边（可同标签页、可跨标签页）。
    public static func movingPane(_ pane: UUID, beside target: UUID, edge: PaneEdge,
                                  in tabs: [TabLayout]) -> [TabLayout]? {
        guard pane != target, let removed = removing(pane, from: tabs) else { return nil }
        return inserting(pane, beside: target, edge: edge, in: removed)
    }

    /// 把 pane 并进指定标签页。它本来就独占这个标签页时无事可做。
    public static func movingPane(_ pane: UUID, intoTab tabID: UUID, in tabs: [TabLayout]) -> [TabLayout]? {
        guard let source = tabIndex(of: pane, in: tabs),
              tabs.contains(where: { $0.id == tabID }) else { return nil }
        if tabs[source].id == tabID, tabs[source].layout.panes.count == 1 { return nil }
        guard let removed = removing(pane, from: tabs) else { return nil }
        return inserting(pane, intoTab: tabID, in: removed)
    }

    /// 把分屏里的 pane 拆出来独立成新标签页，插在第 index 位（移除后的坐标系；
    /// 源标签页还有别的 pane，所以移除不改变标签页数量）。它本来就独占标签页时无事可做。
    public static func detachingPane(_ pane: UUID, toNewTab tabID: UUID, at index: Int,
                                     in tabs: [TabLayout]) -> [TabLayout]? {
        guard let source = tabIndex(of: pane, in: tabs),
              tabs[source].layout.panes.count > 1,
              !tabs.contains(where: { $0.id == tabID }),
              var removed = removing(pane, from: tabs) else { return nil }
        removed.insert(TabLayout(id: tabID, layout: .pane(pane)), at: min(max(index, 0), removed.count))
        return removed
    }

    /// 标签页换位：第 from 个挪到第 to 位（摘掉之后的插入位）。原地不动返回 nil。
    public static func movingTab(from: Int, to: Int, in tabs: [TabLayout]) -> [TabLayout]? {
        guard tabs.indices.contains(from) else { return nil }
        let destination = min(max(to, 0), tabs.count - 1)
        guard destination != from else { return nil }
        var result = tabs
        result.insert(result.remove(at: from), at: destination)
        return result
    }
}
