import AppKit
import LighttyCore

/// Only owns archived Handoff files; CLI history is never deleted here.
final class ArchivedTasksView: NSStackView {
    private let store: TaskStore
    init(store: TaskStore) {
        self.store = store
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 12
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func reload() {
        arrangedSubviews.forEach { removeArrangedSubview($0); $0.removeFromSuperview() }
        do {
            let files = try store.archivedFiles()
            let hint = NSTextField(wrappingLabelWithString: L("Restore archived Handoff tasks or permanently delete their files. CLI sessions are not affected."))
            hint.textColor = ShellStyle.secondaryText
            addArrangedSubview(hint)
            hint.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            if files.isEmpty { addArrangedSubview(NSTextField(labelWithString: L("No archived tasks"))) }
            for file in files {
                let title = (try? store.load(at: file).name) ?? file.lastPathComponent
                let label = NSTextField(wrappingLabelWithString: title)
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let restore = ArchiveActionButton(title: L("Restore")) { [weak self] in
                    self?.perform { _ = try self?.store.restoreArchived(at: file) }
                }
                let delete = ArchiveActionButton(title: L("Delete permanently…")) { [weak self] in
                    guard let self else { return }
                    let alert = AppBranding.makeAlert()
                    alert.messageText = L("Delete archived task permanently?")
                    alert.informativeText = L("This deletes the Handoff file and cannot be undone.")
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: L("Cancel"))
                    alert.addButton(withTitle: L("Delete permanently"))
                    guard alert.runModal() == .alertSecondButtonReturn else { return }
                    self.perform { try self.store.permanentlyDeleteArchived(at: file) }
                }
                let row = NSStackView(views: [label, restore, delete])
                row.spacing = 12
                addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            }
        } catch { present(error) }
    }
    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
            NotificationCenter.default.post(name: .lighttyTasksDidChange, object: nil)
            reload()
        } catch { present(error) }
    }
    private func present(_ error: Error) {
        let label = NSTextField(wrappingLabelWithString: error.localizedDescription)
        label.textColor = .systemRed
        addArrangedSubview(label)
    }
}

private final class ArchiveActionButton: NSButton {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        action = #selector(invoke)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func invoke() { handler() }
}
