import AppKit
import LighttyCore

/// 设置右侧的交接文档浏览器。三栏骨架在 `ColumnBrowserView`，这里只回答 Handoff
/// 自己的问题：左栏那三类是什么、当前类下有哪些文档、右栏摆什么。
///
/// 三类合成一页，是因为它们回答的是同一个问题的三段：**现在有哪些交接文档**、
/// **归档里还留着哪些**、**lightty 到底替我对 Agent 说了什么**。原来前两段分散在
/// Handoff 页与「归档」页，第三段独占 Handoff 页，用户要在两个设置页之间来回翻
/// 才能把一件事看全。
///
/// 文档正文**只读**：这些文件 Agent 也在写（交接协议要求它「同目录点开头临时文件
/// + mv」原子替换），设置页要是也能编辑，就得处理两边同时改的冲突——这一版不做。
/// 打开文件交给系统默认应用，那条路上冲突由编辑器自己负责。
final class HandoffSettingsView: ColumnBrowserView {
    /// 左栏的三个落点。取值即 `ColumnBrowserView` 的选中键，改名会丢用户上次的选中。
    enum Category: String, CaseIterable {
        case inProgress = "in-progress"
        case archived
        case handoffProtocol = "protocol"
    }

    /// 一份交接文档在这一页里的全部所需。`text` 是**磁盘上的全文**（含 frontmatter），
    /// 不是 `TaskFile.body`：右栏自陈「这个文件里有什么」，把 frontmatter 藏起来就
    /// 对不上用户用编辑器打开看到的东西。
    private struct Document {
        let fileURL: URL
        let name: String
        let updated: Date?
        /// `## Next steps` 的第一行，没有就空。
        let nextStep: String
        let text: String
        let archived: Bool
        var id: String { fileURL.path }
    }

    private let bindings: TaskBindings
    private var store: TaskStore { bindings.store }
    private(set) var category: Category = .inProgress
    private var inProgress: [Document] = []
    private var archived: [Document] = []
    private var listed: [Document] = []

    /// 「永久删除」的确认。生产走那个警告框；测试注入一个答案，免得 `runModal()`
    /// 把测试进程停在一个不可见的模态上。文案与按钮顺序仍然只写在下面一处。
    var confirmPermanentDelete: () -> Bool = { true }

