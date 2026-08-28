# Ghostty 官方壳对齐实施清单

> 参考源：`vendor/ghostty/macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`（2515 行）
> 当前状态：lightty `TerminalSurfaceView.swift` 1071 行，输入管线已完整对齐，以下为缺失的上层功能。

---

## P0：核心体验（缺失会让用户觉得终端坏了）

### 1. 标题与状态回传
- **缺失 action**：`SET_TITLE`、`SET_TAB_TITLE`、`PROMPT_TITLE`、`PWD`
- **表现**：终端程序设置标题（starship/zsh 等）不会反映到窗口标题栏和 tab 标签
- **参考**：官方壳 L13-L22（title 属性 + debounce timer）、App.swift 对应 action handler
- **实现**：在 `GhosttyRuntime` action_cb 接这 4 个 action，通过 surface → pane → window 链路更新标题

### 2. 退出确认 / 子进程退出
- **缺失**：`needsConfirmQuit`、`processExited`、`SHOW_CHILD_EXITED`、`COMMAND_FINISHED`
- **表现**：关窗口不会提示"shell 还在跑"；子进程退出后没有状态提示
- **参考**：官方壳 L148-L157、`ChildExitedMessage.swift`
- **实现**：surface 增加 `needsConfirmQuit` 计算属性（查 `ghostty_surface_needs_confirm_quit`）；window close delegate 检查；接 `SHOW_CHILD_EXITED` 在 pane header 显示退出状态

### 3. 剪贴板 / 编辑菜单 IBAction
- **缺失**：`copy`、`paste`、`pasteAsPlainText`、`pasteSelection`、`selectAll`（共 5 个）
- **表现**：右键菜单和 Edit 菜单的复制/粘贴/全选不响应（快捷键走 core keybind 正常）
- **参考**：官方壳 L1641-L1676，都是一行 `ghostty_surface_binding_action` 调用
- **实现**：在 TerminalSurfaceView 加 5 个 `@IBAction` / `@objc` 方法

### 4. 右键上下文菜单
- **缺失**：整个 `menu(for:)` override
- **表现**：右键终端没有菜单弹出
- **参考**：官方壳 L1585-L1637（动态构建菜单：Copy/Paste/Split/Reset 等）
- **实现**：override `menu(for:)` 照搬

### 5. 密码输入安全 (SecureInput)
- **缺失**：`SECURE_INPUT` action、`passwordInput` 属性、`SecureInput` 管理器
- **表现**：终端进入密码模式时不会阻止其他 app 通过 accessibility API 读取按键
- **参考**：官方壳 L133-L147、`SecureInput` 单独文件
- **实现**：接 `SECURE_INPUT` action → 设 surface 的 passwordInput → 调 `EnableSecureEventInput` / `DisableSecureEventInput`

---

## P1：日常高频功能

### 6. 文件/文本拖入终端
- **缺失**：`draggingEntered`、`performDragOperation`（surface 级，非 pane 间拖拽）
- **表现**：从 Finder 拖文件到终端不会粘贴路径
- **参考**：官方壳 L2279-L2319、`registerForDraggedTypes`（L401）
- **实现**：注册 `fileURL` 和 `string` 拖拽类型，drop 时调 `ghostty_surface_text` 发送路径

### 7. 搜索菜单入口 (find IBAction)
- **缺失**：`find`、`findNext`、`findPrevious`、`findHide`、`selectionForFind`、`scrollToSelection`（共 6 个）
- **表现**：Edit → Find 菜单项不响应（快捷键走 core 正常，TerminalSearchBar 已实现）
- **参考**：官方壳 L1681-L1717，均为一行 `ghostty_surface_binding_action` 调用
- **实现**：在 TerminalSurfaceView 加 6 个 IBAction

### 8. Split 菜单入口
- **缺失**：`splitRight`、`splitLeft`、`splitDown`、`splitUp`（4 个 IBAction）
- **表现**：菜单栏点 split 不响应（快捷键走 core 正常）
- **参考**：官方壳 L1729-L1748
- **实现**：4 个 IBAction，各调 `ghostty_surface_binding_action(surface, "new_split:...")`

### 9. 菜单项校验 (NSMenuItemValidation)
- **缺失**：`validateMenuItem`
- **表现**：菜单项不会根据状态自动灰掉（如无选中文本时 Copy 应灰）
- **参考**：官方壳 L2248-L2275
- **实现**：extension 实现 NSMenuItemValidation，按 selector 判断启用/禁用

### 10. 标题变更
- **缺失**：`SET_TITLE`、`SET_TAB_TITLE`、`COPY_TITLE_TO_CLIPBOARD` action（同 P0.1）
- **实现**：随 P0.1 一并完成

