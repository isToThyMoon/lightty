import AppKit

/// 三栏浏览器：左边一棵来源树、中间一列条目、右边详情。Skills、Plugins 与 Handoff
/// 三个设置页共用这具骨架——列宽、拖动与持久化、两张表、搜索框、计数与空态都在这里。
///
/// 子类只回答四件事：导航树长什么样、当前列表是哪些条目、详情区放什么控件、怎么摆。
/// 选中项对骨架而言只是一个字符串键，含义由子类自己解释。
class ColumnBrowserView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    /// 一行导航。`key` 为 nil 表示这行不可选：分区标题，或只负责折叠的 Agent 行。
    struct NavigationItem: Equatable {
        let title: String
        var symbol: String = ""
        var key: String? = nil
        var count: Int = 0
        var depth: Int = 0
        /// 非 nil 表示这行可折叠，值是折叠状态的持久化键。
        var disclosure: String? = nil
        var note: String? = nil
        /// 版本一类的次要信息，跟在标题右边，放不下时整个让位。
        var version: String? = nil
        /// 标题的完整形态，用于 tooltip 与中栏标题。
        var qualifiedName: String? = nil
        /// 叶子行（直接指向一个条目）不显示数量。
        var showsCount: Bool = true
    }

    let localize: (String) -> String
    private let preferences: PreferenceStorage
    /// preferences 的键前缀，例如 `settings.skills`，三页各存各的列宽与折叠状态。
    private let scope: String

    private(set) var navigation: [NavigationItem] = []
    private(set) var listIDs: [String] = []
    private(set) var selectedKey: String?
    private(set) var selectedListID: String?
    private(set) var collapsedGroups: Set<String> = []
    private var updatingSelection = false
    private var preferredSidebarWidth: CGFloat?
    private var preferredListWidth: CGFloat?

    private let horizontalScroll = NSScrollView()
    private let canvas: NSView = BrowserFlippedView()
    private let sidebar = ShellBackdropView(fill: ShellStyle.browserNavigationBackground)
    private let listBackground = ShellBackdropView(fill: ShellStyle.browserListBackground)
    private let detailBackground = ShellBackdropView(fill: ShellStyle.browserDetailBackground)
    private let navigationScroll = SidebarListScrollView()
    private let listScroll = SidebarListScrollView()
    let firstDivider = SkillsColumnDivider()
    let secondDivider = SkillsColumnDivider()
    let navigationTable = NSTableView()
    let listTable = NSTableView()
    let searchField = NSSearchField()
    /// 详情栏的容器。子类把自己的控件加进来，在 `layoutDetail(in:)` 里用局部坐标摆。
    /// 它自己是翻转坐标系的，所以子类算 y 与骨架一致，从上往下。
    let detailArea: NSView = BrowserFlippedView()
    private let listHeading = ColumnBrowserView.label("", font: SkillsStyle.nameFont)
    private let countLabel = ColumnBrowserView.label("", font: SkillsStyle.summaryFont, secondary: true)
    private let emptyLabel = ColumnBrowserView.label("", font: SkillsStyle.bodyFont, secondary: true)
    private let detailEmpty = ColumnBrowserView.label("", font: SkillsStyle.bodyFont, secondary: true)
    let footerButton = ShellTextButton("", target: nil, action: nil)
    lazy var refreshButton: RefreshButton = {
        let button = RefreshButton()
        button.allowsCancel = false
        button.target = self
        button.action = #selector(reload)
        return button
    }()

    init(scope: String, preferences: PreferenceStorage, localize: @escaping (String) -> String) {
        self.scope = scope
        self.preferences = preferences
        self.localize = localize
        collapsedGroups = Set(preferences.stringArray(forKey: "\(scope).collapsedGroups") ?? [])
        let sidebarWidth = preferences.double(forKey: "\(scope).sidebarWidth")
        let listWidth = preferences.double(forKey: "\(scope).listWidth")
        preferredSidebarWidth = sidebarWidth.isFinite && sidebarWidth > 0 ? sidebarWidth : nil
        preferredListWidth = listWidth.isFinite && listWidth > 0 ? listWidth : nil
        super.init(frame: .zero)
        buildChrome()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - 子类覆写

    /// 整棵导航树，含分区标题与折叠行。
    func makeNavigation() -> [NavigationItem] { [] }
    /// 当前导航选中项与搜索词下的条目，顺序即显示顺序。
    func makeListIDs() -> [String] { [] }
    func listCell(for id: String) -> NSView? { nil }
    /// 列表里也可以有不可选的行——按类型分组时的组标题就是一行。
    func isListRowSelectable(_ id: String) -> Bool { true }
    func listRowHeight(for id: String) -> CGFloat { listRowHeight() }
    func navigationCell(for item: NavigationItem) -> NSView? {
        let trailing = item.key != nil || item.disclosure != nil ? (item.showsCount ? String(item.count) : "") : ""
        return ColumnBrowserCell(title: item.title, subtitle: item.note, symbol: item.symbol,
                                 trailing: trailing,
                                 heading: item.key == nil && item.disclosure == nil && item.note == nil,
                                 depth: item.depth, version: item.version, tooltip: item.qualifiedName,
                                 inTree: true)
    }
    /// 导航选中项变了。子类改自己的筛选态，然后调用 `reloadList()`。
    func didSelectNavigation(key: String) {}
    /// 列表选中项变了，nil 表示没有选中。子类更新详情区。
    func didSelectList(id: String?) {}
    func layoutDetail(in rect: NSRect) {}
    /// 刷新按钮按下。子类重新扫描数据，扫完调用 `reloadNavigation()`。
    func reloadData() {}
    var listHeadingText: String { "" }
    var emptyListText: String { "" }
    var detailEmptyText: String { "" }
    var searchPlaceholder: String { "" }
    var navigationAccessibilityLabel: String { "" }
    var listAccessibilityLabel: String { "" }
    /// 单篇说明直接从导航进入正文，不占用一个空列表栏。
    var showsListColumn: Bool { true }
    /// 每行的高度。默认按导航行的层级给，列表行用条目高度。
    func listRowHeight() -> CGFloat { SkillsStyle.skillRowHeight }

    // MARK: - 骨架

    private static func label(_ text: String, font: NSFont, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = secondary ? ShellStyle.secondaryText : ShellStyle.primaryText
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func buildChrome() {
        horizontalScroll.drawsBackground = false
        // This scroll view is already inside the settings page, not the window content.
        // A second titlebar/safe-area inset would expose a transparent band above it.
        horizontalScroll.automaticallyAdjustsContentInsets = false
        horizontalScroll.contentInsets = NSEdgeInsetsZero
        horizontalScroll.hasHorizontalScroller = true
        horizontalScroll.autohidesScrollers = true
        horizontalScroll.documentView = canvas
        addSubview(horizontalScroll)
        for view in [sidebar, listBackground, detailBackground, firstDivider, secondDivider,
                     navigationScroll, listScroll, listHeading, countLabel, searchField,
                     refreshButton, emptyLabel, detailArea, detailEmpty, footerButton] {
            canvas.addSubview(view)
        }
        firstDivider.onDrag = { [weak self] position in self?.resizeColumn(first: true, to: position) }
        secondDivider.onDrag = { [weak self] position in self?.resizeColumn(first: false, to: position) }
        configure(navigationTable, in: navigationScroll)
        navigationTable.target = self
        navigationTable.action = #selector(navigationClicked)
        configure(listTable, in: listScroll)
        searchField.font = SkillsStyle.bodyFont
        searchField.controlSize = .small
        searchField.delegate = self
        (searchField.cell as? NSSearchFieldCell)?.sendsSearchStringImmediately = true
        emptyLabel.alignment = .center
        detailEmpty.alignment = .center
        footerButton.isHidden = true
    }

    private func configure(_ table: NSTableView, in scroll: NSScrollView) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("content"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.focusRingType = .none
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = table
    }

    /// 文案在子类构造完成后才可用，所以由子类在 init 末尾调用一次。
    func applyChromeText() {
        searchField.placeholderString = searchPlaceholder
        searchField.setAccessibilityLabel(searchPlaceholder)
        navigationTable.setAccessibilityLabel(navigationAccessibilityLabel)
        listTable.setAccessibilityLabel(listAccessibilityLabel)
        detailEmpty.stringValue = detailEmptyText
    }

    override func layout() {
        super.layout()
        horizontalScroll.frame = bounds
        let minimumWidth = showsListColumn ? SkillsStyle.minimumWidth
            : SkillsStyle.compactSidebarWidth + SkillsStyle.minimumDetailWidth
        let width = max(minimumWidth, horizontalScroll.contentSize.width)
        let height = horizontalScroll.contentSize.height
        canvas.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let compact = width < SkillsStyle.compactBreakpoint
        let navWidth = min(max(SkillsStyle.compactSidebarWidth,
            preferredSidebarWidth ?? (compact ? SkillsStyle.compactSidebarWidth : SkillsStyle.sidebarWidth)),
            width - (showsListColumn ? SkillsStyle.compactListWidth : 0) - SkillsStyle.minimumDetailWidth)
        let listWidth = min(max(SkillsStyle.compactListWidth,
            preferredListWidth ?? (compact ? SkillsStyle.compactListWidth : SkillsStyle.listWidth)),
            max(SkillsStyle.compactListWidth, width - navWidth - SkillsStyle.minimumDetailWidth))
        let detailX = navWidth + (showsListColumn ? listWidth : 0)
        for view in [listBackground, listScroll, listHeading, countLabel, searchField,
                     refreshButton, secondDivider] {
            view.isHidden = !showsListColumn
        }
        emptyLabel.isHidden = !showsListColumn || listIDs.contains(where: isListRowSelectable)
        let inset = SkillsStyle.inset
        let top = SkillsStyle.topInset
        sidebar.frame = NSRect(x: 0, y: 0, width: navWidth, height: height)
        listBackground.frame = NSRect(x: navWidth, y: 0, width: listWidth, height: height)
        detailBackground.frame = NSRect(x: detailX, y: 0, width: width - detailX, height: height)
        firstDivider.frame = NSRect(x: navWidth - 3, y: 0, width: 7, height: height)
        secondDivider.frame = NSRect(x: detailX - 3, y: 0, width: 7, height: height)
        navigationScroll.frame = NSRect(x: 8, y: top, width: navWidth - 16, height: max(0, height - top - 44))
        footerButton.frame = NSRect(x: inset, y: max(top + 44, height - 40), width: navWidth - inset * 2, height: 28)
        listHeading.frame = NSRect(x: navWidth + inset, y: top + 6, width: listWidth - 104, height: 20)
        countLabel.frame = NSRect(x: detailX - 76, y: top + 6, width: 32, height: 18)
        countLabel.alignment = .right
        refreshButton.frame = NSRect(x: detailX - inset - 28, y: top, width: 28, height: 28)
        searchField.frame = NSRect(x: navWidth + inset, y: top + 40, width: listWidth - inset * 2, height: 28)
        listScroll.frame = NSRect(x: navWidth + 8, y: top + 80, width: listWidth - 16, height: max(0, height - top - 80))
        emptyLabel.frame = NSRect(x: navWidth + inset, y: top + 112, width: listWidth - inset * 2, height: 44)
        detailArea.frame = NSRect(x: detailX, y: 0, width: width - detailX, height: height)
        detailEmpty.frame = NSRect(x: detailX, y: height / 2, width: width - detailX, height: 24)
        layoutDetail(in: NSRect(x: 0, y: 0, width: detailArea.frame.width, height: height))
        for table in [navigationTable, listTable] {
            if let clip = table.enclosingScrollView?.contentView {
                table.setFrameSize(NSSize(width: clip.bounds.width, height: max(table.frame.height, clip.bounds.height)))
                table.sizeLastColumnToFit()
            }
        }
    }

    /// 详情栏的内边距：窄窗口下与其余两栏取齐，宽窗口下留出更多呼吸。
    var detailInset: CGFloat {
        let width = max(SkillsStyle.minimumWidth, horizontalScroll.contentSize.width)
        return width < SkillsStyle.compactBreakpoint ? SkillsStyle.inset : SkillsStyle.detailInset
    }

    private func resizeColumn(first: Bool, to position: CGFloat) {
        if !showsListColumn {
            guard first else { return }
            preferredSidebarWidth = min(max(SkillsStyle.compactSidebarWidth, position),
                                        canvas.bounds.width - SkillsStyle.minimumDetailWidth)
            preferences.set(preferredSidebarWidth, forKey: "\(scope).sidebarWidth")
            needsLayout = true
            layoutSubtreeIfNeeded()
            return
        }
        if first {
            let rightEdge = listBackground.frame.maxX
            preferredSidebarWidth = min(max(SkillsStyle.compactSidebarWidth, position),
                                        rightEdge - SkillsStyle.compactListWidth)
            preferredListWidth = rightEdge - preferredSidebarWidth!
        } else {
            preferredSidebarWidth = sidebar.frame.width
            preferredListWidth = min(max(SkillsStyle.compactListWidth, position - sidebar.frame.width),
                                     canvas.bounds.width - sidebar.frame.width - SkillsStyle.minimumDetailWidth)
        }
        preferences.set(preferredSidebarWidth, forKey: "\(scope).sidebarWidth")
        preferences.set(preferredListWidth, forKey: "\(scope).listWidth")
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    @objc func reload() { reloadData() }

    /// 重建导航树并保持选中项；键消失时交还给子类决定去处。
    func reloadNavigation() {
        navigation = makeNavigation()
        updatingSelection = true
        navigationTable.reloadData()
        if let index = navigation.firstIndex(where: { $0.key != nil && $0.key == selectedKey }) {
            navigationTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else { navigationTable.deselectAll(nil) }
        updatingSelection = false
    }

    /// 重建条目列表并保持选中项；选中项消失时落到第一条可选的行。
    func reloadList() {
        listIDs = makeListIDs()
        let selectable = listIDs.filter { isListRowSelectable($0) }
        if selectedListID == nil || !selectable.contains(selectedListID!) { selectedListID = selectable.first }
        updatingSelection = true
        listTable.reloadData()
        if let index = listIDs.firstIndex(where: { $0 == selectedListID }) {
            listTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            listTable.scrollRowToVisible(index)
        } else { listTable.deselectAll(nil) }
        updatingSelection = false
        listHeading.stringValue = listHeadingText
        listHeading.toolTip = listHeading.stringValue
        // 组标题不是条目，不进计数。
        countLabel.stringValue = String(selectable.count)
        emptyLabel.isHidden = !showsListColumn || !selectable.isEmpty
        emptyLabel.stringValue = emptyListText
        detailEmpty.stringValue = detailEmptyText
        detailEmpty.isHidden = selectedListID != nil
        didSelectList(id: selectedListID)
    }

    /// 子类切换筛选时用：设定选中键，重建两栏。
    func selectNavigation(key: String) {
        selectedKey = key
        didSelectNavigation(key: key)
        reloadNavigation()
        reloadList()
    }

    func selectList(id: String?) {
        selectedListID = id
        detailEmpty.isHidden = id != nil
        didSelectList(id: id)
    }


    /// 选中键已经失效时，子类用它换一个落点，不必自己去碰表格。
    func resetSelection(to key: String) { selectedKey = key }

    var searchQuery: String {
        searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func search(_ query: String) {
        searchField.stringValue = query
        reloadList()
    }

    func controlTextDidChange(_ notification: Notification) { reloadList() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.moveDown(_:)),
              let first = listIDs.firstIndex(where: { isListRowSelectable($0) }) else { return false }
        window?.makeFirstResponder(listTable)
        let row = listTable.selectedRow >= 0 ? listTable.selectedRow : first
        listTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return true
    }

    @objc private func navigationClicked() {
        let row = navigationTable.clickedRow
        guard navigation.indices.contains(row), let key = navigation[row].disclosure else { return }
        toggleGroup(key)
    }

    func toggleGroup(_ key: String) {
        if !collapsedGroups.insert(key).inserted { collapsedGroups.remove(key) }
        preferences.set(collapsedGroups.sorted(), forKey: "\(scope).collapsedGroups")
        reloadNavigation()
    }

    func isCollapsed(_ key: String) -> Bool { collapsedGroups.contains(key) }

    func setFooter(_ title: String, tooltip: String, target: AnyObject?, action: Selector?, hidden: Bool) {
        footerButton.label = title
        footerButton.toolTip = tooltip
        footerButton.target = target
        footerButton.action = action
        footerButton.isHidden = hidden
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === navigationTable ? navigation.count : listIDs.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard tableView === navigationTable else { return listRowHeight(for: listIDs[row]) }
        let item = navigation[row]
        if item.note != nil { return 52 }
        // 分区标题自带上方留白，领起下面一段。
        return item.key == nil && item.disclosure == nil ? 40 : SkillsStyle.navigationRowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        tableView === navigationTable ? navigation[row].key != nil : isListRowSelectable(listIDs[row])
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        // 标题行点不动，不给 hover 和手型；折叠行能点，但它有常驻的分组底色，只留手型。
        guard tableView === navigationTable else {
            return isListRowSelectable(listIDs[row]) ? ShellTableRowView() : ShellDropTargetRowView()
        }
        let item = navigation[row]
        if item.key == nil && item.disclosure == nil { return ShellDropTargetRowView() }
        let view = ShellTableRowView()
        view.drawsHover = item.disclosure == nil
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === navigationTable { return navigationCell(for: navigation[row]) }
        return listCell(for: listIDs[row])
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSelection, let table = notification.object as? NSTableView else { return }
        if table === navigationTable {
            guard navigation.indices.contains(table.selectedRow), let key = navigation[table.selectedRow].key else { return }
            selectNavigation(key: key)
        } else {
            selectList(id: listIDs.indices.contains(table.selectedRow) ? listIDs[table.selectedRow] : nil)
        }
    }
}

private final class BrowserFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One row of either table: an icon lane, a title that may carry a dimmed version,
/// an optional second line, and a right-aligned count. Every width is measured from
/// the text itself — a truncating NSTextField reports no intrinsic width.
final class ColumnBrowserCell: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let trailingLabel = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let titleFont: NSFont
    private let topSpacing: CGFloat
    private let groupSurface: Bool
    private let isHeading: Bool
    private let hasSubtitle: Bool
    private let isDisclosure: Bool
    private let depth: Int
    /// 左栏的行排在树里（缩进 + 图标槽）；中栏的条目自成一列，贴边排。
    /// 这件事由调用方说了算——靠「有没有副标题」去猜，说明行与条目行就会打架。
    private let inTree: Bool
    /// 树里图标槽的起点，缺省按 depth 推。分组嵌在上一级文字列下时由调用方给出，
    /// 分区标题的文字也从这里起。
    private let lane: CGFloat?
    /// Built once each; layout picks whichever one fits the row.
    private let plainTitle: NSAttributedString
    private let titleWithVersion: NSAttributedString?
    private var showsVersion: Bool?

    init(title: String, subtitle: String?, symbol: String, trailing: String, image: NSImage? = nil, heading: Bool = false,
         depth: Int = 0, version: String? = nil, tooltip: String? = nil, inTree: Bool = false,
         headingFont: NSFont = SkillsStyle.sectionFont, headingColor: NSColor = ShellStyle.tertiaryText, titleFont: NSFont? = nil, groupSurface: Bool = false, topSpacing: CGFloat = 0,
         lane: CGFloat? = nil) {
        self.topSpacing = topSpacing
        self.lane = lane
        self.groupSurface = groupSurface
        self.depth = depth
        self.inTree = inTree
        isHeading = heading
        hasSubtitle = subtitle != nil
        isDisclosure = symbol.hasPrefix("chevron.")
        let font = titleFont ?? (heading ? headingFont
            : (subtitle != nil && !inTree ? SkillsStyle.nameFont : SkillsStyle.bodyFont))
        let color = heading ? headingColor : ShellStyle.primaryText
        self.titleFont = font
        plainTitle = ColumnBrowserCell.title(title, font: font, color: color)
        titleWithVersion = version.flatMap { $0.isEmpty ? nil : $0 }
            .map { ColumnBrowserCell.title(title, font: font, color: color, version: $0) }
        super.init(frame: .zero)
        titleLabel.attributedStringValue = plainTitle
        subtitleLabel.stringValue = subtitle ?? ""
        subtitleLabel.font = SkillsStyle.summaryFont
        subtitleLabel.textColor = ShellStyle.secondaryText
        subtitleLabel.isHidden = !hasSubtitle
        trailingLabel.stringValue = trailing
        trailingLabel.font = SkillsStyle.summaryFont
        trailingLabel.textColor = ShellStyle.tertiaryText
        trailingLabel.alignment = .right
        icon.image = image ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(isDisclosure
                ? .init(pointSize: ShellStyle.compactIconSize, weight: .medium)
                : .init(pointSize: 13, weight: .regular))
        icon.contentTintColor = image?.isTemplate == false ? nil : ShellStyle.secondaryText
        for label in [titleLabel, subtitleLabel, trailingLabel] {
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        addSubview(icon)
        icon.imageScaling = .scaleProportionallyDown
        toolTip = [tooltip ?? title, version, subtitle].compactMap { $0 }.joined(separator: "\n")
        setAccessibilityElement(true)
        setAccessibilityLabel(toolTip)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var backgroundStyle: NSView.BackgroundStyle { get { .normal } set {} }

    private var contentBounds: NSRect {
        NSRect(x: 0, y: topSpacing, width: bounds.width, height: max(0, bounds.height - topSpacing))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard groupSurface else { return }
        ShellStyle.navigationGroupFill.setFill()
        // 横向与行视图的选中、hover 底色同宽（它们内缩 2pt），上下两边对齐成一列。
        NSBezierPath(roundedRect: contentBounds.insetBy(dx: 2, dy: 4),
                     xRadius: ShellStyle.rowCornerRadius, yRadius: ShellStyle.rowCornerRadius).fill()
    }


    private static func title(_ text: String, font: NSFont, color: NSColor,
                              version: String? = nil) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ])
        if let version {
            result.append(NSAttributedString(string: "  " + version, attributes: [
                .font: SkillsStyle.captionFont, .foregroundColor: ShellStyle.tertiaryText,
                .paragraphStyle: paragraph,
            ]))
        }
        return result
    }

    private static func width(_ text: NSAttributedString) -> CGFloat {
        text.length == 0 ? 0 : ceil(text.size().width)
    }

    /// 树里行的文字起点。行外挂的说明（不走这个 cell 的）也从这里起，才与标题同列。
    static func treeTextLeft(depth: Int = 0) -> CGFloat { 8 + CGFloat(depth) * 16 + 16 + 8 }

    override func layout() {
        super.layout()
        let inset: CGFloat = 8
        // 一级缩进 16pt，图标与折叠箭头共用同一条 16pt 的槽，槽后留 8pt。一条规则
        // 管到底：每深一级就右移一格，同级的文字永远落在同一列，有没有图标都一样。
        // 分区标题与中栏条目贴边，它们不在这棵树里。
        let indent = CGFloat(depth) * 16
        let iconWidth: CGFloat = 16
        // 分区标题贴边领起一段，中栏条目不在树里，其余都占缩进与图标槽。
        let laneLeft = lane ?? inset + indent
        let textLeft: CGFloat = !inTree ? inset : isHeading ? (lane ?? inset) : laneLeft + iconWidth + 8
        let countWidth = trailingLabel.stringValue.isEmpty ? 0
            : max(16, ColumnBrowserCell.width(trailingLabel.attributedStringValue) + 4)
        let titleWidth = max(0, bounds.width - textLeft - inset - countWidth)
        // 单行按大写字高居中：标签的字贴着框顶，框居中时字会比底框中线高一点五个点。
        let y: CGFloat = hasSubtitle ? (inTree ? 7 : 12)
            : contentBounds.midY - (titleFont.ascender - titleFont.capHeight / 2)
        // The version rides along only when the pair fits whole: half a version reads
        // as noise next to a clipped name, and the tooltip carries it either way.
        let fits = titleWithVersion.map { ColumnBrowserCell.width($0) <= titleWidth } ?? false
        if showsVersion != fits {
            showsVersion = fits
            titleLabel.attributedStringValue = fits ? titleWithVersion! : plainTitle
        }
        titleLabel.frame = NSRect(x: textLeft, y: y, width: titleWidth, height: 18)
        subtitleLabel.frame = NSRect(x: textLeft, y: inTree ? 29 : 34,
                                     width: max(0, bounds.width - textLeft - inset), height: 18)
        // 标签把字排在框顶，字号不同的两段文字框顶对齐，基线就错开；数量按标题的基线放。
        let trailingFont = trailingLabel.font ?? titleFont
        trailingLabel.frame = NSRect(x: bounds.width - inset - countWidth,
                                     y: y + titleFont.ascender - trailingFont.ascender,
                                     width: countWidth, height: 18)
        // 两行的条目图标照旧居中领起整块；单行跟着标题那一行走。
        let iconY = hasSubtitle ? contentBounds.midY - 8
            : ColumnBrowserCell.iconTop(icon.image, lane: 16, textTop: y, font: titleFont)
        // 箭头比内容图标窄得多，居中在槽里离文字就远了；按固定中心贴近文字摆，
        // 展开与收起两个朝向共用这个中心，切换时不左右跳。
        let iconX = isDisclosure ? textLeft - 9 - iconWidth / 2 : laneLeft
        icon.frame = NSRect(x: iconX, y: iconY, width: iconWidth, height: 16)
    }

    /// 标签的字贴着框顶排，大写字母的中心比框中心高一点五个点左右，按框居中的图标
    /// 就显得往下坠。SF Symbol 的 alignmentRect 正是按大写字高给的，把它的中心对到
    /// 标题的大写字高中心上，箭头与拼图这类高矮不一的符号也落在同一条线上。
    private static func iconTop(_ image: NSImage?, lane: CGFloat, textTop: CGFloat, font: NSFont) -> CGFloat {
        let capCenter = textTop + font.ascender - font.capHeight / 2
        guard let image, image.size.width > 0, image.size.height > 0 else { return capCenter - lane / 2 }
        // NSImageView 等比缩小后居中；alignmentRect 在图像里是自下而上的。
        let scale = min(1, lane / image.size.width, lane / image.size.height)
        let alignmentCenter = (lane - image.size.height * scale) / 2
            + (image.size.height - image.alignmentRect.midY) * scale
        return capCenter - alignmentCenter
    }
}
