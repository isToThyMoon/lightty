import AppKit
import LighttyCore

final class SessionsSidebarContent: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    /// internal 而非 private：`SidebarState` 带着它，而渲染状态是这个模块对测试的
    /// 断言面——测试断言值，不必遍历视图树反推显示了什么。
    enum Row: Equatable {
        case projectsHeading, project(SessionProject), heading, emptyProjects, session(AgentSession, UUID?)
        enum ID: Hashable { case projects, project(UUID), recent, empty, session(AgentSessionKey) }
        var id: ID {
            switch self {
            case .projectsHeading: return .projects
            case .project(let project): return .project(project.id)
            case .heading: return .recent
            case .emptyProjects: return .empty
            case .session(let record, _): return .session(record.key)
            }
        }
    }
    private let library: SessionLibrary
    private let searchMode: Bool
    var onRequestDismiss: (() -> Void)?
    private var projectsCollapsed = false
    private let search = NSTextField()
    private var agentFilter = 0
    private var showingArchived = false
    private let status = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let scroll = SidebarListScrollView()
    private var rows: [Row] = []
    private let newProject = NSButton(title: L("New project…"), target: nil, action: nil)
    private let more = NSButton(title: L("Load more sessions"), target: nil, action: nil)
    private let management = NSButton()
    /// 刷新/取消同一个按钮：它们是同一件事的两个状态，摆两个按钮会有一个永远是灰的。
    private let refresh = RefreshButton()
    private let projectMore = NSButton()
    private let projectHeading = SidebarDisclosureButton(title: L("Projects"))
    private let refreshProgress = NSProgressIndicator()
    private let recentHeading = NSTextField(labelWithString: L("Recent sessions"))
    private let recentHeader = NSView()
    private let projectHeader = NSView()
    private static let sessionPasteboardType = NSPasteboard.PasteboardType("app.lightty.session-reference")
    private var sortByTitle = false
    private var moreHeight: NSLayoutConstraint!
    private var renderedProjectNames: [UUID: String] = [:]
    private let relativeDateFormatter = RelativeDateTimeFormatter()
    private var sectionDisclosureRequested = false
    private var synchronizingSelection = false

    init(library: SessionLibrary, searchMode: Bool = false) {
        self.library = library
        self.searchMode = searchMode
        super.init(frame: .zero)
        search.placeholderString = L("Search sessions…")
        search.delegate = self
        SearchPaletteStyle.configure(search)
        newProject.target = self; newProject.action = #selector(createProject)
        more.target = self; more.action = #selector(loadMore)
        status.font = .systemFont(ofSize: 10.5)
        status.textColor = ShellStyle.secondaryText
        status.isSelectable = false
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        projectHeading.font = .systemFont(ofSize: 12, weight: .medium)
        projectHeading.contentTintColor = ShellStyle.primaryText
        projectHeading.isBordered = false
        projectHeading.imagePosition = .imageTrailing
        projectHeading.target = self
        projectHeading.action = #selector(toggleProjects)
        recentHeading.font = .systemFont(ofSize: 12, weight: .medium)
        recentHeading.textColor = ShellStyle.primaryText
        newProject.title = ""
        newProject.image = NSImage(systemSymbolName: "plus", accessibilityDescription: L("New project…"))
        newProject.toolTip = L("New project…")
        newProject.setAccessibilityLabel(L("New project…"))
        management.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: L("Filter sessions"))
        management.toolTip = L("Filter sessions")
        management.setAccessibilityLabel(L("Filter sessions"))
        management.target = self; management.action = #selector(showManagement)
        refresh.target = self; refresh.action = #selector(refreshOrCancel)
        projectMore.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: L("Project actions"))
        projectMore.setAccessibilityLabel(L("Project actions"))
        projectMore.isEnabled = false
        for button in [management, newProject, projectMore, refresh] {
            button.isBordered = false
            button.contentTintColor = ShellStyle.secondaryText
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        let actions = NSStackView(views: [projectHeading, NSView(), projectMore, newProject])
        actions.spacing = 6
        actions.translatesAutoresizingMaskIntoConstraints = false
        projectHeader.addSubview(actions)
        NSLayoutConstraint.activate([
            actions.leadingAnchor.constraint(equalTo: projectHeader.leadingAnchor, constant: 10),
            actions.trailingAnchor.constraint(equalTo: projectHeader.trailingAnchor, constant: -4),
            actions.centerYAnchor.constraint(equalTo: projectHeader.centerYAnchor),
        ])
        refreshProgress.style = .spinning
        refreshProgress.controlSize = .small
        refreshProgress.isDisplayedWhenStopped = false
        refreshProgress.setAccessibilityLabel(L("Loading local sessions…"))
        refreshProgress.widthAnchor.constraint(equalToConstant: 14).isActive = true
        refreshProgress.heightAnchor.constraint(equalToConstant: 14).isActive = true
        // 标题行不放转圈：刷新按钮自己就表达了「在读」（变成取消），两个一起是重复的。
        // 转圈只留给搜索面板——那边没有刷新按钮，需要另一个东西说明在读。
        //
        // 搜索面板里这一行其实根本不显示：那边 `rows` 只有会话，没有标题行，
        // `recentHeader` 永远不会被表格取走（见 `makeState()` 里 `searchMode` 那一支）。
        // 这个分支是既有代码留下的，不在这次的范围里，但别再往它里面加东西。
        let recentActions = NSStackView(views: searchMode ? [recentHeading, NSView(), management]
                                                       : [recentHeading, NSView(), refresh, management])
        recentActions.spacing = 6
        recentActions.alignment = .centerY
        recentActions.detachesHiddenViews = false
        recentActions.translatesAutoresizingMaskIntoConstraints = false
        recentHeader.addSubview(recentActions)
        NSLayoutConstraint.activate([
            recentActions.leadingAnchor.constraint(equalTo: recentHeader.leadingAnchor, constant: 10),
            recentActions.trailingAnchor.constraint(equalTo: recentHeader.trailingAnchor, constant: -4),
            recentActions.centerYAnchor.constraint(equalTo: recentHeader.centerYAnchor),
        ])
        let column = NSTableColumn(identifier: .init("session"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self; table.delegate = self
        table.target = self; table.action = #selector(activateRow)
        table.intercellSpacing = NSSize(width: 0, height: searchMode ? ShellStyle.paletteRowGap : 2)
        table.setAccessibilityLabel(L("CLI sessions"))
        table.registerForDraggedTypes([Self.sessionPasteboardType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        scroll.documentView = table
        let searchRow = NSStackView(views: searchMode ? [SearchPaletteStyle.icon(), search, refreshProgress] : [])
        searchRow.spacing = 10
        searchRow.alignment = .centerY
        searchRow.detachesHiddenViews = false
        for view in [searchRow, status, scroll, more] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: searchMode ? (view === scroll ? 10 : 18) : 12),
                view.trailingAnchor.constraint(equalTo: trailingAnchor,
                    constant: searchMode ? (view === scroll ? -10 : -18) : (view === scroll ? -SidebarListScrollView.trailingMargin : -12)),
            ])
        }
        NSLayoutConstraint.activate([
            searchRow.topAnchor.constraint(equalTo: topAnchor),
            scroll.topAnchor.constraint(equalTo: searchMode ? searchRow.bottomAnchor : topAnchor,
                constant: searchMode ? 14 : 0),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -4),
            status.heightAnchor.constraint(equalToConstant: 16),
            status.bottomAnchor.constraint(equalTo: more.topAnchor, constant: -4),
            more.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        if !searchMode { searchRow.heightAnchor.constraint(equalToConstant: 0).isActive = true }
        moreHeight = more.heightAnchor.constraint(equalToConstant: 0)
        NotificationCenter.default.addObserver(self, selector: #selector(libraryDidChange(_:)), name: .lighttySessionLibraryDidChange, object: library)
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncTerminalSelection()
    }

    @objc private func syncTerminalSelection() {
        guard !searchMode, !synchronizingSelection else { return }
        synchronizingSelection = true
        defer { synchronizingSelection = false }
        let activeKey = (window?.windowController as? TerminalWindowController)
            .flatMap { library.selectedSession(in: $0.sessionWindowID) }
        let index = activeKey.flatMap { key in rows.firstIndex { $0.id == .session(key) } }
        if let index {
            if table.selectedRow != index { table.selectRowIndexes([index], byExtendingSelection: false) }
        } else if table.selectedRow != -1 { table.deselectAll(nil) }
    }

    private func refreshSessionPresence(_ keys: Set<AgentSessionKey>) {
        guard !searchMode, !keys.isEmpty else { return }
        // Update only materialized cells; no catalog query, reloadData, scrolling or layout rebuild.
        table.enumerateAvailableRowViews { _, row in
            guard self.rows.indices.contains(row), case .session(let session, _) = self.rows[row],
                  keys.contains(session.key),
                  let cell = self.table.view(atColumn: 0, row: row, makeIfNecessary: false) as? SessionListCell else { return }
            self.configure(cell, for: self.rows[row])
        }
    }
    /// Presentation consumes current state. Refresh is an explicit user action or model policy.
    func activate() { reload() }
    func focusSearch() { window?.makeFirstResponder(search) }
    @objc func toggleProjects() {
        projectsCollapsed.toggle()
        projectHeading.setExpanded(!projectsCollapsed, animated: window != nil)
        sectionDisclosureRequested = true
        defer { sectionDisclosureRequested = false }
        reload()
    }
    @objc private func refreshCatalog() { library.refresh() }
    @objc private func refreshOrCancel() {
        // 不在这里改按钮：读取状态的每一次变化都会广播一条会话库通知，`reload()` 接得住。
        if library.loading { library.cancelLoading() } else { refreshCatalog() }
    }

    /// 第一侧栏在表格之外呈现的**全部**东西，算成一个可比较的值。
    ///
    /// `SessionChange` 已合并并区分目录与运行态更新；目录分页仍可能分多次完成。
    /// `makeState()` 只算不写，`render(_:)` 比较后才更新视图，保持现有单元格及编辑状态。
    /// 相同图片使用缓存对象，避免反复创建 NSImage 引起 AppKit display/layout 循环。
    /// 新的目录显示项放进这个结构；选中和已打开状态由 `syncTerminalSelection()` 单独更新。
    struct SidebarState: Equatable {
        var rows: [Row]
        /// 会话行显示的位置串要用项目名，而 `Row.session` 只带项目的 UUID。
        /// 放进状态里，改名就能被整体比较发现，不必再留一个额外的旗标。
        var projectNames: [UUID: String]
        /// 相对时间的语种。变了同样要让所有单元格重排一次。
        var language: String
        var messages: [String]
        var showMore: Bool
        var canLoadMore: Bool
        var projectTitle: String
        var recentTitle: String
        var filterActive: Bool
        var loading: Bool
        var canCreateProject: Bool
    }
    private var renderedState: SidebarState?

    /// 唯一写视图的地方。每一处写入都先比较，因为调用它的频率不由这里决定。
    private func render(_ state: SidebarState) {
        let previous = renderedState
        guard previous != state else { return }
        renderedState = state

        if previous?.language != state.language {
            let language = LanguagePreference.current()
            relativeDateFormatter.locale = language == .system ? .current : Locale(identifier: language.rawValue)
            relativeDateFormatter.unitsStyle = .short
        }
        // 表格：行的增删由稳定标识差异驱动；项目名或语种变了要让已建单元格重排一遍，
        // 因为这两样都参与单元格内容却不在 `Row` 里。
        if previous?.rows != state.rows || previous?.projectNames != state.projectNames
            || previous?.language != state.language {
            let selectedID = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
            let oldRows = rows
            rows = state.rows
            renderedProjectNames = state.projectNames
            updateRows(from: oldRows,
                       contentInvalidated: previous?.projectNames != state.projectNames
                           || previous?.language != state.language)
            if searchMode, let selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }) {
                table.selectRowIndexes([index], byExtendingSelection: false)
            }
        }
        if previous?.messages != state.messages {
            status.stringValue = state.messages.joined(separator: " · ")
            status.toolTip = state.messages.isEmpty ? nil : state.messages.joined(separator: "\n")
            status.setAccessibilityValue(state.messages.joined(separator: "\n"))
            status.isHidden = state.messages.isEmpty
        }
        if previous?.showMore != state.showMore {
            moreHeight.isActive = !state.showMore
            more.isHidden = !state.showMore
        }
        if previous?.canLoadMore != state.canLoadMore { more.isEnabled = state.canLoadMore }
        if previous?.projectTitle != state.projectTitle { projectHeading.title = state.projectTitle }
        if previous?.recentTitle != state.recentTitle { recentHeading.stringValue = state.recentTitle }
        if previous?.filterActive != state.filterActive {
            management.contentTintColor = state.filterActive ? ShellStyle.accent : ShellStyle.secondaryText
        }
        if previous?.canCreateProject != state.canCreateProject { newProject.isEnabled = state.canCreateProject }
        if previous?.loading != state.loading {
            // 转圈只在搜索面板里有父视图；侧栏那边它不参与布局，这两行是空转。
            refreshProgress.isHidden = !state.loading
            if state.loading { refreshProgress.startAnimation(nil) } else { refreshProgress.stopAnimation(nil) }
            refresh.isRefreshing = state.loading
        }
        syncTerminalSelection()
    }

    @objc private func loadMore() { library.loadMore() }
    func setArchiveFilter(_ enabled: Bool) {
        showingArchived = enabled
        reload()
    }
    @objc private func showManagement() {
        ShellMenuPopover.present(from: management, items: managementItems())
    }

    /// 筛选浮层的内容。这个浮层里每一条都是「筛选 / 排序 / 打开哪个选择器」——
    /// 同一件事的几种选择，所以只用分组标题分段，不画线；也不放当场执行的动作
    /// （刷新在标题行上的按钮里）。
    func managementItems() -> [ShellMenuPopover.Item] {
        var items: [ShellMenuPopover.Item] = [.header(L("Filter sessions"))]
        for (index, title) in [L("All agents"), "Codex CLI", "Claude Code"].enumerated() {
            items.append(.action(title, checked: agentFilter == index) { [weak self] in
                self?.agentFilter = index; self?.reload()
            })
        }
        items += [
            .action(L("Archived"), checked: showingArchived) { [weak self] in
                guard let self else { return }; self.setArchiveFilter(!self.showingArchived)
            },
            .header(L("Sort sessions")),
            .action(L("Recently updated"), checked: !sortByTitle) { [weak self] in self?.sortByTitle = false; self?.reload() },
            .action(L("Name"), checked: sortByTitle) { [weak self] in self?.sortByTitle = true; self?.reload() },
            .header(L("Native resume picker…"))]
        for agent in SessionAgent.allCases {
            guard let source = library.source(for: agent) else { continue }
            items.append(.action(agent == .codex ? "Codex CLI" : "Claude Code") { [weak self] in
                guard let controller = self?.window?.windowController as? TerminalWindowController else { return }
                SessionResumeFlow.nativePicker(source: source, in: controller)
            })
        }
        return items
    }
    func controlTextDidChange(_ obj: Notification) { reload() }

    /// 目录通知合并重算；用户筛选、搜索仍同步响应。运行态只更新选择和已打开标记。
    private lazy var libraryChanges = Coalescer(.nextTick) { [weak self] in self?.reload() }
    @objc private func libraryDidChange(_ notification: Notification) {
        guard let change = SessionChange.from(notification) else { return }
        refreshSessionPresence(change.sessions)
        if change.catalog { libraryChanges.schedule() }
        else { syncTerminalSelection() }
    }

    @objc private func reload() { render(makeState()) }

    /// 只算不写。这里出现任何一次视图写入，`render` 的整体早退就白做了。
    func makeState() -> SidebarState {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let organization = library.organization
        let projectNames = Dictionary(uniqueKeysWithValues: organization.projects.map { ($0.id, $0.name) })
        // Match the model's first-assignment semantics without rescanning assignments per session.
        var assignedProjects: [AgentSessionKey: UUID] = [:]
        var seenAssignments = Set<AgentSessionKey>()
        for assignment in organization.assignments where seenAssignments.insert(assignment.session).inserted {
            if let id = assignment.projectID, projectNames[id] != nil { assignedProjects[assignment.session] = id }
        }
        let filtered = library.records.filter { record in
            let providerMatches = agentFilter == 0
                || (agentFilter == 1 ? record.key.agent == .codex : record.key.agent == .claude)
            let projectID = assignedProjects[record.key]
            let projectName = projectID.flatMap { projectNames[$0] } ?? ""
            let archived = organization.archivedSessions.contains(record.key)
                || projectID.map { organization.archivedProjects.contains($0) } == true
            return providerMatches && (searchMode || archived == showingArchived)
                && (query.isEmpty || [record.title, record.workingDirectory ?? "", record.key.agent == .codex ? "Codex CLI" : "Claude Code", projectName]
                    .contains { $0.localizedCaseInsensitiveContains(query) })
        }.sorted {
            if sortByTitle, $0.title != $1.title { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            if $0.updatedAt != $1.updatedAt { return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            return $0.key.nativeID < $1.key.nativeID
        }
        let grouped = filtered.map { ($0, assignedProjects[$0.key]) }
        let membersByProject = Dictionary(grouping: grouped, by: { $0.1 })
        var rows: [Row] = [.projectsHeading]
        if !searchMode {
            let visibleProjects = organization.projects.filter { showingArchived ? organization.archivedProjects.contains($0.id) : !organization.archivedProjects.contains($0.id) }
            if !projectsCollapsed && visibleProjects.isEmpty && grouped.allSatisfy({ $0.1 == nil }) { rows.append(.emptyProjects) }
            for project in organization.projects where !projectsCollapsed {
                let members = membersByProject[project.id] ?? []
                if showingArchived {
                    guard organization.archivedProjects.contains(project.id) || !members.isEmpty else { continue }
                } else if organization.archivedProjects.contains(project.id) { continue }
                rows.append(.project(project))
                if !project.collapsed {
                    rows += members.map { .session($0.0, $0.1) }
                }
            }
            rows.append(.heading)
            rows += (membersByProject[nil] ?? []).map { .session($0.0, nil) }
        } else { rows = grouped.map { .session($0.0, $0.1) } }
        var messages: [String] = []
        if !library.loading && filtered.isEmpty { messages.append(L("No matching sessions.")) }
        if library.hasMore() {
            messages.append(L("More sessions are available. Search covers loaded sessions."))
        }
        if showingArchived {
            messages.append(L("Archived in lightty only. Original Agent sessions are unchanged."))
        }
        for agent in SessionAgent.allCases {
            if let error = library.errors[agent] { messages.append("\(agent == .codex ? "Codex CLI" : "Claude Code"): \(error)") }
        }
        if let error = library.storageError { messages.append(error) }
        return SidebarState(
            rows: rows,
            projectNames: projectNames,
            language: LanguagePreference.current().rawValue,
            messages: messages,
            showMore: library.hasMore(),
            canLoadMore: !library.loading && library.hasMore(),
            projectTitle: showingArchived ? L("Archived") : L("Projects"),
            recentTitle: showingArchived ? L("Other archived sessions") : L("Recent sessions"),
            filterActive: agentFilter != 0 || showingArchived,
            loading: library.loading,
            canCreateProject: library.organizationReady && !library.saving && library.storageError == nil)
    }

    /// Stable identities preserve cells, hover and tracking areas across local organization edits.
    private func updateRows(from previous: [Row], contentInvalidated: Bool) {
        let oldByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let projectDisclosure = rows.contains { row in
            guard case .project(let project) = row,
                  case .project(let old)? = oldByID[row.id] else { return false }
            return old.collapsed != project.collapsed
        }
        let difference = rows.map(\.id).difference(from: previous.map(\.id))
        var removed = IndexSet(), inserted = IndexSet()
        for change in difference {
            switch change {
            case .remove(let index, _, _): removed.insert(index)
            case .insert(let index, _, _): inserted.insert(index)
            }
        }
        if !difference.isEmpty {
            let animate = (sectionDisclosureRequested || projectDisclosure)
                && window != nil && !previous.isEmpty && !searchMode
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animate ? ShellStyle.animationDuration : 0
                context.timingFunction = ShellStyle.easeInOutCubic
                table.beginUpdates()
                table.removeRows(at: removed, withAnimation: animate ? [.effectFade, .slideUp] : [])
                table.insertRows(at: inserted, withAnimation: animate ? [.effectFade, .slideDown] : [])
                table.endUpdates()
            }
        }
        for (index, row) in rows.enumerated() where !inserted.contains(index) && (oldByID[row.id] != row || contentInvalidated) {
            if searchMode {
                // Search uses read-only PaletteRowView, not SessionListCell. Refresh just this
                // result through AppKit, retaining the table's selection and scroll position.
                table.reloadData(forRowIndexes: [index], columnIndexes: [0])
            } else if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? SessionListCell {
                configure(cell, for: row)
            }
            // Moving a session into/out of a project changes its indentation and height.
            if case .session = row, oldByID[row.id] != row { table.noteHeightOfRows(withIndexesChanged: [index]) }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard rows.indices.contains(row), case .session(let record, _) = rows[row],
              let data = try? JSONEncoder().encode(record.key) else { return nil }
        let item = NSPasteboardItem()
        item.setData(data, forType: Self.sessionPasteboardType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard (info.draggingSource as? NSTableView) === table,
              let data = info.draggingPasteboard.data(forType: Self.sessionPasteboardType),
              let target = sessionDropTarget(data, at: row) else { return [] }
        tableView.setDropRow(target.row, dropOperation: .on)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard (info.draggingSource as? NSTableView) === table, dropOperation == .on,
              let data = info.draggingPasteboard.data(forType: Self.sessionPasteboardType) else { return false }
        return acceptSessionDrop(data, at: row)
    }

    /// Shared validation for AppKit's preview and commit; never trusts pasteboard metadata.
    private func sessionDropTarget(_ data: Data, at row: Int) -> (record: AgentSession, projectID: UUID?, row: Int)? {
        guard !searchMode, library.organizationReady, !library.saving, library.storageError == nil,
              (0...rows.count).contains(row), data.count <= 8192,
              let key = try? JSONDecoder().decode(AgentSessionKey.self, from: data),
              let record = library.records.first(where: { $0.key == key }) else { return nil }
        let projectID: UUID?
        let targetRow: Int
        switch row < rows.count ? rows[row] : nil {
        case .project(let project):
            guard !library.organization.archivedProjects.contains(project.id) else { return nil }
            projectID = project.id
            targetRow = row
        case .heading, .session(_, nil), nil:
            // Recent rows and the empty tail share one grouping destination, not a sort position.
            guard let heading = rows.firstIndex(where: { $0.id == .recent }) else { return nil }
            projectID = nil
            targetRow = heading
        default:
            return nil
        }
        guard library.organization.projectID(for: record) != projectID else { return nil }
        return (record, projectID, targetRow)
    }

    @discardableResult
    func acceptSessionDrop(_ data: Data, at row: Int) -> Bool {
        guard let (record, projectID, _) = sessionDropTarget(data, at: row) else { return false }
        library.updateOrganization { state in
            state.move(record, to: projectID)
            if let index = state.projects.firstIndex(where: { $0.id == projectID }) {
                state.projects[index].collapsed = false
            }
        }
        return true
    }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .session(_, let projectID) = rows[row] {
            if searchMode { return 48 }
            return projectID != nil && !searchMode ? 48 : 64
        }
        return 32
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch rows[row] { case .projectsHeading, .project, .heading, .emptyProjects: return false; case .session: return true }
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if searchMode {
            let view = NSTableRowView()
            view.selectionHighlightStyle = .none
            return view
        }
        switch rows[row] {
        case .heading: return reusableRowView(in: tableView, id: "shell-drop-row") { ShellDropTargetRowView() }
        case .projectsHeading, .emptyProjects: return NSTableRowView()
        default: return reusableRowView(in: tableView, id: "shell-row") { ShellTableRowView() }
        }
    }
    /// row view 与 cell 一样走 `makeView` 复用：每行新建会带上 tracking area、
    /// 光标安装和 layer，滚动起手一次建十几行时这是可观的一笔。
    private func reusableRowView<T: NSTableRowView>(
        in tableView: NSTableView, id: String, make: () -> T
    ) -> T {
        let identifier = NSUserInterfaceItemIdentifier(id)
        if let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? T { return view }
        let view = make()
        view.identifier = identifier
        return view
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if searchMode, case .session(let record, _) = rows[row] {
            let agent = record.key.agent == .codex ? "Codex CLI" : "Claude Code"
            let date = record.updatedAt.map { relativeDateFormatter.localizedString(for: $0, relativeTo: Date()) } ?? ""
            let snippet = NSAttributedString(string: [date, record.workingDirectory ?? ""].filter { !$0.isEmpty }.joined(separator: " · "),
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: ShellStyle.secondaryText])
            let result = PaletteRowView(name: record.title.isEmpty ? L("Untitled session") : record.title,
                tag: agent, tagColor: ShellStyle.tertiaryText, snippet: snippet)
            result.onTap = { [weak self] in self?.open(record) }
            result.onDoubleTap = result.onTap
            result.isSelected = tableView.selectedRow == row
            return result
        }
        if case .projectsHeading = rows[row] { return projectHeader }
        if case .heading = rows[row] { return recentHeader }
        let identifier = NSUserInterfaceItemIdentifier("session-list-cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? SessionListCell ?? SessionListCell()
        cell.identifier = identifier
        configure(cell, for: rows[row])
        return cell
    }
    /// 选中改回「当前聚焦终端那一行」这件事，**必须挪到下一拍**。
    ///
    /// 用户点一行时，AppKit 在 `NSTableView.mouseDown:` 里先选中被点的行，
    /// 发出这条通知，**然后才**调 `scrollRowToVisible:`——用的是那一刻的选中行。
    /// 如果我们在通知里同步把选中改成上面某一行，AppKit 接着就会把列表滚上去：
    /// 点底部一条会话开终端，列表整个弹回顶部（实测调用栈确认过）。
    ///
    /// 挪到下一拍之后，`mouseDown` 结束时选中的还是被点那一行（本来就可见，不滚动），
    /// 同步紧接着发生——而单纯的 `selectRowIndexes` 自己是不滚动的。
    private lazy var selectionSyncs = Coalescer(.nextTick) { [weak self] in self?.syncTerminalSelection() }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard searchMode else {
            // Non-session rows may be selected programmatically to dispatch their action.
            if rows.indices.contains(table.selectedRow), case .session = rows[table.selectedRow] {
                selectionSyncs.schedule()
            }
            return
        }
        table.enumerateAvailableRowViews { rowView, row in
            (rowView.view(atColumn: 0) as? PaletteRowView)?.isSelected = row == self.table.selectedRow
        }
    }
    /// 测试接缝：一行的显示内容纯粹由那条会话算出来。返回第二行的文字，
    /// 不必先把整个表格和窗口搭起来。单元格类型是文件私有的，所以不出现在签名里。
    func detailTextForTesting(_ session: AgentSession) -> String {
        let cell = SessionListCell()
        configure(cell, for: .session(session, nil))
        return cell.detail.stringValue
    }

    private func configure(_ cell: SessionListCell, for row: Row) {
        cell.resetContent()
        switch row {
        case .projectsHeading: break
        case .emptyProjects:
            cell.title.stringValue = L("No projects")
            cell.title.font = .systemFont(ofSize: 11, weight: .regular)
            cell.title.textColor = ShellStyle.secondaryText
            cell.indent = 20
            cell.menuButton.isHidden = true
        case .heading:
            cell.title.stringValue = showingArchived ? L("Other archived sessions") : L("Recent sessions")
            cell.title.font = .systemFont(ofSize: 12, weight: .medium)
            cell.title.textColor = ShellStyle.primaryText
            cell.menuButton.isHidden = true
        case .project(let project):
            cell.title.stringValue = project.name
            cell.indent = 34
            cell.projectIcon.isHidden = false
            cell.projectIcon.image = ProjectFolderIcons.image(expanded: !project.collapsed)
            cell.projectIcon.setAccessibilityLabel(project.collapsed ? L("Collapsed") : L("Expanded"))
            cell.title.font = .systemFont(ofSize: 12, weight: .semibold)
            cell.onMenu = { [weak self, weak cell] in if let cell { self?.projectMenu(project, from: cell.menuButton) } }
        case .session(let record, let projectID):
            cell.indent = projectID == nil ? 10 : 24
            cell.title.stringValue = record.title.isEmpty ? L("Untitled session") + " · " + String(record.key.nativeID.prefix(8)) : record.title
            let date = record.updatedAt.map { relativeDateFormatter.localizedString(for: $0, relativeTo: Date()) } ?? ""
            let location = projectID.flatMap { renderedProjectNames[$0] }
                ?? record.workingDirectory ?? ""
            cell.setAgent(record.key.agent)
            // 「在别处开着」要在点下去之前就说清楚，否则用户点了才撞上那个提示框。
            // lightty 自己开着优先——那时它在不在别处跑已经不重要了。
            let openness: String
            switch library.presence(for: record.key) {
            case .inLightty: openness = L("Open in lightty")
            case .elsewhere: openness = L("Open in another terminal")
            case .unknown: openness = ""
            }
            cell.detail.stringValue = [date, openness]
                .filter { !$0.isEmpty }.joined(separator: " · ")
            cell.location.stringValue = location.hasPrefix("/") ? URL(fileURLWithPath: location).lastPathComponent : location
            if projectID != nil && !searchMode {
                cell.location.stringValue = ""
            }
            cell.location.fullText = record.workingDirectory ?? location
            cell.onMenu = { [weak self, weak cell] in if let cell { self?.sessionMenu(record, from: cell.menuButton) } }
        }
    }
    @objc private func activateRow() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard rows.indices.contains(row) else { return }
        switch rows[row] {
        case .project(let project):
            table.deselectRow(row)
            library.updateOrganization { state in
                if let index = state.projects.firstIndex(where: { $0.id == project.id }) { state.projects[index].collapsed.toggle() }
            }
        case .session(let record, _): open(record)
        case .projectsHeading, .heading, .emptyProjects: break
        }
    }
    private func open(_ record: AgentSession, destination: TerminalLaunchDestination = .tab) {
        guard let controller = window?.windowController as? TerminalWindowController,
              let source = library.source(for: record.key.agent) else { return }
        onRequestDismiss?()
        SessionResumeFlow.open(record, source: source, in: controller, destination: destination)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)): onRequestDismiss?(); return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !rows.isEmpty else { return true }
            let delta = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = max(0, min(rows.count - 1, table.selectedRow + delta))
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row); return true
        case #selector(NSResponder.insertNewline(_:)):
            let row = max(0, table.selectedRow)
            if rows.indices.contains(row), case .session(let record, _) = rows[row] { open(record) }
            return true
        default: return false
        }
    }
    private func sessionMenu(_ record: AgentSession, from anchor: NSView) {
        ShellMenuPopover.present(from: anchor, items: sessionMenuItems(record, anchor: anchor))
    }

    func sessionMenuItems(_ record: AgentSession, anchor: NSView) -> [ShellMenuPopover.Item] {
        // 改名有两条路（见 `SessionRename`）：会话开着就敲 `/rename` 让 agent 自己改，
        // 那样它终端里显示的标题也跟着变；会话没开就走官方接口。唯一给不了的情况是
        // 「开着但 agent 正在跑」——这时 PTY 前台是它的输出流，塞不进命令，而从外面
        // 改又会和它自己屏幕上显示的标题不一致。
        let paneIDs = library.openPaneIDs(for: record.key)
        let openPane = AppState.shared?.runningPanes()
            .first { paneIDs.contains($0.pane.dragIdentifier) }?.pane
        var items: [ShellMenuPopover.Item] = openPane == nil ? [
            .action(L("Continue in new tab")) { [weak self] in self?.open(record) },
            .action(L("Split in current tab")) { [weak self] in self?.open(record, destination: .split) },
            .action(L("New window")) { [weak self] in self?.open(record, destination: .window) },
        ] : [
            .action(L("Show terminal")) { [weak self] in self?.open(record) },
        ]
        if openPane == nil || openPane?.acceptsInjectedCommand == true {
            items.append(.action(L("Rename session…")) { [weak self, weak openPane, weak anchor] in
                guard let self, let anchor else { return }
                NameEditorPopover.present(
                    from: anchor, title: L("Rename session"),
                    initial: record.title, confirmLabel: L("Rename")
                ) { name in
                    if let openPane { openPane.renameSession(to: name) }
                    else { SessionRename.perform(record, to: name, library: self.library) }
                }
            })
        }
        items.append(.separator)
        if !library.saving && library.storageError == nil {
            let organization = library.organization
            let archived = organization.isArchived(record)
            let archivedProject = organization.projectID(for: record).map { organization.archivedProjects.contains($0) } == true
            let title = archived ? (archivedProject ? L("Restore to recent sessions") : L("Restore session")) : L("Archive session")
            items.append(.action(title) { [weak self] in
                self?.library.updateOrganization { $0.setArchived(!archived, session: record) }
            })
            items.append(.separator)
            items.append(.header(L("Move to project")))
            for project in library.organization.projects where !library.organization.archivedProjects.contains(project.id) {
                items.append(.action(project.name, checked: library.organization.projectID(for: record) == project.id) { [weak self] in
                    self?.library.updateOrganization { $0.move(record, to: project.id) }
                })
            }
            if organization.projectID(for: record) != nil {
                items.append(.action(L("Move to recent sessions")) { [weak self] in
                    self?.library.updateOrganization { $0.move(record, to: nil) }
                })
            }
        }
        if !library.saving && library.organizationReady && library.storageError == nil {
            items.append(.separator)
            items.append(.action(L("Delete session…"), destructive: true) { [weak self] in
                guard let self, let window = self.window else { return }
                SessionDeletion.confirm(record, library: self.library, window: window)
            })
        }
        return items
    }
    @objc private func createProject() {
        NameEditorPopover.present(from: newProject, title: L("New project…"), confirmLabel: L("Create")) { [weak self] name in
            self?.library.updateOrganization { $0.projects.append(SessionProject(name: name)) }
        }
    }
    private func projectMenu(_ project: SessionProject, from anchor: NSView) {
        guard !library.saving, library.storageError == nil else { return }
        var items: [ShellMenuPopover.Item] = [
            .action(L("Rename project")) { [weak self, weak anchor] in
                guard let self, let anchor else { return }
                NameEditorPopover.present(from: anchor, title: L("Rename project"), confirmLabel: L("Save")) { name in
                    self.library.updateOrganization { state in
                        if let index = state.projects.firstIndex(where: { $0.id == project.id }) { state.projects[index].name = name }
                    }
                }
            },
            .action(L("Move project up")) { [weak self] in
                self?.library.updateOrganization { state in
                    if let index = state.projects.firstIndex(where: { $0.id == project.id }), index > 0 {
                        state.projects.swapAt(index, index - 1)
                    }
                }
            },
            .action(L("Remove project"), destructive: true) { [weak self] in
                self?.library.updateOrganization { $0.removeProject(project.id) }
            },
        ]
        // Existing archives remain recoverable, but new project archiving is not offered.
        if library.organization.archivedProjects.contains(project.id) {
            items.insert(.action(L("Restore project")) { [weak self] in
                self?.library.updateOrganization { $0.setArchived(false, projectID: project.id) }
            }, at: 0)
        }
        ShellMenuPopover.present(from: anchor, items: items)
    }

}

