import Foundation

/// 标签页名。默认名只存序号，显示时才按当前语言格式化；用户改过的名字原样存。
///
/// 为什么不再只存字符串：以前「是否改过名」靠拿标题去匹配当前语言的「标签页 %d」
/// 反推，切一次语言，所有默认名都匹配不上，全部被当成用户起的名字。
public enum TabTitle: Sendable, Equatable {
    case numbered(Int)
    case custom(String)

    public var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    /// 默认名的序号；用户起的名字没有序号。
    public var number: Int? {
        if case .numbered(let number) = self { return number }
        return nil
    }

    /// 按默认名格式（形如 "Tab %d"，取当前语言）解析一个标题字符串：匹配就是默认名，
    /// 否则是用户起的名字。只用于迁移旧数据，新数据显式存了是否改过名。
    public static func parsing(_ title: String, defaultFormat: String) -> TabTitle {
        let prefix = defaultFormat.replacingOccurrences(of: "%d", with: "")
        guard title.hasPrefix(prefix),
              let number = Int(title.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces))
        else { return .custom(title) }
        return .numbered(number)
    }

    /// 从快照读回。`customTitle` 为 nil 说明是还没有这个字段的旧快照：按旧规则反推一次，
    /// 之后再存就是显式的了。字段自相矛盾（说是默认名却没有序号）也按旧规则兜底。
    public static func restored(title: String, customTitle: Bool?, number: Int?,
                                defaultFormat: String) -> TabTitle {
        switch (customTitle, number) {
        case (true?, _): return .custom(title)
        case (false?, let number?): return .numbered(number)
        default: return parsing(title, defaultFormat: defaultFormat)
        }
    }
}

/// 窗口编排里的一个标签页：身份、pane 排布、标题、放大态、最近聚焦的 pane。
public struct ArrangedTab: Sendable, Equatable {
    public let id: UUID
    public var layout: PaneLayout
    public var title: TabTitle
    /// 放大中的 pane（toggle_split_zoom）。结构一变就失效。
    public var zoomedPane: UUID?
    /// 本标签页最近聚焦的 pane，只经 `WindowArrangement.focusing` 记录；pane 离开标签页即清掉。
    /// 标签页切走再切回来、first responder 暂时不在终端里时，焦点从这里找回。
    public internal(set) var focusedPane: UUID?

    public init(id: UUID, layout: PaneLayout, title: TabTitle, zoomedPane: UUID? = nil) {
        self.id = id
        self.layout = layout
        self.title = title
        self.zoomedPane = zoomedPane
    }

    /// 该交还焦点的 pane：记录的焦点，没有就取树序第一个。
    public var focusTarget: UUID? { focusedPane ?? layout.panes.first }
}

/// 一个窗口的完整编排：有序的标签页 + 当前标签页。值类型，全部命令是纯函数。
///
/// 每条命令要么返回完整的新编排，要么返回 nil 表示无效或无事可做，绝不产出中间态。
/// 侧栏、快捷键、撤销、快照恢复都按标签页 / pane 的身份下命令，序号只在需要序号的
/// 命令（goto_tab N、move_tab 环绕）内部换算——列表随时可能变，身份不会。
///
/// 三条贯穿所有命令的规则集中在这里，调用方不再各自处理：
/// - 当前标签页被移除时，落到它原来位次上的邻居（越界取最后一个）。
/// - 标签页的排布结构变了，它的放大态作废；只改比例不算结构变化。
/// - pane 离开标签页（关闭、移走、拆出、跨窗口移出）时，它不再是那个标签页的焦点。
public struct WindowArrangement: Sendable, Equatable {
    public private(set) var tabs: [ArrangedTab]
    public private(set) var activeTabID: UUID?

    /// `activeTabID` 不在 `tabs` 里时取第一个标签页。
    public init(tabs: [ArrangedTab] = [], activeTabID: UUID? = nil) {
        self.tabs = tabs
        self.activeTabID = activeTabID.flatMap { id in tabs.contains { $0.id == id } ? id : nil } ?? tabs.first?.id
    }

    /// 快照恢复：当前标签页按位次给出，越界夹到两端。
    public init(restoring tabs: [ArrangedTab], activeIndex: Int) {
        let index = tabs.isEmpty ? nil : min(max(activeIndex, 0), tabs.count - 1)
        self.init(tabs: tabs, activeTabID: index.map { tabs[$0].id })
    }

