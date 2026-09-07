import AppKit
import Testing
@testable import lightty

@MainActor
struct SearchPaletteStyleTests {
    @Test func searchFieldHasSharedBorderlessAppearance() {
        let field = NSTextField()
        SearchPaletteStyle.configure(field)
        #expect(!field.isBezeled)
        #expect(!field.drawsBackground)
        #expect(field.focusRingType == .none)
        #expect(field.font?.pointSize == 15)
    }

    @Test func bothModesUsePaletteGeometry() {
        let bounds = NSRect(x: 0, y: 0, width: 1200, height: 900)
        let frame = SearchPaletteStyle.frame(in: bounds, flipped: false)
        #expect(frame.width == 744)
        #expect(abs(frame.height - 504) <= 1)
        #expect(frame.midX == bounds.midX)
        #expect(frame.maxY == 810)
    }
}
