import AppKit
import XCTest
@testable import lightty

/// 拖起来的卡片是一张位图，它的文字必须和屏幕上的真行一样粗。
/// 重画一遍（cacheDisplay）会启用 font smoothing 把字形描粗，拖着一个粗、
/// 落地换回真行又细回去，用户看到的是一次"虚实切换"，像掉了一帧。
final class DragSnapshotWeightTests: XCTestCase {
    @MainActor
    func testSnapshotTextIsNoHeavierThanWhatIsOnScreen() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        row.wantsLayer = true
        row.layer?.backgroundColor = NSColor.white.cgColor
        let label = NSTextField(labelWithString: "检查合并并发布 TestFlight")
        label.font = .systemFont(ofSize: 12)
        label.frame = NSRect(x: 10, y: 10, width: 280, height: 20)
        row.addSubview(label)
        try XCTUnwrap(window.contentView).addSubview(row)
        window.contentView?.layoutSubtreeIfNeeded()
        row.displayIfNeeded()

        let dragged = try XCTUnwrap(ReorderDrag.snapshot(of: row))

        // 对照组：旧路径，把这一行重画进位图。
        let rep = try XCTUnwrap(row.bitmapImageRepForCachingDisplay(in: row.bounds))
        row.cacheDisplay(in: row.bounds, to: rep)
        let redrawn = NSImage(size: row.bounds.size)
        redrawn.addRepresentation(rep)

        let draggedInk = ink(of: dragged)
        let redrawnInk = ink(of: redrawn)
        XCTAssertGreaterThan(draggedInk, 0, "快照是空的")
        XCTAssertLessThan(Double(draggedInk), Double(redrawnInk) * 0.95,
                          "快照的字重要明显轻于重画路径：\\(draggedInk) vs \\(redrawnInk)")
    }

    /// 深色像素占比：字重变化在这个数上是十几个百分点的差异，够判定。
    @MainActor
    private func ink(of image: NSImage) -> Int {
        guard let data = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: data) else { return 0 }
        var dark = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let alpha = Double(color.alphaComponent)
                let value = Double(color.brightnessComponent) * alpha + (1 - alpha)
                if value < 0.5 { dark += 1 }
            }
        }
        return dark
    }
}
