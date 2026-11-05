import AppKit
import XCTest
@testable import lightty

/// 单 pane 标签页在第二侧栏里压成一条叶子行；分屏后才展开成两级树。
@MainActor
final class LeafTabRowTests: XCTestCase {
    private var directory: URL!
    private var controller: TerminalWindowController!
    private var column: TabColumnView!
    private var table: NSTableView!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        _ = NSApplication.shared
        AppState.shared = AppState(taskDirectory: directory, sweepStalePanes: false)
        ensureTerminalRuntime()
        controller = TerminalWindowController()
        column = TabColumnView()
        controller.window!.contentView!.addSubview(column)
        column.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        try controller.waitForInitialLayout()
        table = try XCTUnwrap(descendants(column).compactMap { $0 as? NSTableView }.first)
        layout()
    }

    override func tearDown() {
        controller.window?.close()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: 就地命名

    private func nameEditor() -> NSTextField? {
        (0..<table.numberOfRows).lazy
            .compactMap { self.table.view(atColumn: 0, row: $0, makeIfNecessary: false) }
            .flatMap { self.descendants($0).compactMap { $0 as? NSTextField } }
            .first { $0.isEditable }
    }

    /// 排版建出行视图，事件循环跑它挂出的下一拍（给焦点、交结果），再排一次版。
    private func settle() {
        layout()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        layout()
    }

    /// 输入框还没在编辑时才给焦点：已在编辑时再 makeFirstResponder 会让字段编辑器
    /// 先失焦一次，那等于用户点了别处。
    private func focus(_ editor: NSTextField) {
        if editor.currentEditor() == nil { controller.window?.makeFirstResponder(editor) }
    }

    /// 真的经字段编辑器打字：直接改 stringValue 会在失焦时被字段编辑器里的内容盖掉。
    private func type(_ text: String, into editor: NSTextField) throws {
        focus(editor)
        let fieldEditor = try XCTUnwrap(editor.currentEditor() as? NSTextView)
        fieldEditor.selectAll(nil)
        fieldEditor.insertText(text, replacementRange: fieldEditor.selectedRange())
    }

    private func press(_ command: Selector, in editor: NSTextField) throws {
        focus(editor)
        let fieldEditor = try XCTUnwrap(editor.currentEditor() as? NSTextView)
        _ = editor.delegate?.control?(editor, textView: fieldEditor, doCommandBy: command)
        settle()
    }

    /// 叶子行的标签页还叫默认名，没有可「重命名」的：命名时这一行就地展开成分组行，
    /// 标题位就是输入框——名字会出现在哪、这一行会变成什么样，打字时就看得见。
    /// 命名途中列表刷新，打了一半的字不能丢；回车确认后分组行留下。
    func testNamingALeafTabHappensInPlaceAndSurvivesARefresh() throws {
        let tabID = try XCTUnwrap(controller.tabOverview().first?.id)
        XCTAssertEqual(table.numberOfRows, 1, "单 pane、默认名：一条叶子行")
        column.beginNaming(tabID)
        settle()
        XCTAssertEqual(table.numberOfRows, 2, "命名途中以分组行 + pane 行出现")
        let editor = try XCTUnwrap(nameEditor())
        XCTAssertEqual(editor.placeholderAttributedString?.string, L("Tab name"))
        XCTAssertEqual(editor.stringValue, "", "不预填默认名：那不是用户要改的名字")

        try type("发布前检查", into: editor)
        column.reload()
        settle()
        XCTAssertEqual(controller.tabOverview().first?.hasCustomTitle, false, "刷新不等于确认")
        let survivor = try XCTUnwrap(nameEditor())
        XCTAssertEqual(survivor.stringValue, "发布前检查")

        try press(#selector(NSResponder.insertNewline(_:)), in: survivor)
        XCTAssertEqual(controller.tabOverview().first?.title, "发布前检查")
        XCTAssertEqual(controller.tabOverview().first?.hasCustomTitle, true)
        XCTAssertEqual(table.numberOfRows, 2, "起了名就是分组：分组行留下")
        XCTAssertNil(nameEditor())
    }

    // MARK: - helpers

    private func layout() {
        column.reload()
        column.layoutSubtreeIfNeeded()
        table.layoutSubtreeIfNeeded()
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
