import AppKit

/// A compact, icon-free child window. Return and Escape take the safe action.
final class SessionDeletionConfirmation: NSObject {
    var messageText = ""
    var informativeText = ""
    private(set) var buttons: [NSButton] = []
    private var panel: ShellMenuWindow?
    private var eventMonitor: Any?
    private var closeObserver: NSObjectProtocol?
    private var completion: ((NSApplication.ModalResponse) -> Void)?

    func addButton(withTitle title: String) {
        let button = ShellTextButton(title, emphasis: buttons.isEmpty ? .quiet : .destructive,
                                     target: self, action: #selector(choose(_:)))
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.label = title
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 32),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: max(72, button.intrinsicContentSize.width + 24))
        ])
        button.tag = buttons.count
        buttons.append(button)
    }

    func beginSheetModal(for parent: NSWindow, completionHandler: @escaping (NSApplication.ModalResponse) -> Void) {
        let title = NSTextField(wrappingLabelWithString: messageText)
        title.font = .boldSystemFont(ofSize: 15)
        let parts = informativeText.components(separatedBy: "\n\n")
        let name = NSTextField(wrappingLabelWithString: parts.first ?? "")
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.textColor = ShellStyle.primaryText
        name.maximumNumberOfLines = 2
        let detail = NSTextField(wrappingLabelWithString: parts.dropFirst().joined(separator: "\n\n"))
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = ShellStyle.secondaryText
        let actions = NSStackView(views: buttons)
        actions.orientation = .horizontal
        actions.spacing = 8
        let actionRow = NSView()
        actions.translatesAutoresizingMaskIntoConstraints = false
        actionRow.addSubview(actions)
        NSLayoutConstraint.activate([
            actions.trailingAnchor.constraint(equalTo: actionRow.trailingAnchor),
            actions.topAnchor.constraint(equalTo: actionRow.topAnchor),
            actions.bottomAnchor.constraint(equalTo: actionRow.bottomAnchor),
            actions.leadingAnchor.constraint(greaterThanOrEqualTo: actionRow.leadingAnchor)
        ])
        let stack = NSStackView(views: [title, name, detail, actionRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(18, after: detail)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 340),
            title.widthAnchor.constraint(equalToConstant: 300),
            name.widthAnchor.constraint(equalToConstant: 300),
            detail.widthAnchor.constraint(equalToConstant: 300),
            actionRow.widthAnchor.constraint(equalToConstant: 300)
        ])
        let controller = NSViewController()
        controller.view = content
        let panel = ShellMenuWindow(content: controller)
        self.panel = panel
        panel.appearance = parent.effectiveAppearance
        panel.dismissesOnResignKey = false
        panel.onDismiss = { [weak self] in self?.cancel() }
        let margin = ShellMenuWindow.shadowMargin
        panel.setContentSize(NSSize(width: panel.cardSize.width + margin * 2,
                                    height: panel.cardSize.height + margin * 2))
        panel.onDefaultAction = { [weak self] in self?.cancel() }
        completion = completionHandler
        panel.setFrameOrigin(NSPoint(x: parent.frame.midX - panel.frame.width / 2,
                                     y: parent.frame.midY - panel.frame.height / 2))
        panel.setBackdrop(ShellMenuPopover.blurredBackdrop(of: parent,
            under: panel.frame.insetBy(dx: margin, dy: margin)))
        // A native sheet supplies its own opaque rounded surface, including our shadow margin.
        // Use the same transparent child-window presentation as the mode menu instead.
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        // Retain this request until dismissal; block interaction with its parent only.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown,
            .otherMouseDown, .keyDown, .scrollWheel]) { [self, weak parent] event in
            guard let parent, event.window === parent else { return event }
            if event.type == .leftMouseDown || event.type == .rightMouseDown { cancel() }
            return nil
        }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: parent, queue: .main) { [self] _ in cancel() }
    }

    @objc private func choose(_ sender: NSButton) {
        finish(sender.tag == 0 ? .alertFirstButtonReturn : .alertSecondButtonReturn)
    }
    private func cancel() {
        finish(.alertFirstButtonReturn)
    }

    private func finish(_ response: NSApplication.ModalResponse) {
        guard let panel else { return }
        self.panel = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        let parent = panel.parent
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent?.makeKey()
        let callback = completion
        completion = nil
        callback?(response)
    }
}