    // MARK: - 查询

    public var activeTab: ArrangedTab? { activeTabID.flatMap(tab) }
    /// 当前标签页该交还焦点的 pane（见 `ArrangedTab.focusTarget`）。
    public var focusTarget: UUID? { activeTab?.focusTarget }
    public var activeIndex: Int? { activeTabID.flatMap(index) }

    public func tab(_ id: UUID) -> ArrangedTab? { tabs.first { $0.id == id } }
    public func index(of id: UUID) -> Int? { tabs.firstIndex { $0.id == id } }
    public func tabID(hosting pane: UUID) -> UUID? { tabs.first { $0.layout.contains(pane) }?.id }

    /// 全部 pane，按标签页、再按树序。
    public var panes: [UUID] { tabs.flatMap(\.layout.panes) }

    /// 默认名里用到的最大序号；新标签页的默认名要从它之后接着编。
    public var highestTitleNumber: Int { tabs.compactMap(\.title.number).max() ?? 0 }

    /// 标签页身份不重复、pane 不重复、当前标签页在列表里（空窗口没有当前标签页）。
    public var isWellFormed: Bool {
        let panes = self.panes
        return Set(tabs.map(\.id)).count == tabs.count
            && Set(panes).count == panes.count
            && (tabs.isEmpty ? activeTabID == nil : activeTab != nil)
    }

    // MARK: - 选中

    /// 选中某个标签页。它已经是当前标签页也算有效（调用方可能要借此重新交还焦点）。
    public func selecting(_ id: UUID) -> WindowArrangement? {
        guard tab(id) != nil else { return nil }
        var next = self
        next.activeTabID = id
        return next
    }

    /// core goto_tab 的目标。`index` 是 1-based 序号，超界落到最后一个。
    public enum TabTarget: Sendable, Equatable {
        case previous, next, last, index(Int)
    }

    /// core goto_tab：只有一个标签页时无事可做；前后切换环绕。
    public func selecting(_ target: TabTarget) -> WindowArrangement? {
        guard tabs.count > 1, let current = activeIndex else { return nil }
        let destination: Int
        switch target {
        case .previous: destination = current == 0 ? tabs.count - 1 : current - 1
        case .next: destination = current == tabs.count - 1 ? 0 : current + 1
        case .last: destination = tabs.count - 1
        case .index(let number): destination = min(max(0, number - 1), tabs.count - 1)
        }
        return selecting(tabs[destination].id)
    }

    /// 记下某个 pane 是它所在标签页最近聚焦的那个。不换当前标签页：终端拿到焦点时
    /// 它所在的标签页本来就是当前的，要切标签页由调用方另下 `selecting`。
    public func focusing(_ pane: UUID) -> WindowArrangement? {
        guard let index = tabs.firstIndex(where: { $0.layout.contains(pane) }) else { return nil }
        var next = self
        next.tabs[index].focusedPane = pane
        return next
    }

    // MARK: - 标签页

    /// 追加一个标签页。`select` 为 false 时当前标签页不变（空窗口仍会选中它）。
    public func appendingTab(_ id: UUID, layout: PaneLayout, title: TabTitle,
                             select: Bool) -> WindowArrangement? {
        guard tab(id) == nil, layout.panes.allSatisfy({ tabID(hosting: $0) == nil }) else { return nil }
        let layouts = tabLayouts + [TabLayout(id: id, layout: layout)]
        return adopting(layouts, newTitles: [id: title], select: select ? id : nil)
    }

    /// core close_tab 的范围，相对当前标签页。关闭本身走 `removingPanes`。
    public enum CloseScope: Sendable, Equatable {
        case this, other, right
    }

    /// 某个关闭范围里的标签页；没有当前标签页时为空。
    public func tabIDs(in scope: CloseScope) -> Set<UUID> {
        guard let current = activeIndex else { return [] }
        let doomed: [ArrangedTab]
        switch scope {
        case .this: doomed = [tabs[current]]
        case .other: doomed = tabs.enumerated().filter { $0.offset != current }.map(\.element)
        case .right: doomed = Array(tabs[(current + 1)...])
        }
        return Set(doomed.map(\.id))
    }