---

## P2：体验完善

### 11. 桌面通知
- **缺失**：`DESKTOP_NOTIFICATION` action、`showUserNotification`、`handleUserNotification`
- **表现**：终端程序触发的 OSC 通知不会弹出 macOS 通知
- **参考**：官方壳 L1770-L1845（`UNMutableNotificationContent`）
- **实现**：接 action → 构建 UNNotificationRequest → 发送；需要 app 注册通知权限

### 12. 进度条
- **缺失**：`PROGRESS_REPORT` action
- **表现**：shell integration 的进度汇报（如 `curl` 下载）不会显示在标题或 dock 图标
- **参考**：官方壳 L23-L35（progressReportTimer 自动清零）
- **实现**：接 action → 存到 surface 属性 → pane header 或 dock badge 显示

### 13. 终端功能菜单项
- **缺失**：`resetTerminal`、`toggleReadonly`、`changeTitle`
- **参考**：官方壳 L1721-L1768
- **实现**：3 个 @objc 方法，各调 `ghostty_surface_binding_action`

### 14. 背景色 / 配置热变更
- **缺失**：`COLOR_CHANGE`、`CONFIG_CHANGE` action
- **表现**：终端 OSC 改背景色不会同步到窗口 chrome；`reload_config` 后 surface 以外的 UI 不更新
- **参考**：官方壳对应 action handler
- **实现**：接两个 action → 刷新 pane header / window 的 chrome 配色

### 15. 滚动条
- **缺失**：`SCROLLBAR` action
- **表现**：scrollback 没有滚动条指示
- **参考**：官方壳 `SurfaceScrollView.swift`
- **实现**：可后期做，core 只报位置/高度，UI 层面可选择显示方式

---

## P3：完整对齐

### 16. Accessibility (VoiceOver)
- **缺失**：`isAccessibilityElement`、`accessibilityRole`、`accessibilityValue`、`accessibilitySelectedText`、`accessibilityNumberOfCharacters`、`accessibilityVisibleCharacterRange`、`accessibilityLine`、`accessibilityString`、`accessibilityAttributedString`（共 9 个 override）、`SELECTION_CHANGED` action
- **参考**：官方壳 L2322-L2420
- **实现**：extension 实现整套 accessibility override；接 SELECTION_CHANGED 发 accessibility notification

### 17. Services 菜单
- **缺失**：`NSServicesMenuRequestor`、`validRequestor`、`writeSelection`、`readSelection`
- **表现**：右键 → 服务 不工作
- **参考**：官方壳 L2174-L2247
- **实现**：extension 照搬

### 18. Inspector（调试面板）
- **缺失**：`INSPECTOR`、`RENDER_INSPECTOR` action
- **表现**：Ghostty 的内置终端调试器不可用
- **参考**：官方壳 `InspectorView.swift` + action handler
- **实现**：视需要，lightty 有自己的 DebugRulerView，可后期对接

### 19. 剩余 action 补齐
- `MOVE_TAB` — tab 重排序
- `FLOAT_WINDOW` — 浮动窗口
- `TOGGLE_QUICK_TERMINAL` — 快速终端（下拉式）
- `TOGGLE_BACKGROUND_OPACITY` — 切换背景透明度
- `KEY_SEQUENCE` / `KEY_TABLE` — 按键序列提示
- `RENDERER_HEALTH` — 渲染器健康检查
- `RESET_WINDOW_SIZE` — 重置窗口大小
- `EXPORT_TERMINAL_IO` — 导出终端 IO
- `CHECK_FOR_UPDATES` — 检查更新（lightty 不需要）
- `READONLY` — 只读模式 toggle
- `MOUSE_OVER_LINK` — 链接 hover 光标
- `COPY_TITLE_TO_CLIPBOARD` — 复制标题到剪贴板

---

## 实施顺序建议

```
Phase 1（核心可用）: P0.1 → P0.2 → P0.3 → P0.4 → P0.5
Phase 2（日常完整）: P1.6 → P1.7 → P1.8 → P1.9
Phase 3（体验完善）: P2.11 → P2.12 → P2.13 → P2.14
Phase 4（完整对齐）: P3.16 → P3.17 → P3.19（按需取舍）
```

每个 Phase 完成后跑 `scripts/check-terminal-adapter-parity.sh`（需更新脚本增加新检查项）。

## 代码来源

所有实现直接参考 vendor 内的官方源码，MIT 许可。关键文件：
- `vendor/ghostty/macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`
- `vendor/ghostty/macos/Sources/Ghostty/Ghostty.App.swift`
- `vendor/ghostty/macos/Sources/Ghostty/Ghostty.Action.swift`
