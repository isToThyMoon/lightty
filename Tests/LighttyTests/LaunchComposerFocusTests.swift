import AppKit
import Testing
@testable import lightty

@MainActor
struct LaunchComposerFocusTests {
    @Test(arguments: [false, true])
    func didShowFocusesOnlyStandaloneNewTask(embedded: Bool) throws {
        _ = NSApplication.shared
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 700),
                            styleMask: [.titled], backing: .buffered, defer: false)
        defer { host.orderOut(nil) }
        let root = try #require(host.contentView)
        let search = NSTextField(frame: NSRect(x: 0, y: 650, width: 200, height: 24))
        root.addSubview(search)
        let controller = LaunchComposerController(subject: .newTask, controller: nil, embedded: embedded)
        root.addSubview(controller.view)
        root.layoutSubtreeIfNeeded()
        #expect(host.makeFirstResponder(search))
        #expect(search.currentEditor() != nil)

        controller.popoverDidShow(Notification(name: NSPopover.didShowNotification))

        if embedded {
            #expect(search.currentEditor() != nil)
            #expect(controller.nameField.currentEditor() == nil)
        } else {
            #expect(controller.nameField.currentEditor() != nil)
            #expect(search.currentEditor() == nil)
        }
    }
}