    /// 改名：用户起的名字从此不再是默认名。
    public func renamingTab(_ id: UUID, to title: String) -> WindowArrangement? {
        guard let index = index(of: id) else { return nil }
        var next = self
        next.tabs[index].title = .custom(title)
        return next
    }

    /// 标签页换位：挪到 `anchor` 之后，anchor 为 nil 挪到最前。anchor 按身份给出，
    /// 期间有别的标签页被关掉也落在同一个邻居后面；anchor 自己没了命令就作废。
    /// 原地不动返回 nil。选中项跟着标签页本体走。
    public func movingTab(_ id: UUID, after anchor: UUID?) -> WindowArrangement? {
        guard let from = index(of: id), anchor != id else { return nil }
        let rest = tabs.filter { $0.id != id }
        let destination: Int
        if let anchor {
            guard let found = rest.firstIndex(where: { $0.id == anchor }) else { return nil }
            destination = found + 1
        } else {
            destination = 0
        }
        return TabArrangement.movingTab(from: from, to: destination, in: tabLayouts).flatMap { adopting($0) }
    }

    /// core move_tab：当前标签页移动 amount 位，环绕。
    public func movingActiveTab(by amount: Int) -> WindowArrangement? {
        guard tabs.count > 1, amount != 0, let current = activeIndex else { return nil }
        let destination = (current + amount % tabs.count + tabs.count) % tabs.count
        return TabArrangement.movingTab(from: current, to: destination, in: tabLayouts).flatMap { adopting($0) }
    }

    // MARK: - pane

    /// 把一个不在本窗口的 pane 插到目标 pane 旁边（分屏、跨窗口移入）。
    public func insertingPane(_ pane: UUID, beside target: UUID, edge: PaneEdge) -> WindowArrangement? {
        TabArrangement.inserting(pane, beside: target, edge: edge, in: tabLayouts).flatMap { adopting($0) }
    }

    /// 把一个不在本窗口的 pane 并进指定标签页（跨窗口移入）。
    public func insertingPane(_ pane: UUID, intoTab tabID: UUID) -> WindowArrangement? {
        TabArrangement.inserting(pane, intoTab: tabID, in: tabLayouts).flatMap { adopting($0) }
    }

    /// 移除一个 pane（关闭、跨窗口移出）；标签页移空即消失。
    public func removingPane(_ pane: UUID) -> WindowArrangement? {
        TabArrangement.removing(pane, from: tabLayouts).flatMap { adopting($0) }
    }

    /// 一次移除一组 pane（关闭的统一入口）：本窗口没有的身份忽略，一个都不在时无事可做。
    /// 逐个从排布里摘、最后一次性接收，所以当前标签页的落点按移除前的位次算。
    /// 关标签页（容器行 ✕、close_tab、清空窗口）就是移除这些标签页的全部 pane。
    public func removingPanes(_ panes: Set<UUID>) -> WindowArrangement? {
        var layouts = tabLayouts
        var removed = false
        for pane in self.panes where panes.contains(pane) {
            guard let next = TabArrangement.removing(pane, from: layouts) else { continue }
            layouts = next
            removed = true
        }
        return removed ? adopting(layouts) : nil
    }

    /// 窗口内把 pane 移到另一个 pane 旁边（可跨标签页）。
    public func movingPane(_ pane: UUID, beside target: UUID, edge: PaneEdge) -> WindowArrangement? {
        TabArrangement.movingPane(pane, beside: target, edge: edge, in: tabLayouts).flatMap { adopting($0) }
    }

    /// 窗口内把 pane 并进指定标签页。它本来就独占这个标签页时无事可做。
    public func movingPane(_ pane: UUID, intoTab tabID: UUID) -> WindowArrangement? {
        TabArrangement.movingPane(pane, intoTab: tabID, in: tabLayouts).flatMap { adopting($0) }
    }

    /// 把分屏里的 pane 拆成新标签页，放在 `anchor` 之后（nil = 最前）。源标签页还有
    /// 别的 pane，所以 anchor 可以是源标签页自己。它本来就独占标签页时无事可做。
    public func detachingPane(_ pane: UUID, toNewTab id: UUID, title: TabTitle,
                              after anchor: UUID?) -> WindowArrangement? {
        let destination: Int
        if let anchor {
            guard let found = index(of: anchor) else { return nil }
            destination = found + 1
        } else {
            destination = 0
        }
        return TabArrangement.detachingPane(pane, toNewTab: id, at: destination, in: tabLayouts)
            .flatMap { adopting($0, newTitles: [id: title]) }
    }

