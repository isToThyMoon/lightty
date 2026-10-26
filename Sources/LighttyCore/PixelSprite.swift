import Foundation

/// 侧栏速度计里的像素小精灵：纯数据，界面按它逐格画方块。
///
/// 造型是向各家风格致敬的原创图案，不复刻任何官方吉祥物的轮廓。
public struct PixelSprite: Sendable, Equatable {
    public enum Ink: Sendable, Equatable {
        /// 固定的品牌色，0xRRGGBB，深浅外观都不变。
        case rgb(UInt32)
        /// 跟随侧栏次级文字色，深浅外观各自取色。
        case foreground
        /// 次级文字色的淡底，给没有品牌形象的通用小精灵当身体。
        case faint
    }

    /// 自上而下每行一个字符串，等长；`.` 是空格，其余字符查 `inks`。
    public let rows: [String]
    public let inks: [Character: Ink]
    /// 生成时轮流出现的像素组（按字符）。两组就交替（踩步），一组就闪烁（光标）；
    /// 静止时只显示第一组。
    public let frames: [Character]

    public init(rows: [String], inks: [Character: Ink], frames: [Character] = []) {
        precondition(Set(rows.map(\.count)).count <= 1, "PixelSprite rows must have equal width")
        self.rows = rows
        self.inks = inks
        self.frames = frames
    }

    public var columns: Int { rows.first?.count ?? 0 }

    /// 每个非空像素：列、行（自上而下）与字符。
    public var pixels: [(column: Int, row: Int, key: Character)] {
        rows.enumerated().flatMap { row, line in
            line.enumerated().compactMap { column, key in key == "." ? nil : (column, row, key) }
        }
    }
}
