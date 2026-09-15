import AppKit
import QuartzCore
import Testing
@testable import lightty

@MainActor
struct RefreshButtonTests {
    @Test func rotationMovesClockwiseInWindowCoordinates() throws {
        _ = NSApplication.shared
        let button = RefreshButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        let window = NSWindow(contentRect: button.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = button
        button.layoutSubtreeIfNeeded()
        button.isRefreshing = true
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let glyph = try #require(refreshRotationLayer(in: button.layer))
        let animation = try #require(glyph.animation(forKey: "refresh.spin") as? CABasicAnimation)
        #expect(animation.keyPath == "transform.rotation.z")
        let start = try #require(animation.fromValue as? Double)
        let end = try #require(animation.toValue as? Double)
        func inWindow(_ point: CGPoint) -> CGPoint {
            button.convert(glyph.convert(point, to: button.layer), to: nil)
        }
        let center = inWindow(CGPoint(x: glyph.bounds.midX, y: glyph.bounds.midY))
        let first = CGPoint(x: glyph.bounds.midX, y: glyph.bounds.minY)
        let second = CGPoint(x: glyph.bounds.midX, y: glyph.bounds.maxY)
        // Window coordinates are y-up. Determine the visual top through the real view hierarchy.
        let top = inWindow(first).y > inWindow(second).y ? first : second
        #expect(inWindow(top).y > center.y)
        let original = glyph.transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer {
            glyph.transform = original
            CATransaction.commit()
        }
        glyph.transform = CATransform3DMakeRotation(start + (end - start) / 4, 0, 0, 1)
        let quarterTurn = inWindow(top)
        #expect(quarterTurn.x > center.x, "Clockwise moves the top of the icon to the right, not the left")
        #expect(abs(quarterTurn.y - center.y) < 0.01)
    }

    /// 自绘的刷新图标 = 同一张图放进原生 NSButton：imageRect 相等、墨迹范围与轮廓逐像素
    /// 一致（1x / 2x），且渲染出的像素色等于按**这个视图**的 appearance 解析的
    /// secondaryText，不是进程级默认外观。
    @Test(arguments: [CGFloat(1), 2], [NSAppearance.Name.aqua, .darkAqua])
    func customGlyphRendersLikeNativeButton(scale: CGFloat, appearance: NSAppearance.Name) throws {
        _ = NSApplication.shared
        let button = RefreshButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        button.appearance = NSAppearance(named: appearance)
        let native = NSButton(frame: NSRect(x: 30, y: 0, width: 24, height: 24))
        native.isBordered = false
        native.wantsLayer = true
        native.image = button.image
        native.contentTintColor = ShellStyle.secondaryText
        native.appearance = NSAppearance(named: appearance)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 60, height: 24),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = try #require(window.contentView)
        host.addSubview(button)
        host.addSubview(native)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        // 布局：图片矩形与原生按钮一致
        #expect(button.cell?.imageRect(forBounds: button.bounds) == native.cell?.imageRect(forBounds: native.bounds))

        // 轮廓：墨迹范围与整个箭头的剪影（含朝向、对齐）逐像素比
        func render(_ view: NSView, scale: CGFloat) throws -> NSBitmapImageRep {
            let context = try #require(CGContext(data: nil, width: Int(24 * scale), height: Int(24 * scale),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.translateBy(x: 0, y: 24 * scale)
            context.scaleBy(x: scale, y: -scale)
            try #require(view.layer).render(in: context)
            return NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        }
        let reference = try render(native, scale: scale)
        let actual = try render(button, scale: scale)
        let expectedInk = try inkBounds(reference)
        let actualInk = try inkBounds(actual)
        #expect(abs(actualInk.width - expectedInk.width) <= 1)
        #expect(abs(actualInk.height - expectedInk.height) <= 1,
                "actual ink: \(actualInk), native ink: \(expectedInk)")
        #expect(abs(actualInk.minX - expectedInk.minX) <= 1)
        #expect(abs(actualInk.minY - expectedInk.minY) <= 1)
        var error: CGFloat = 0, ink: CGFloat = 0
        for y in 0..<reference.pixelsHigh {
            for x in 0..<reference.pixelsWide {
                let expected = reference.colorAt(x: x, y: y)?.alphaComponent ?? 0
                let observed = actual.colorAt(x: x, y: y)?.alphaComponent ?? 0
                error += abs(expected - observed)
                ink += expected
            }
        }
        #expect(error / ink < 0.15, "Compare the complete arrow silhouette, including its orientation and alignment")

