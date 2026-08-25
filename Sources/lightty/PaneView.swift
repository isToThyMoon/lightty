import AppKit
import LighttyCore

/// pane = 任务绑定点（HANDOVER 8.2）。header + 终端 surface。
/// 生命周期：新开 pane 不创建文件（未命名，内存态）；命名那一刻才经 TaskStore 落盘。
final class PaneView: NSView {
    enum Binding {
        case unnamed                 // 灰点「未命名」
        case bound(fileURL: URL)     // 绿点，任务文件已存在
    }

    let header = PaneHeaderView()
    let terminal: TerminalSurfaceView
    let dragIdentifier = UUID()
    private(set) var binding: Binding = .unnamed
    private var terminalSearchBar: TerminalSearchBar?
    private var searchSelected: Int?
    private var searchTotal: Int?
    private var dropOverlay: PaneDropOverlayView?

    /// pane 关闭请求（shell 退出，或 core 根据用户 Ghostty keybind 请求 close_surface）
    var onClose: ((PaneView) -> Void)?
    /// 标题或状态变化后，刷新窗口的衍生 metadata；标题栏不重复显示任务名。
    var onMetadataChange: ((PaneView) -> Void)?
    /// pane header 拖到目标四边时，由目标窗口控制器原位重组 split tree。
    var onMoveRequest: ((UUID, PaneView, PaneDropZone) -> Bool)?

