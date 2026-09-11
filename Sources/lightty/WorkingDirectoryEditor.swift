import AppKit

enum WorkingDirectory {
    static func validated(_ input: String) -> String? {
        let path = (input.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard path.hasPrefix("/"), !path.contains("\n"), !path.contains("\r") else { return nil }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

final class WorkingDirectoryEditor: NSStackView, NSTextFieldDelegate {
    private let box: ShellFieldBox
    var field: NSTextField { box.field }
    var onPickerVisibilityChange: ((Bool) -> Void)?
    var onPathChange: (() -> Void)?
    /// 在目录框里按回车的动作。由字段的 doCommandBy 分发，不挂窗口级 keyEquivalent。
    var onCommit: (() -> Void)?
    var path: String {
        get { field.stringValue }
        set { field.stringValue = newValue; onPathChange?() }
    }

    init(path: String) {
        box = ShellFieldBox(ShellTextField())
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        field.stringValue = path
        field.delegate = self
        field.font = .systemFont(ofSize: 11)
        field.focusRingType = .none
        if let cell = field.cell as? NSTextFieldCell {
            cell.usesSingleLineMode = true
            cell.wraps = false
            cell.isScrollable = true
            cell.lineBreakMode = .byTruncatingHead
        }
        field.setAccessibilityLabel(L("Working directory"))
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let choose = ShellIconButton(symbol: "folder", accessibilityLabel: L("Choose folder…"), target: self, action: #selector(chooseFolder))
        addArrangedSubview(box)
        addArrangedSubview(choose)
        choose.widthAnchor.constraint(equalToConstant: 28).isActive = true
        choose.heightAnchor.constraint(equalToConstant: ShellFieldBox.height).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func controlTextDidChange(_ notification: Notification) { onPathChange?() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)), let onCommit else { return false }
        onCommit()
        return true
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Choose folder…")
        if let valid = WorkingDirectory.validated(path) { panel.directoryURL = URL(fileURLWithPath: valid) }
        onPickerVisibilityChange?(true)
        defer { onPickerVisibilityChange?(false) }
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}
