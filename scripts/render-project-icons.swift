#!/usr/bin/env swift
import AppKit

// Run from the repository root after editing the two vendored SVGs.
// Generate PDFs once for all supported macOS versions; the app does not parse SVG.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("assets/icons")
let output = root.appendingPathComponent("Sources/lightty/Resources/ProjectIcons")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for name in ["project-folder", "project-folder-open"] {
    guard let image = NSImage(contentsOf: sources.appendingPathComponent(name + ".svg")) else {
        fatalError("Cannot read source icon: \(name)")
    }
    let view = NSImageView(frame: NSRect(origin: .zero, size: image.size))
    view.image = image
    try view.dataWithPDF(inside: view.bounds).write(to: output.appendingPathComponent(name + ".pdf"), options: .atomic)
}
try Data(contentsOf: sources.appendingPathComponent("LICENSE.txt"))
    .write(to: output.appendingPathComponent("Lucide-LICENSE.txt"), options: .atomic)