    init(surfaceConfiguration: TerminalSurfaceConfiguration = .init()) {
        terminal = TerminalSurfaceView(configuration: surfaceConfiguration)
        super.init(frame: .zero)
        header.title = "未命名"
        header.dot = .unnamed
        header.injectEnabled = false
        header.dragIdentifier = dragIdentifier
        header.onSelect = { [weak self] in self?.focusTerminal() }
        header.dragPreviewProvider = { [weak self] in self?.makeDragPreview() }
        registerForDraggedTypes([.lighttyPaneID])

        for v in [header, terminal] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminal.topAnchor.constraint(equalTo: header.bottomAnchor),
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // 调试标尺：可视化"窗口顶到第一行字"的每一段构成
        if ProcessInfo.processInfo.environment["LIGHTTY_DEBUG_LAYOUT"] != nil {
            let ruler = DebugRulerView(terminal: terminal)
            ruler.translatesAutoresizingMaskIntoConstraints = false
            addSubview(ruler)
            NSLayoutConstraint.activate([
                ruler.topAnchor.constraint(equalTo: topAnchor),
                ruler.bottomAnchor.constraint(equalTo: bottomAnchor),
                ruler.leadingAnchor.constraint(equalTo: leadingAnchor),
                ruler.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { ruler.needsDisplay = true }
        }

        header.onRename = { [weak self] name in self?.rename(to: name) }
        header.onEditingEnded = { [weak self] in self?.focusTerminal() }
        header.onFinish = { [weak self] in self?.finish() }
        header.onInject = { [weak self] in self?.inject() }
        terminal.onCloseRequest = { [weak self] in
            guard let self else { return }
            self.onClose?(self)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 已绑定任务的 pane（恢复流程 / 分屏继承）
    func bind(to fileURL: URL, name: String, status: TaskStatus) {
        binding = .bound(fileURL: fileURL)
        header.title = name
        header.dot = status == .stuck ? .stuck : .active
        header.injectEnabled = true
        onMetadataChange?(self)
    }

    var taskFileURL: URL? {
        if case .bound(let url) = binding { return url }
        return nil
    }

    // MARK: - 命名即落盘

    private func rename(to name: String) {
        do {
            switch binding {
            case .unnamed:
                let created = try AppState.shared.taskStore.create(
                    name: name,
                    cwd: FileManager.default.homeDirectoryForCurrentUser.path,
                    tool: nil)
                bind(to: created.fileURL, name: name, status: .active)
            case .bound(let url):
                // 只改名不动状态：状态点保持文件里的原状态
                let newURL = try AppState.shared.taskStore.rename(at: url, to: name)
                binding = .bound(fileURL: newURL)
                header.title = name
            }
            onMetadataChange?(self)
        } catch {
            NSSound.beep()
            NSLog("task rename/create failed: \(error)")
        }
    }

    // MARK: - 收工 / 注入（指令在点击时实时嵌入当前任务文件路径）

    private func finish() {
        switch binding {
        case .unnamed:
            // 未命名时先触发命名编辑
            header.beginRename()
        case .bound(let url):
            terminal.sendText(HandoffPrompt.finish(taskFilePath: url.path) + "\r")
        }
    }

    private func inject() {
        guard case .bound(let url) = binding else { return }
        terminal.sendText(HandoffPrompt.resume(taskFilePath: url.path) + "\r")
    }

    func focusTerminal() {
        window?.makeFirstResponder(terminal)
    }

    // MARK: - Ghostty terminal search host

    func startTerminalSearch(needle: String?) {
        if let terminalSearchBar {
            if let needle, !needle.isEmpty {
                terminalSearchBar.setNeedle(needle)
            } else {
                terminalSearchBar.focus()
            }
            return
        }

        let bar = TerminalSearchBar(needle: needle)
        bar.terminal = terminal
        bar.onNeedleChange = { [weak terminal] needle in
            terminal?.performBindingAction("search:\(needle)")
        }
        bar.onNext = { [weak terminal] in
            terminal?.performBindingAction("navigate_search:next")
        }
        bar.onPrevious = { [weak terminal] in
            terminal?.performBindingAction("navigate_search:previous")
        }
        bar.onClose = { [weak self] in self?.endTerminalSearch(requestCore: true) }
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: terminal.topAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
        terminalSearchBar = bar
        bar.update(selected: searchSelected, total: searchTotal)
        DispatchQueue.main.async { [weak bar] in bar?.focus() }
    }

    func endTerminalSearch(requestCore: Bool) {
        guard let bar = terminalSearchBar else {
            if requestCore { terminal.performBindingAction("end_search") }
            return
        }
        terminalSearchBar = nil
        bar.removeFromSuperview()
        if requestCore { terminal.performBindingAction("end_search") }
        focusTerminal()
    }

    func updateTerminalSearchSelected(_ selected: Int?) {
        searchSelected = selected
        terminalSearchBar?.update(selected: searchSelected, total: searchTotal)
    }

    func updateTerminalSearchTotal(_ total: Int?) {
        searchTotal = total
        terminalSearchBar?.update(selected: searchSelected, total: searchTotal)
    }

    // MARK: - Ghostty-style pane drag/drop

    private func draggedPaneID(from sender: NSDraggingInfo) -> UUID? {
        guard let raw = sender.draggingPasteboard.string(forType: .lighttyPaneID) else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropOverlay(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropOverlay(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideDropOverlay()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let sourceID = draggedPaneID(from: sender) else { return false }
        return sourceID != dragIdentifier
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { hideDropOverlay() }
        guard let sourceID = draggedPaneID(from: sender), sourceID != dragIdentifier else {
            return false
        }
        let point = convert(sender.draggingLocation, from: nil)
        let zone = PaneDropZone.calculate(at: point, in: bounds)
        return onMoveRequest?(sourceID, self, zone) ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        hideDropOverlay()
    }

    private func updateDropOverlay(for sender: NSDraggingInfo) -> NSDragOperation {
        guard let sourceID = draggedPaneID(from: sender), sourceID != dragIdentifier else {
            hideDropOverlay()
            return []
        }
        let point = convert(sender.draggingLocation, from: nil)
        let zone = PaneDropZone.calculate(at: point, in: bounds)
        let overlay = dropOverlay ?? PaneDropOverlayView(frame: .zero)
        overlay.frame = zone.frame(in: bounds)
        overlay.autoresizingMask = []
        if overlay.superview == nil {
            addSubview(overlay, positioned: .above, relativeTo: nil)
        }
        dropOverlay = overlay
        return .move
    }

    private func hideDropOverlay() {
        dropOverlay?.removeFromSuperview()
        dropOverlay = nil
    }

    func clearDropPreview() {
        hideDropOverlay()
    }

    /// 与 vendor SurfaceDragSource 一样使用缩小的 pane snapshot；若 IOSurface 暂时
    /// 无法缓存，header 会自动退回到带标题的轻量 preview。
    private func makeDragPreview() -> NSImage? {
        guard bounds.width > 0, bounds.height > 0,
              let representation = bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        cacheDisplay(in: bounds, to: representation)
        let source = NSImage(size: bounds.size)
        source.addRepresentation(representation)

        let scale = min(0.2, 180 / bounds.width)
        let size = NSSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale))
        let preview = NSImage(size: size)
        preview.lockFocus()
        source.draw(
            in: NSRect(origin: .zero, size: size),
            from: bounds,
            operation: .copy,
            fraction: 0.9)
        preview.unlockFocus()
        return preview
    }
}
