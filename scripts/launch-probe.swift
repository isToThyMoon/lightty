// 启动跳闪探针（调试工具，不进构建）：spawn app → 连拍窗口 bounds + 全屏帧
// → 输出逐帧像素 diff 表。用于验证「窗口一次成形显示」不回归：
//   swiftc -O scripts/launch-probe.swift -o /tmp/launch-probe
//   /tmp/launch-probe .build/debug/lightty /tmp/frames
// 健康输出 = 窗口 bounds 出现后，只有一次大 pixdiff（显形帧），之前的帧
// 里看不到占位小窗。需要屏幕录制权限。窗口平铺工具的 AX 吸附属外部行为。
import AppKit
import CoreGraphics
import ImageIO

let appPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".build/debug/lightty"
let frameDir = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "frames"
try? FileManager.default.createDirectory(atPath: frameDir, withIntermediateDirectories: true)

let proc = Process()
proc.executableURL = URL(fileURLWithPath: appPath)
proc.environment = ProcessInfo.processInfo.environment
try proc.run()
let pid = proc.processIdentifier
let t0 = Date()

func windowInfo(_ pid: Int32) -> (id: CGWindowID, bounds: CGRect)? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    for w in list {
        guard let owner = w[kCGWindowOwnerPID as String] as? Int32, owner == pid,
              let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
              let id = w[kCGWindowNumber as String] as? UInt32,
              let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
        let rect = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        if rect.width > 50 { return (id, rect) }
    }
    return nil
}

func capture(_ wid: CGWindowID, rectSpec: String, to path: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    _ = wid
    p.arguments = ["-x", "-R", rectSpec, path]
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus == 0 && FileManager.default.fileExists(atPath: path)
}

func fingerprint(_ path: String) -> [UInt8]? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = 64, h = 64
    var buf = [UInt8](repeating: 0, count: w * h)
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.interpolationQuality = .low
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return buf
}

var rows: [(t: Double, bounds: CGRect, path: String?)] = []
let deadline = t0.addingTimeInterval(3.5)
var idx = 0
while Date() < deadline {
    if let info = windowInfo(pid) {
        let t = Date().timeIntervalSince(t0)
        let path = String(format: "%@/f%03d_%04.0fms.png", frameDir, idx, t * 1000)
        // 截固定的全屏区域（用户真实所见），不跟随窗口 bounds，避免把
        // bounds 变化和内容变化混在一个 diff 里
        let sb = CGDisplayBounds(CGMainDisplayID())
        let spec = "0,0,\(Int(sb.width)),\(Int(sb.height))"
        let ok = capture(info.id, rectSpec: spec, to: path)
        rows.append((t, info.bounds, ok ? path : nil))
        idx += 1
    } else {
        rows.append((Date().timeIntervalSince(t0), .zero, nil))
    }
    usleep(40_000)
}
proc.terminate()

print("t(ms)  bounds                       pixdiff")
var prevFP: [UInt8]? = nil
var prevBounds: CGRect? = nil
for r in rows {
    var diffStr = "-"
    if let p = r.path, let fp = fingerprint(p) {
        if let prev = prevFP {
            let d = zip(fp, prev).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
            diffStr = String(format: "%.2f", Double(d) / Double(fp.count))
        } else { diffStr = "first" }
        prevFP = fp
    }
    let b = r.bounds
    let boundsChanged = prevBounds != nil && prevBounds != b ? " *BOUNDS*" : ""
    prevBounds = b
    print(String(format: "%5.0f  x=%.0f y=%.0f w=%.0f h=%.0f  %@%@",
                 r.t * 1000, b.origin.x, b.origin.y, b.width, b.height, diffStr, boundsChanged))
}