        // 颜色：实心像素等于按该视图 appearance 解析的 secondaryText。
        // 1x 下笔画太细，几乎没有不透明像素可取样，所以固定按 2x 渲染取色。
        let expectedColor = try #require(NSColor(cgColor:
            ShellStyle.secondaryText.shellResolvedCGColor(for: button.effectiveAppearance))?.usingColorSpace(.deviceRGB))
        let colored = try render(button, scale: 2)
        var visible = 0
        var maxColorError: CGFloat = 0
        for y in 0..<colored.pixelsHigh {
            for x in 0..<colored.pixelsWide {
                guard let color = colored.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.9 else { continue }
                visible += 1
                maxColorError = max(maxColorError, abs(color.redComponent - expectedColor.redComponent),
                    abs(color.greenComponent - expectedColor.greenComponent), abs(color.blueComponent - expectedColor.blueComponent))
            }
        }
        #expect(visible > 20, "The refresh symbol must actually render, not just have a centered empty layer")
        #expect(maxColorError < 0.04, "Rendered pixels must use this view's appearance, not the process-wide default")
    }

    private func inkBounds(_ bitmap: NSBitmapImageRep) throws -> CGRect {
        var rect = CGRect.null
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                rect = rect.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        try #require(!rect.isNull, "The actual rendered refresh arrow must be visible")
        return rect
    }

    /// 转轴始终在图标中心：无论读取先于布局（启动时会话视图还不存在就开始读）还是
    /// 布局之后才开始读，anchorPoint 居中、四个角度下中心不动、窗口改尺寸后仍不动；
    /// 读取中把按钮移出再加回视图树，frame 不变、动画 layer 同一实例、转轴仍居中。
    @Test func rotationPivotStaysCenteredAcrossLayoutAndReparenting() throws {
        _ = NSApplication.shared
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

        // 两种启动顺序：先读后布局、先布局后读
        for loadingBeforeLayout in [true, false] {
            let f = try SessionModelFixture()
            defer { f.close() }
            // Startup begins loading before the Sessions view exists.
            if loadingBeforeLayout { f.library.start() }
            let content = SessionsSidebarContent(library: f.library)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 700),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = content
            content.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if !loadingBeforeLayout {
                f.library.start()
                content.activate()
            }
            #expect(f.library.loading, "loadingBeforeLayout=\(loadingBeforeLayout)")
            func descendants(_ view: NSView) -> [NSView] {
                view.subviews.flatMap { [$0] + descendants($0) }
            }
            let button = try #require(descendants(content).compactMap { $0 as? NSButton }
                .first { $0.toolTip == L("Cancel") })
            let layer = try #require(refreshRotationLayer(in: button.layer))
            // A centered rotation leaves the visible glyph's center invariant at every angle.
            // Use the actual post-layout layer geometry, not timing-sensitive presentation frames.
            #expect(layer.anchorPoint.x == 0.5)
            #expect(layer.anchorPoint.y == 0.5)
            #expect(layer !== button.layer, "AppKit must retain ownership of the button's layout geometry")
            try expectCenteredRotation(button, layer: layer)

            // Layout changes while loading must not change the rotation pivot either.
            window.setContentSize(NSSize(width: 360, height: 500))
            content.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try expectCenteredRotation(button, layer: layer)
        }

        // 读取中移出再加回视图树
        let button = RefreshButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        button.isRefreshing = true
        #expect(refreshRotationLayer(in: button.layer) == nil, "Detached views need no animation")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = try #require(window.contentView)
        host.addSubview(button)
        button.setFrameOrigin(NSPoint(x: 200, y: 100))
        host.layoutSubtreeIfNeeded()
        let layer = try #require(refreshRotationLayer(in: button.layer))
        try expectCenteredRotation(button, layer: layer)
        let frame = button.frame
        button.removeFromSuperview()
        #expect(refreshRotationLayer(in: button.layer) == nil)
        host.addSubview(button)
        host.layoutSubtreeIfNeeded()
        #expect(button.frame == frame)
        #expect(refreshRotationLayer(in: button.layer) === layer)
        try expectCenteredRotation(button, layer: layer)
    }

    private func expectCenteredRotation(_ button: NSButton, layer: CALayer) throws {
        let rect = try #require(button.cell?.imageRect(forBounds: button.bounds))
        #expect(rect.width > 0 && rect.height > 0)
        #expect(layer.bounds.size == button.image?.size)
        let center = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
        let expectedCenter = layer.convert(center, to: button.layer)
        #expect(button.bounds.contains(expectedCenter))
        let original = layer.transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer {
            layer.transform = original
            CATransaction.commit()
        }
        for angle in [0.0, Double.pi / 2, Double.pi, 3 * Double.pi / 2] {
            layer.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
            let actual = layer.convert(center, to: button.layer)
            #expect(abs(actual.x - expectedCenter.x) < 0.01)
            #expect(abs(actual.y - expectedCenter.y) < 0.01)
        }
    }

    @Test func refreshCanRestartDuringItsFinishingRevolution() async throws {
        _ = NSApplication.shared
        let button = RefreshButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        let window = NSWindow(contentRect: button.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = button
        button.layoutSubtreeIfNeeded()
        let image = button.image, frame = button.frame
        #expect(button.toolTip == L("Refresh"))
        button.isRefreshing = true
        #expect(button.accessibilityLabel() == L("Cancel"))
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            #expect(button.alphaValue == 0.45)
            button.isRefreshing = false
            #expect(button.alphaValue == 1)
            return
        }
        let layer = try #require(refreshRotationLayer(in: button.layer))
        let animation = try #require(layer.animation(forKey: "refresh.spin"))
        button.isRefreshing = false
        #expect(button.accessibilityLabel() == L("Refresh"))
        #expect(refreshRotationLayer(in: button.layer) === layer)
        button.isRefreshing = true
        try await Task.sleep(for: .seconds(1))
        #expect(layer.animation(forKey: "refresh.spin")?.beginTime == animation.beginTime,
                "A new load cancels the pending stop without restarting the rotation")
        button.isRefreshing = false
        // 上限就是契约：最多转完当前一圈（0.9 秒）就停，不能放宽。
        try await awaitUntil("rotation stops within one revolution", timeout: .milliseconds(1500)) {
            refreshRotationLayer(in: button.layer) == nil
        }
        #expect(button.image === image)
        #expect(button.frame == frame)
        #expect(CATransform3DIsIdentity(layer.transform))
    }
}

func refreshRotationLayer(in layer: CALayer?) -> CALayer? {
    guard let layer else { return nil }
    if layer.animation(forKey: "refresh.spin") != nil { return layer }
    return layer.sublayers?.lazy.compactMap { refreshRotationLayer(in: $0) }.first
}
