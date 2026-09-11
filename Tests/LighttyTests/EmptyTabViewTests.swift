import AppKit
import Testing
@testable import lightty

@MainActor
struct EmptyTabViewTests {
    @Test func subtitleStaysOnOneLine() throws {
        _ = NSApplication.shared
        if GhosttyRuntime.shared == nil {
            GhosttyRuntime.shared = GhosttyRuntime()
        }

        let view = EmptyTabView()
        view.frame = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        view.layoutSubtreeIfNeeded()

        let subtitle = try #require(descendants(of: view)
            .compactMap { $0 as? NSTextField }
            .first { $0.stringValue == L("Open a task from the sidebar, or create a new tab.") })
        #expect(subtitle.maximumNumberOfLines == 1)
        #expect(subtitle.cell?.wraps == false)
        #expect(subtitle.frame.width >= subtitle.attributedStringValue.size().width)
    }

    @Test func darkTerminalThemeUpdateKeepsEmptyStateReadableInDarkShellAppearance() throws {
        _ = NSApplication.shared
        if GhosttyRuntime.shared == nil {
            GhosttyRuntime.shared = GhosttyRuntime()
        }

        let view = EmptyTabView()
        view.appearance = NSAppearance(named: .darkAqua)
        var values = GhosttyConfigValues()
        values.backgroundColor = .shellRGB(0x1E1E2E)
        values.foregroundColor = .shellRGB(0xCDD6F4)
        values.backgroundOpacity = 1
        NotificationCenter.default.post(
            name: .ghosttyGlobalConfigDidChange,
            object: GhosttyRuntime.shared,
            userInfo: [GhosttyConfigNotification.valuesKey: values])

        let backgroundCG = try #require(view.layer?.backgroundColor)
        let background = try #require(NSColor(cgColor: backgroundCG))
        let title = try #require(descendants(of: view)
            .compactMap { $0 as? NSTextField }
            .first { $0.stringValue == L("No tab open") })
        let foreground = try #require(title.textColor).shellResolvedCGColor(for: view.effectiveAppearance)
        let resolvedForeground = try #require(NSColor(cgColor: foreground))

        #expect(background.luminance < 0.2)
        #expect(contrastRatio(between: background, and: resolvedForeground) >= 4.5)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func contrastRatio(between first: NSColor, and second: NSColor) -> Double {
        let lighter = max(relativeLuminance(first), relativeLuminance(second))
        let darker = min(relativeLuminance(first), relativeLuminance(second))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(_ color: NSColor) -> Double {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        func linear(_ value: CGFloat) -> Double {
            let component = Double(value)
            return component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent)
            + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
    }
}
