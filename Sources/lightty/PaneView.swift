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
    let terminal = TerminalSurfaceView()
    private(set) var binding: Binding = .unnamed

    /// pane 关闭请求（shell 退出或 cmd+W）
    var onClose: ((PaneView) -> Void)?

    init() {
        super.init(frame: .zero)
        header.title = "未命名"
        header.dot = .unnamed
        header.injectEnabled = false

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

        header.onRename = { [weak self] name in self?.rename(to: name) }
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
                let newURL = try AppState.shared.taskStore.rename(at: url, to: name)
                bind(to: newURL, name: name, status: .active)
            }
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
}