    private let detailTitle = HandoffSettingsView.label("", font: SkillsStyle.titleFont)
    private let detailSubtitle = HandoffSettingsView.label("", font: SkillsStyle.summaryFont, secondary: true)
    private let detailError = HandoffSettingsView.label("", font: SkillsStyle.summaryFont)
    private let pathScroll = NSTextView.scrollableTextView()
    private var paths: NSTextView { pathScroll.documentView as! NSTextView }
    private let bodyScroll = NSTextView.scrollableTextView()
    private var body: NSTextView { bodyScroll.documentView as! NSTextView }
    private lazy var openButton = ShellTextButton(localize("Open file"), target: self, action: #selector(openFile))
    private lazy var revealButton = ShellIconButton(symbol: "folder", accessibilityLabel: localize("Reveal in Finder"), target: self, action: #selector(revealFile))
    private lazy var archiveButton = ShellTextButton(localize("Archive task"), target: self, action: #selector(archiveDocument))
    private lazy var restoreButton = ShellTextButton(localize("Restore"), target: self, action: #selector(restoreDocument))
    private lazy var deleteButton = ShellTextButton(localize("Delete permanently…"), emphasis: .destructive,
                                                    target: self, action: #selector(deleteDocument))

    /// 协议一栏整块是一个滚动列，与文档详情互斥显示。
    private let protocolScroll = NSScrollView()
    private let protocolColumn = NSStackView()
    private var renderedPath: String?
    private var renderedText: String?

    init(bindings: TaskBindings, preferences: PreferenceStorage = FilePreferences.shared,
         localize: @escaping (String) -> String = { L($0) }) {
        self.bindings = bindings
        super.init(scope: "settings.handoff", preferences: preferences, localize: localize)
        confirmPermanentDelete = { [weak self] in self?.runDeleteConfirmation() ?? false }
        buildDetail()
        applyChromeText()
        resetSelection(to: Category.inProgress.rawValue)
        scan()
        reloadNavigation()
        reloadList()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 测试与调用点要的查询

    /// 切左栏。走骨架那条选中路径，与用户点一下左栏完全同一段代码。
    func select(_ category: Category) { selectNavigation(key: category.rawValue) }

    var documentTable: NSTableView { listTable }
    var selectedDocumentPath: String? { selectedListID }
    var listedNames: [String] { listed.map(\.name) }
    var documentBody: String { body.string }
    var documentPath: String { paths.string }
    var protocolText: String {
        descendants(protocolColumn).compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: "\n")
    }

    private var selected: Document? { listed.first { $0.id == selectedListID } }

    private static func label(_ text: String, font: NSFont, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = secondary ? ShellStyle.secondaryText : ShellStyle.primaryText
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    private func buildDetail() {
        for view in [detailTitle, detailSubtitle, openButton, revealButton, archiveButton,
                     restoreButton, deleteButton, detailError, pathScroll,
                     bodyScroll, protocolScroll] {
            detailArea.addSubview(view)
        }
        detailError.textColor = .systemRed
        detailError.isHidden = true
        paths.isEditable = false
        paths.isSelectable = true
        paths.drawsBackground = false
        paths.font = SkillsStyle.codeFont
        paths.textColor = ShellStyle.secondaryText
        paths.textContainerInset = .zero
        paths.textContainer?.lineFragmentPadding = 0
        paths.setAccessibilityLabel(localize("File locations"))
        pathScroll.drawsBackground = false
        pathScroll.automaticallyAdjustsContentInsets = false
        pathScroll.hasVerticalScroller = true
        pathScroll.autohidesScrollers = true
        body.identifier = NSUserInterfaceItemIdentifier("handoff-document")
        body.isEditable = false
        body.isSelectable = true
        body.drawsBackground = false
        body.textContainerInset = NSSize(width: 0, height: 8)
        body.textContainer?.lineFragmentPadding = 0
        body.setAccessibilityLabel(localize("Handoff document"))
        bodyScroll.drawsBackground = false
        bodyScroll.automaticallyAdjustsContentInsets = false
        bodyScroll.hasVerticalScroller = true
        bodyScroll.autohidesScrollers = true
        refreshButton.toolTip = localize("Rescan the task folder")
        refreshButton.setAccessibilityLabel(localize("Rescan the task folder"))
        buildProtocolColumn()
    }

    // MARK: - 骨架要的答案

    override var searchPlaceholder: String { localize("Search handoff documents…") }
    override var navigationAccessibilityLabel: String { localize("Handoff categories") }
    override var listAccessibilityLabel: String { localize("Handoff documents") }
    override var listHeadingText: String {
        navigation.first { $0.key == selectedKey }?.title ?? localize("Handoff")
    }

    override var emptyListText: String {
        guard searchQuery.isEmpty else { return localize("No matching documents.") }
        switch category {
        case .inProgress: return localize("No tasks yet")
        case .archived: return localize("No archived tasks")
        // 协议不是一份文档，中栏空着是本来的样子，不是「没找到」。
        case .handoffProtocol: return localize("The protocol is the same for every task.")
        }
    }

    /// 协议栏没有「选中一份文档」这回事，右栏那句提示也就不该出现；骨架只认
    /// 文案，给空串等于把它收起来。
    override var detailEmptyText: String {
        category == .handoffProtocol ? "" : localize("Select a handoff document to read it.")
    }

    override func makeNavigation() -> [NavigationItem] {
        [
            .init(title: localize("In progress"), symbol: "doc.text",
                  key: Category.inProgress.rawValue, count: inProgress.count),
            .init(title: localize("Archived"), symbol: "archivebox",
                  key: Category.archived.rawValue, count: archived.count),
            .init(title: localize("Protocol"), symbol: "text.quote",
                  key: Category.handoffProtocol.rawValue, showsCount: false),
        ]
    }

    override func makeListIDs() -> [String] {
        let query = searchQuery
        let source: [Document]
        switch category {
        case .inProgress: source = inProgress
        case .archived: source = archived
        case .handoffProtocol: source = []
        }
        listed = source.filter {
            query.isEmpty || [$0.name, $0.nextStep, $0.fileURL.lastPathComponent]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
        return listed.map(\.id)
    }

    override func listCell(for id: String) -> NSView? {
        guard let document = listed.first(where: { $0.id == id }) else { return nil }
        return ColumnBrowserCell(title: document.name, subtitle: subtitle(of: document),
                                 symbol: "", trailing: "")
    }

    override func didSelectNavigation(key: String) {
        guard let value = Category(rawValue: key) else { return }
        category = value
        // 协议那栏的「还没装」是**查出来的**，切过去就重查一次，不拿构造时的旧结论。
        if value == .handoffProtocol { buildProtocolColumn() }
    }

    override func didSelectList(id: String?) { updateDetail() }
    override var showsListColumn: Bool { category != .handoffProtocol }

    override func reloadData() {
        scan()
        buildProtocolColumn()
        reloadNavigation()
        reloadList()
    }

    override func layoutDetail(in rect: NSRect) {
        let inset = detailInset
        let width = max(0, rect.width - inset * 2)
        let top = SkillsStyle.topInset
        protocolScroll.frame = NSRect(x: inset, y: top, width: width,
                                      height: max(0, rect.height - top - SkillsStyle.inset))
        detailTitle.frame = NSRect(x: inset, y: top, width: width, height: 28)
        detailSubtitle.frame = NSRect(x: inset, y: top + 36, width: width, height: 18)
        // 文字按钮按各自的文字定宽，图标跟在后面：写死宽度总有一种语言对不上，
        // 而把图标夹在两个文字按钮中间，三个控件的轻重就乱了。
        var x = inset
        for button in [openButton, archiveButton, restoreButton, deleteButton] where !button.isHidden {
            let width = ceil(button.attributedTitle.size().width) + 24
            button.frame = NSRect(x: x, y: top + 64, width: width, height: 28)
            x += width + 8
        }
        revealButton.frame = NSRect(x: x, y: top + 64, width: 28, height: 28)
        detailError.frame = NSRect(x: inset, y: top + 100, width: width, height: 18)
        let errorRoom: CGFloat = detailError.isHidden ? 0 : 24
        pathScroll.frame = NSRect(x: inset, y: top + 100 + errorRoom, width: width, height: 40)
        bodyScroll.frame = NSRect(x: inset, y: top + 156 + errorRoom, width: width,
                                  height: max(0, rect.height - top - 156 - errorRoom - SkillsStyle.inset))
        layoutProtocolDocument()
    }

    // MARK: - 数据

    /// 重扫两个目录。读不出来的文件也进列表（标题用文件名、副标题用错误），
    /// 不静默当成不存在——一个坏掉的交接文档比一个消失的交接文档好找。
    private func scan() {
        let result = store.list()
        var live = result.tasks.map {
            document(at: $0.fileURL, task: $0.task, archived: false)
        }
        live += result.failures.map {
            Document(fileURL: $0.fileURL, name: $0.fileURL.lastPathComponent, updated: nil,
                     nextStep: $0.error.localizedDescription, text: text(at: $0.fileURL), archived: false)
        }
        inProgress = live.sorted(by: ordering)
        let files = (try? store.archivedFiles()) ?? []
        archived = files.map { url in
            guard let task = try? store.load(at: url) else {
                return Document(fileURL: url, name: url.lastPathComponent, updated: nil,
                                nextStep: "", text: text(at: url), archived: true)
            }
            return document(at: url, task: task, archived: true)
        }.sorted(by: ordering)
    }

    private func document(at url: URL, task: TaskFile, archived: Bool) -> Document {
        Document(fileURL: url, name: task.name, updated: task.updated,
                 nextStep: nextStep(of: task.body), text: text(at: url), archived: archived)
    }

    private func text(at url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// 最近更新的在前。读不出时间的（解析失败）排最后，按文件名——它们没有可比的时间，
    /// 混在中间会显得列表的序是随机的。
    private func ordering(_ lhs: Document, _ rhs: Document) -> Bool {
        switch (lhs.updated, rhs.updated) {
        case let (left?, right?): return left == right ? lhs.name < rhs.name : left > right
        case (nil, nil): return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        case (_?, nil): return true
        case (nil, _?): return false
        }
    }

    /// 中栏的第二行：**最近更新 + 下一步的第一行**。
    ///
    /// 这两样各答一个问题，缺一个都不够挑：时间答「这份还新鲜吗」，下一步答
    /// 「这份是干什么的」。任务名往往是一句项目名，一屏里好几个长得差不多。
    ///
    /// 下一步取自 `LaunchComposer.summarize`，不另写一个解析器：任务气泡里显示的
    /// 「下一步」就是它认出来的那一节，两处认的必须是同一段，否则用户在两个地方
    /// 读到的是同一份文档的两个说法。
    private func subtitle(of document: Document) -> String {
        let time = document.updated.map(relativeTime) ?? ""
        return [time, document.nextStep].filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }

    private func nextStep(of body: String) -> String {
        let summary = LaunchComposer.summarize(body)
        guard summary != L("No handoff summary yet") else { return "" }
        let line = summary.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("## ") } ?? ""
        return line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
    }

    private func relativeTime(_ date: Date) -> String {
        RelativeTime.text(date, localize: localize)
    }

    // MARK: - 右栏

    private func updateDetail() {
        // 上一次动作的报错跟着那一份文档，换一份就该消失——留在那儿会读成新文档也出了错。
        detailError.stringValue = ""
        detailError.isHidden = true
        let showsProtocol = category == .handoffProtocol
        protocolScroll.isHidden = !showsProtocol
        let document = showsProtocol ? nil : selected
        for view in [detailTitle, detailSubtitle, openButton, revealButton,
                     pathScroll, bodyScroll] {
            view.isHidden = document == nil
        }
        archiveButton.isHidden = document.map { $0.archived } ?? true
        restoreButton.isHidden = document.map { !$0.archived } ?? true
        deleteButton.isHidden = restoreButton.isHidden
        // 这一排是按显示出来的按钮依次排的，显隐一变就得重排。
        needsLayout = true
        guard let document else {
            // 文档没了就把正文和路径一起清掉：只隐藏控件的话，下一次选中前那份
            // 旧文本还在文本视图里，选中任何一条都会先闪一下上一份的内容。
            paths.string = ""
            body.string = ""
            renderedPath = nil
            renderedText = nil
            return
        }
        detailTitle.stringValue = document.name
        detailTitle.toolTip = document.name
        detailSubtitle.stringValue = subtitle(of: document)
        detailSubtitle.toolTip = detailSubtitle.stringValue
        if paths.string != document.fileURL.path {
            paths.string = document.fileURL.path
            paths.scrollToBeginningOfDocument(nil)
        }
        openButton.isEnabled = FileManager.default.fileExists(atPath: document.fileURL.path)
        updateBody(document, force: false)
    }

    private func updateBody(_ document: Document, force: Bool) {
        let changed = renderedPath != document.id || renderedText != document.text
        guard force || changed else { return }
        body.textStorage?.setAttributedString(SkillDocumentPresentation.text(document.text, raw: false))
        if changed {
            body.setSelectedRange(NSRange(location: 0, length: 0))
            body.scrollToBeginningOfDocument(nil)
        }
        renderedPath = document.id
        renderedText = document.text
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let selected { updateBody(selected, force: true) }
    }

    // MARK: - 动作

    @objc private func openFile() {
        guard let document = selected else { return }
        if !NSWorkspace.shared.open(document.fileURL) {
            report(localize("The handoff file could not be opened."))
        }
    }

    @objc private func revealFile() {
        guard let document = selected else { return }
        NSWorkspace.shared.activateFileViewerSelecting([document.fileURL])
    }

    /// 归档走 `TaskBindings`，不直接调 store：归档要把绑着这份任务的终端全部解绑，
    /// 那是 `TaskBindings` 的职责，绕过去会留下指向 archive/ 里某个文件的终端。
    @objc private func archiveDocument() {
        guard let document = selected, !document.archived else { return }
        perform { try self.bindings.archiveTask(at: document.fileURL) }
    }

    @objc private func restoreDocument() {
        guard let document = selected, document.archived else { return }
        perform { try self.store.restoreArchived(at: document.fileURL) }
    }

    @objc private func deleteDocument() {
        guard let document = selected, document.archived else { return }
        guard confirmPermanentDelete() else { return }
        perform { try self.store.permanentlyDeleteArchived(at: document.fileURL) }
    }

    /// 文案与按钮顺序原样沿用原来的归档页：用户已经认得这个框，换说法只会让
    /// 「永久删除」看起来像一件新的、没见过的事。
    private func runDeleteConfirmation() -> Bool {
        let alert = AppBranding.makeAlert()
        alert.messageText = localize("Delete archived task permanently?")
        alert.informativeText = localize("This deletes the Handoff file and cannot be undone.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: localize("Cancel"))
        alert.addButton(withTitle: localize("Delete permanently"))
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// 动作做完自己立刻重读两栏，不等目录监听：用户按下按钮，列表就该是新的。
    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
            selectList(id: nil)
            scan()
            reloadNavigation()
            reloadList()
        } catch { report(error.localizedDescription) }
    }

    private func report(_ message: String) {
        detailError.stringValue = message
        detailError.toolTip = message
        detailError.isHidden = false
        needsLayout = true
    }

    // MARK: - 协议栏

    /// 五块，与原来 Handoff 设置页逐块相同：开场注入、中途绑定注入、技能调用写法、
    /// 插件没装时的直述兜底、注入时机。
    ///
    /// 全部文本取自 `HandoffProtocol`，**不另存副本**：副本迟早跟真正注入的对不上，
    /// 而「用户照着设置页读、Agent 收到的却是别的」是最难被发现的一种不一致。
    private func buildProtocolColumn() {
        if protocolScroll.documentView == nil {
            protocolColumn.orientation = .vertical
            protocolColumn.alignment = .leading
            protocolColumn.spacing = 0
            protocolColumn.translatesAutoresizingMaskIntoConstraints = false
            protocolColumn.setHuggingPriority(.init(1), for: .horizontal)
            protocolScroll.drawsBackground = false
            protocolScroll.hasVerticalScroller = true
            protocolScroll.autohidesScrollers = true
            protocolScroll.automaticallyAdjustsContentInsets = false
            let document = HandoffFlippedView()
            document.translatesAutoresizingMaskIntoConstraints = false
            protocolScroll.documentView = document
            document.addSubview(protocolColumn)
            NSLayoutConstraint.activate([
                document.widthAnchor.constraint(equalTo: protocolScroll.contentView.widthAnchor),
                document.bottomAnchor.constraint(equalTo: protocolColumn.bottomAnchor, constant: 24),
                protocolColumn.topAnchor.constraint(equalTo: document.topAnchor),
                protocolColumn.leadingAnchor.constraint(equalTo: document.leadingAnchor),
                protocolColumn.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            ])
        }
        for view in protocolColumn.arrangedSubviews {
            protocolColumn.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let column = protocolColumn
        addWide(hintLabel(localize("This is what lightty says to the Agent when a terminal has a task bound. It is fixed in this version.")), to: column)
        column.setCustomSpacing(28, after: column.arrangedSubviews.last!)

        let path = Self.sampleTaskPath
        addSection(localize("Injected at session start"),
                   hint: localize("Sent once when a session starts in a terminal that already has a task bound."),
                   body: HandoffProtocol.injection(path: path, body: Self.sampleTaskFile, lateBinding: false),
                   to: column)

        // 中途绑定那版与开场版只有开头不同，后面逐字相同。整段再贴一次，这一页就要
        // 多滚一屏读同样的字，用户会以为自己滚回去了——只展示不同的那一段。
        addSection(localize("Injected when a task is bound later"),
                   hint: localize("Sent with the next message after a task is bound, rebound, or renamed."),
                   body: HandoffProtocol.injection(path: path, body: Self.sampleTaskFile,
                                                   lateBinding: true),
                   to: column)

        buildProtocolSkill(path: path, into: column)

        addSection(localize("Typed in when the plugin is not installed"),
                   hint: localize("The button falls back to this. It carries the whole contract on its own, so it works without the plugin and without the session-start text."),
                   body: HandoffProtocol.directInstruction(path: path),
                   to: column)

        column.addArrangedSubview(sectionLabel(localize("When lightty injects")))
        column.setCustomSpacing(10, after: column.arrangedSubviews.last!)
        for line in [
            localize("Session start: injected whenever the terminal has a task bound."),
            localize("Later binding or rename: injected again only when the session or the file path changed."),
            localize("Unbinding: nothing is injected, and the next binding starts fresh."),
        ] {
            addWide(hintLabel(line), to: column)
            column.setCustomSpacing(6, after: column.arrangedSubviews.last!)
        }
        needsLayout = true
    }

    /// 技能一节。调用写法两家不一样，且都按插件名加前缀——这是页面上唯一「照着敲」
    /// 的内容，所以单独成行、可选中，不埋在正文里。
    ///
    /// 装没装是**查出来的**，不是断言。这一栏的自陈目的就是「告诉用户 lightty 到底
    /// 做了什么」，而技能没装时敲下去是静默失败（两家都不报错），在这点上写一句
    /// 「已随插件安装」等于骗人。
    private func buildProtocolSkill(path: String, into column: NSStackView) {
        column.addArrangedSubview(sectionLabel(localize("Skill")))
        column.setCustomSpacing(12, after: column.arrangedSubviews.last!)
        let invocations = SettingsGroup()
        // 名字取自 LaunchAgent.title，不在这里重打一遍："Claude Code" 这类产品名
        // 已经有主了，抄一份迟早两处对不上。
        // 展示的是**裸写法**，不带路径：用户手敲不需要背一长串路径，技能自己会去
        // `~/.lightty/panes/$LIGHTTY_PANE_ID/task` 找回来。按钮发的那一份是带路径的
        // （见 `AgentCommand.handoff`），那是内部形式，不该摆在"你该输入什么"这里。
        let agents = SessionAgent.allCases.map { ($0, LaunchAgent($0)) }
        var unavailable: [String] = []
        for (agent, launch) in agents {
            let value = NSTextField(labelWithString:
                HandoffProtocol.skillInvocation(agent: agent, plugin: HookMarketplace.pluginName,
                                                path: nil))
            value.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            value.textColor = ShellStyle.secondaryText
            value.isSelectable = true
            invocations.addRow(title: launch.title, control: value)
            if !HookInstaller.handoffSkillAvailable(for: agent) { unavailable.append(launch.title) }
        }
        addWide(invocations, to: column)
        column.setCustomSpacing(12, after: invocations)
        addWide(hintLabel(localize("Typing the invocation runs it; the Agent can also reach it when you ask in your own words. Append what the next session should focus on to tailor the document to it.")), to: column)
        column.setCustomSpacing(6, after: column.arrangedSubviews.last!)
        // 一家一行，不拼成一句：拼接要一个分隔符，而中英的分隔符不一样，
        // 为两家 agent 引进一个"顿号 / 逗号"的本地化键不划算。
        for name in unavailable {
            addWide(hintLabel(String(format: localize("%@ cannot run it yet. Install or update the lightty plugin under General, Agent status hooks, Manage…."), name)), to: column)
            column.setCustomSpacing(6, after: column.arrangedSubviews.last!)
        }
        column.setCustomSpacing(12, after: column.arrangedSubviews.last!)
        addWide(protocolBlock(HandoffProtocol.skillDocument), to: column)
        column.setCustomSpacing(32, after: column.arrangedSubviews.last!)
    }

    /// 一节 = 标题 + 说明 + 协议原文。几处结构一样，抽出来免得间距各写各的。
    private func addSection(_ title: String, hint: String, body: String, to column: NSStackView) {
        column.addArrangedSubview(sectionLabel(title))
        column.setCustomSpacing(8, after: column.arrangedSubviews.last!)
        addWide(hintLabel(hint), to: column)
        column.setCustomSpacing(12, after: column.arrangedSubviews.last!)
        addWide(protocolBlock(body), to: column)
        column.setCustomSpacing(32, after: column.arrangedSubviews.last!)
    }

    /// 列里的每个子视图都要显式占满列宽：列是 `.leading` 对齐且贴合内容，
    /// 不给约束的话长文本会把列撑到窗口外。
    private func addWide(_ view: NSView, to column: NSStackView) {
        column.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = ShellStyle.primaryText
        return label
    }

    private func hintLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = ShellStyle.tertiaryText
        return label
    }

    /// 协议原文：等宽、可选中、**不走本地化**——它是跨会话的数据格式协议，
    /// 固定英文（同 `Localization.swift` 的边界说明）。
    ///
    /// 套一层与 `SettingsGroup` 同源的容器：这一栏的等宽正文有几十行，裸铺在
    /// 背景上分不清哪儿是一块的起止。
    private func protocolBlock(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        label.textColor = ShellStyle.secondaryText
        return ProtocolBlockView(label)
    }

    private func layoutProtocolDocument() {
        guard let document = protocolScroll.documentView else { return }
        document.layoutSubtreeIfNeeded()
        protocolScroll.reflectScrolledClipView(protocolScroll.contentView)
    }

    /// 路径用**占位符**而不是一条像模像样的假路径。这一处是 lightty 运行时替换的
    /// 槽位，写成 `/Users/me/.lightty/tasks/Rewrite the launch composer.md` 会让人
    /// 分不清那是示例还是真会出现的字面量——尖括号一眼就是占位。
    ///
    /// 与下面的 `sampleTaskFile` 是两回事，两者刻意不同口径：那份是**用户文件的
    /// 内容**，拿真实感的样例数据演示格式才有用；这一处是我们要填的槽。
    private static let sampleTaskPath = "<task file path>"

    /// 注入的是任务文件**全文**（含 frontmatter）——「只重写结束 `---` 之后」那条
    /// 指令得让 Agent 对着实物看，所以示意值也带上 frontmatter，键与 lightty 实际
    /// 写出的一致。
    private static let sampleTaskFile = """
        ---
        name: Rewrite the launch composer
        workdir: /Users/me/project/app
        tool: claude
        created: 2026-09-01T09:00:00Z
        updated: 2026-09-08T17:20:00Z
        ---
        ## Next steps
        - …
        """
}

private final class HandoffFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 协议原文的阅读容器：使用圆角、抬升底色和留白，不画表单分组的外框。
/// 内边距与 `SettingsGroup` 对齐。
///
/// 单独一个类型而不是复用 `SettingsGroup`：那个的 `addRow` 是「左标题右控件、
/// 行高至少 48」的布局，几十行等宽正文塞进去会被挤进右侧窄条。这里要的只是它
/// 的外壳。
private final class ProtocolBlockView: NSView {
    init(_ content: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        layer?.backgroundColor = ShellStyle.raisedSurface.shellResolvedCGColor(for: effectiveAppearance)
    }
}