private final class SessionListCell: NSTableCellView {
    override var draggingImageComponents: [NSDraggingImageComponent] {
        let size = NSSize(width: min(max(bounds.width, 180), 260), height: 40)
        let label = title.stringValue
        let appearance = effectiveAppearance
        let preview = NSImage(size: size, flipped: true) { rect in
            appearance.performAsCurrentDrawingAppearance {
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                        xRadius: ShellStyle.rowCornerRadius, yRadius: ShellStyle.rowCornerRadius)
                ShellStyle.raisedSurface.setFill(); path.fill()
                ShellStyle.divider.setStroke(); path.lineWidth = 1; path.stroke()
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byTruncatingTail
                (label as NSString).draw(in: NSRect(x: 12, y: 12, width: size.width - 24, height: 18),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                                     .foregroundColor: ShellStyle.primaryText, .paragraphStyle: paragraph])
            }
            return true
        }
        let component = NSDraggingImageComponent(key: .icon)
        component.contents = preview
        component.frame = NSRect(origin: .zero, size: size)
        return [component]
    }

    let projectIcon = NSImageView()
    private var titleLeading: NSLayoutConstraint!
    var indent: CGFloat = 10 { didSet { titleLeading.constant = indent } }
    let title = SessionTruncatingLabel(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let agentIcon = NSImageView()
    private var detailLeading: NSLayoutConstraint!
    func setAgent(_ agent: SessionAgent?) {
        agentIcon.image = agent.flatMap { AgentSessionIcon.image(for: $0) }
        agentIcon.isHidden = agent == nil
        agentIcon.toolTip = agent.map { $0 == .claude ? "Claude Code" : "OpenAI Codex" }
        detailLeading.constant = agent == nil ? 0 : 16
    }
    let location = SessionTruncatingLabel(labelWithString: "")
    let menuButton = ShellIconButton(symbol: "ellipsis", accessibilityLabel: L("Session actions"), target: nil, action: nil)
    var onMenu: (() -> Void)?
    func resetContent() {
        onMenu = nil
        title.stringValue = ""
        title.fullText = nil
        title.font = .systemFont(ofSize: 12.5, weight: .medium)
        title.textColor = ShellStyle.primaryText
        detail.stringValue = ""
        setAgent(nil)
        location.stringValue = ""
        location.fullText = nil
        projectIcon.isHidden = true
        projectIcon.image = nil
        menuButton.isHidden = false
        indent = 10
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 12.5, weight: .medium)
        title.textColor = ShellStyle.primaryText
        title.lineBreakMode = .byTruncatingTail
        projectIcon.isHidden = true
        projectIcon.contentTintColor = ShellStyle.primaryText
        detail.font = .systemFont(ofSize: 10.5)
        detail.textColor = ShellStyle.secondaryText
        detail.lineBreakMode = .byTruncatingTail
        location.font = .systemFont(ofSize: 10.5)
        location.textColor = ShellStyle.tertiaryText
        location.lineBreakMode = .byTruncatingMiddle
        menuButton.isBordered = false; menuButton.target = self; menuButton.action = #selector(openMenu)
        menuButton.setAccessibilityLabel(L("Session actions"))
        agentIcon.isHidden = true
        agentIcon.contentTintColor = ShellStyle.secondaryText
        for view in [title, detail, location, menuButton, projectIcon, agentIcon] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        titleLeading = title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        detailLeading = detail.leadingAnchor.constraint(equalTo: title.leadingAnchor)
        NSLayoutConstraint.activate([
            titleLeading,
            projectIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            projectIcon.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            projectIcon.widthAnchor.constraint(equalToConstant: 18),
            projectIcon.heightAnchor.constraint(equalToConstant: 16),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            title.trailingAnchor.constraint(equalTo: menuButton.leadingAnchor, constant: -4),
            detailLeading,
            agentIcon.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            agentIcon.centerYAnchor.constraint(equalTo: detail.centerYAnchor),
            agentIcon.widthAnchor.constraint(equalToConstant: 11),
            agentIcon.heightAnchor.constraint(equalToConstant: 11),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            location.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            location.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            location.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 2),
            menuButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            menuButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            menuButton.widthAnchor.constraint(equalToConstant: 26),
            menuButton.heightAnchor.constraint(equalToConstant: 26),
        ])
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func openMenu() { onMenu?() }
}

/// Tooltips belong to the truncated field, not the whole row or the private session ID.
private final class SessionTruncatingLabel: NSTextField {
    var fullText: String?
    override func layout() {
        super.layout()
        let shortened = fullText.map { !$0.isEmpty && $0 != stringValue } ?? false
        toolTip = !stringValue.isEmpty && (shortened || (cell?.cellSize.width ?? 0) > bounds.width)
            ? (fullText ?? stringValue) : nil
    }
}