    // MARK: - 比例与放大

    /// 只改比例的更新（拖分隔线、按键调尺寸、均分）：pane 集合与树序都不许变，放大态保留。
    public func resizingLayout(ofTab id: UUID, to layout: PaneLayout) -> WindowArrangement? {
        guard let index = index(of: id), tabs[index].layout != layout,
              tabs[index].layout.panes == layout.panes else { return nil }
        var next = self
        next.tabs[index].layout = layout
        return next
    }

    /// toggle_split_zoom：只对当前标签页里的 pane 生效，标签页只有一个 pane 时无事可做。
    public func togglingZoom(_ pane: UUID) -> WindowArrangement? {
        guard let index = activeIndex, tabs[index].layout.contains(pane),
              tabs[index].layout.panes.count > 1 else { return nil }
        var next = self
        next.tabs[index].zoomedPane = tabs[index].zoomedPane == nil ? pane : nil
        return next
    }

    // MARK: - 撤销

    /// 撤销时换回之前记下的编排。放大态不随记录回来：结构没变的标签页保留眼下的放大态，
    /// 结构变了的清掉——与普通结构命令同一条规则。焦点也取眼下的，只在那个 pane 回到记录后
    /// 仍在同一标签页时保留。当前标签页取记录里的。
    public func restoring(_ record: WindowArrangement) -> WindowArrangement {
        var result = record
        for index in result.tabs.indices {
            let current = tab(result.tabs[index].id)
            let layout = result.tabs[index].layout
            result.tabs[index].zoomedPane = current?.layout == layout ? current?.zoomedPane : nil
            result.tabs[index].focusedPane = current?.focusedPane.flatMap { layout.contains($0) ? $0 : nil }
        }
        return result
    }

    // MARK: - 快照

    /// 按标签页生成快照条目；转换不出的标签页（例如 pane 视图已经不在）跳过。
    /// 一个都没有返回 nil。当前标签页的位次夹在条目数之内。
    public func snapshot<Entry>(_ entry: (ArrangedTab) -> Entry?) -> (tabs: [Entry], activeIndex: Int)? {
        let entries = tabs.compactMap(entry)
        guard !entries.isEmpty else { return nil }
        return (entries, min(max(activeIndex ?? 0, 0), entries.count - 1))
    }

    // MARK: - 内部

    private var tabLayouts: [TabLayout] { tabs.map { TabLayout(id: $0.id, layout: $0.layout) } }

    /// 接收 `TabArrangement` 算出的新编排：身份相同的标签页沿用标题，结构变了清掉放大态，
    /// 焦点 pane 已经不在树里的清掉焦点；新身份用 `newTitles` 给的标题（给不出就是无效命令），
    /// 没有焦点记录。当前标签页按 `select`，否则留在原来那个身上，它没了就落到原位次上的邻居。
    private func adopting(_ layouts: [TabLayout], newTitles: [UUID: TabTitle] = [:],
                          select: UUID? = nil) -> WindowArrangement? {
        var result: [ArrangedTab] = []
        for entry in layouts {
            if var tab = tab(entry.id) {
                if tab.layout != entry.layout {
                    tab.layout = entry.layout
                    tab.zoomedPane = nil
                    if let focused = tab.focusedPane, !entry.layout.contains(focused) { tab.focusedPane = nil }
                }
                result.append(tab)
            } else {
                guard let title = newTitles[entry.id] else { return nil }
                result.append(ArrangedTab(id: entry.id, layout: entry.layout, title: title))
            }
        }
        let active: UUID?
        if let select, result.contains(where: { $0.id == select }) {
            active = select
        } else if let activeTabID, result.contains(where: { $0.id == activeTabID }) {
            active = activeTabID
        } else {
            active = result.isEmpty ? nil : result[min(activeIndex ?? 0, result.count - 1)].id
        }
        return WindowArrangement(tabs: result, activeTabID: active)
    }
}
