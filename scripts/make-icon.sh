#!/bin/bash
# 从 assets/lightty-icon.svg（1024 母图）生成 assets/lightty.icns。
# SVG 渲染用 AppKit（macOS 11+ NSImage 原生支持 SVG），无第三方依赖。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SVG="$ROOT/assets/lightty-icon.svg"
ICONSET="$(mktemp -d)/lightty.iconset"
mkdir -p "$ICONSET"

swift - "$SVG" "$ICONSET" <<'SWIFT'
import AppKit

let svgURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outDir = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let source = NSImage(contentsOf: svgURL) else { fatalError("cannot load SVG") }

// iconset 规格：基础尺寸 × (@1x, @2x)
let specs: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for spec in specs {
    let px = spec.px
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("rep \(px)") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    source.draw(
        in: NSRect(x: 0, y: 0, width: px, height: px),
        from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png \(px)") }
    try! png.write(to: outDir.appendingPathComponent("\(spec.name).png"))
}
print("rendered \(specs.count) sizes")
SWIFT

iconutil -c icns "$ICONSET" -o "$ROOT/assets/lightty.icns"
rm -rf "$(dirname "$ICONSET")"
echo "done: assets/lightty.icns ($(du -h "$ROOT/assets/lightty.icns" | cut -f1))"
