import AppKit
import XCTest

@testable import lightty

/// 单行输入框拿到焦点时该同时成立的三件事。
///
/// 三条都是从一个真实症状倒推出来的：点进「任务名称」，占位文字会横跳一下，
/// 而界面上没有任何东西解释这次位移。拆开是——
///
/// 1. 焦点框亮得太晚。原来用 `NSControl.textDidBeginEditingNotification` 判断
///    「进入编辑」，但那条通知要等第一次敲键才发，点进去的那一刻边框还是透明的。
/// 2. 文字真的会横跳。没聚焦时 cell 把文字画在 `titleRect` 原点，聚焦后
///    field editor 画在 `editorFrame` 原点加一段 `lineFragmentPadding`；
///    `isBezeled = false` 时这两个矩形相同，差的正好是这段 padding（默认 2pt）。
/// 3. 两个输入框的光标一深一浅。`ShellTextArea` 设过 `insertionPointColor`，
///    单行框没设。
final class ShellFieldFocusTests: XCTestCase {
    @MainActor
    private func makeBox() -> (ShellFieldBox, NSWindow) {
        let field = ShellTextField()
        field.placeholderString = "任务名称"
        field.font = .systemFont(ofSize: 12.5)
        if let cell = field.cell as? NSTextFieldCell {
            cell.usesSingleLineMode = true
            cell.wraps = false
            cell.isScrollable = true
        }
        let box = ShellFieldBox(field)
        box.translatesAutoresizingMaskIntoConstraints = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = window.contentView!
        content.addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            box.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            box.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        window.makeKeyAndOrderFront(nil)
        content.layoutSubtreeIfNeeded()
        return (box, window)
    }

    @MainActor
    private func borderAlpha(_ box: ShellFieldBox) -> CGFloat {
        guard let color = box.layer?.borderColor else { return -1 }
        return color.alpha
    }

    /// 点进去就该亮，**不用等敲字**。这条是回归本身。
    @MainActor
    func testFocusRingLightsUpOnFocusNotOnFirstKeystroke() {
        let (box, window) = makeBox()
        window.makeFirstResponder(window.contentView)
        XCTAssertEqual(borderAlpha(box), 0, accuracy: 0.01, "没聚焦时不该有边框")
        window.makeFirstResponder(box.field)
        XCTAssertEqual(borderAlpha(box), 1, accuracy: 0.01,
            "点进输入框的那一刻边框就该亮——别等第一次敲键")
    }

    /// 一个字都没敲就把焦点移走，边框也要熄。
    @MainActor
    func testFocusRingGoesOutWithoutAnyTyping() {
        let (box, window) = makeBox()
        window.makeFirstResponder(box.field)
        XCTAssertEqual(borderAlpha(box), 1, accuracy: 0.01)
        window.makeFirstResponder(window.contentView)
        XCTAssertEqual(borderAlpha(box), 0, accuracy: 0.01, "焦点走了边框就该熄")
    }

    /// cell 画的文字要和 field editor 画的文字落在同一列上。
    @MainActor
    func testTheCellDrawsWhereTheFieldEditorDraws() {
        let (box, window) = makeBox()
        window.makeFirstResponder(box.field)
        guard let editor = box.field.currentEditor() as? NSTextView else {
            return XCTFail("聚焦后应当有 field editor")
        }
        guard let cell = box.field.cell as? NSTextFieldCell else { return XCTFail("拿不到 cell") }
        XCTAssertEqual(cell.titleRect(forBounds: box.field.bounds).minX,
                       editor.frame.minX + (editor.textContainer?.lineFragmentPadding ?? 0),
                       accuracy: 0.01,
                       "两条路径的文字起点要落在同一列上，否则聚焦那一刻文字横跳")
    }

    /// 对齐必须改 cell 那一侧。**别去抹平 field editor 的 `lineFragmentPadding`**：
    /// 抹平了也对齐，但空框时光标正好落在文本容器最左边，被边缘切掉一半——2pt
    /// 的光标变成 1pt，和别处的输入框对不上（敲一个字、光标离开行首就恢复）。
    ///
    /// 这一条同时钉住 `ShellTextFieldCell.editorPadding` 那个常量：它就是拿真的
    /// field editor 量出来的值，AppKit 哪天改了这里就挂。
    @MainActor
    func testTheFieldEditorKeepsItsPaddingSoTheCaretIsNotClipped() {
        let (box, window) = makeBox()
        window.makeFirstResponder(box.field)
        guard let editor = box.field.currentEditor() as? NSTextView else {
            return XCTFail("聚焦后应当有 field editor")
        }
        XCTAssertEqual(editor.textContainer?.lineFragmentPadding,
                       ShellTextFieldCell.editorPadding,
                       "cell 那一侧就是按这个值让位的；抹成 0 会切掉行首的光标")
    }

    /// 光标颜色两个框要一致，用我们自己的字色。
    @MainActor
    func testInsertionPointMatchesTheMultiLineBox() {
        let (box, window) = makeBox()
        window.makeFirstResponder(box.field)
        guard let editor = box.field.currentEditor() as? NSTextView else {
            return XCTFail("聚焦后应当有 field editor")
        }
        XCTAssertEqual(editor.insertionPointColor, ShellStyle.primaryText,
            "单行框的光标色要和 ShellTextArea 一致，不用系统默认那支更淡的")
    }
}
