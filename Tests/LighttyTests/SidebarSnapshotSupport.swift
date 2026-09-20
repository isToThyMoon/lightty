import AppKit
import XCTest
import LighttyCore
@testable import lightty

struct SidebarSnapshotCatalog: CatalogOnlyProvider {
    let source: SessionCatalogSource
    func page(archived: Bool, cursor: String?, cancelled: () -> Bool) throws -> SessionCatalogPage {
        .init(sessions: archived || source.agent == .claude ? [] : ["修复搜索页键盘遮挡", "Review sidebar alignment", "整理 Agent 会话恢复逻辑"].enumerated().map { index, title in
            AgentSession(key: .init(agent: source.agent, sourceRoot: source.root.path, nativeID: "sidebar-\(index)"),
                         title: title, workingDirectory: "/Users/example/project/mobile/apps/client",
                         updatedAt: Date(timeIntervalSince1970: 1_789_450_000 - Double(index * 3600)))
        }, nextCursor: nil)
    }
}

/// 只在显式截图分支上屏；所有任务、会话和终端内容均为 fixture。
@MainActor
func captureSidebarVariants(_ controller: TerminalWindowController, panel: PrimarySidebar, directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let window = try XCTUnwrap(controller.window)
    defer { ShellMenuPopover.dismiss(); window.orderOut(nil) }
    controller.sessionLibrary.refresh(includeArchived: false)
    try waitUntil("fixture sessions loaded") { !controller.sessionLibrary.loading && controller.sessionLibrary.records.count == 3 }
    func selectMode(_ mode: PrimarySidebarMode) {
        // 截图直接布局最终态，避免把滑块的过渡帧误判为选中态错位。
        panel.selectMode(mode, animated: false)
        panel.layoutSubtreeIfNeeded()
    }
    let names = ["开发调试基础 concepts", "lightty 优化", "mobile 开发", "backend-java 领域语言学习", "agent 输出的 output style"]
    for name in names {
        _ = try AppState.shared.taskBindings.store.create(name: name, workdir: "/Users/example/project/mobile")
    }
    func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    descendants(panel).compactMap { $0 as? HandoffSidebarContent }.first?.reload()
    let pane = try XCTUnwrap(controller.activePane)
    pane.rename(to: "搜索结果页商卡 title 对齐")
    controller.renameTab(at: 0, to: "mobile 开发")
    controller.split(pane, direction: .down)
    for name in ["Main 分支周末整理", "优化设置页插件技能 MCP 界面", "修复搜索页键盘遮挡"] {
        let next = PaneView()
        next.rename(to: name)
        if let record = controller.sessionLibrary.records.first(where: { $0.title == name }) {
            next.associateSession(.init(key: record.key, configuration: .custom(record.key.sourceRoot),
                workingDirectory: "/Users/example/project/mobile/apps/client"))
        }
        controller.addTab(initialPane: next)
    }
    for pane in controller.panes() {
        controller.sessionLibrary.updateDirectory("/Users/example/project/mobile/apps/client", for: pane.dragIdentifier)
    }
    if let entry = AppState.shared.taskBindings.store.list().tasks.first {
        pane.bind(to: entry.fileURL, name: entry.task.name)
    }
    window.setContentSize(NSSize(width: 1180, height: 760))
    window.makeKeyAndOrderFront(nil)
    try waitUntil("sidebar slide finishes") { panel.frame.minX >= ShellStyle.panelInset - 0.5 }
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        window.appearance = NSAppearance(named: appearance)
        for radius in [CGFloat(16), 18, 20] {
            panel.layer?.cornerRadius = radius
            try captureSettingsWindow(window, to: directory.appendingPathComponent("sidebar-\(appearance.rawValue)-continuous-\(Int(radius)).png"))
        }
        panel.layer?.cornerRadius = ShellStyle.panelCornerRadius
        panel.layer?.cornerCurve = .circular
        try captureSettingsWindow(window, to: directory.appendingPathComponent("sidebar-\(appearance.rawValue)-circular.png"))
        panel.layer?.cornerCurve = .continuous
        selectMode(.sessions)
        try waitUntil("fixture sessions loaded") { !AppState.shared.sessionLibrary.loading && AppState.shared.sessionLibrary.records.count == 3 }
        try drainMainQueue()
        try captureSettingsWindow(window, to: directory.appendingPathComponent("sidebar-\(appearance.rawValue)-sessions.png"))
        selectMode(.handoff)
        if let sidebar = window.contentView?.superview?.subviews.compactMap({ $0 as? TabSidebarView }).first,
           let width = sidebar.constraints.first(where: { $0.firstAttribute == .width && $0.secondItem == nil }) {
            let original = width.constant
            width.constant = 280
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            try captureSettingsWindow(window, to: directory.appendingPathComponent("sidebar-\(appearance.rawValue)-wide.png"))
            width.constant = original
            window.contentView?.superview?.layoutSubtreeIfNeeded()
        }
        if let table = descendants(panel).compactMap({ $0 as? NSTableView }).first,
           let row = table.rowView(atRow: 0, makeIfNecessary: true) as? ShellTableRowView {
            row.setSidebarHovered(true)
            try captureSettingsWindow(window, to: directory.appendingPathComponent("sidebar-\(appearance.rawValue)-hover.png"))
            row.setSidebarHovered(false)
            if let button = (table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SidebarRowActionContent)?.rowActionButton {
                XCTAssertTrue(window.makeFirstResponder(button), "更多操作可通过键盘聚焦")
                try captureSettingsWindow(window, to: directory.appendingPathComponent("sidebar-\(appearance.rawValue)-keyboard.png"))
                button.performClick(nil)
                XCTAssertTrue(button.menuPresented, "菜单打开时保留行内入口")
                ShellMenuPopover.dismiss()
                XCTAssertFalse(button.menuPresented)
                window.makeFirstResponder(nil)
            }
        }
    }
}
