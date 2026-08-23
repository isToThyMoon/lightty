import AppKit
import GhosttyKit

/// 承载一个 ghostty surface 的 NSView。
/// 硬约束（docs/libghostty-embedding.md）：不设 wantsLayer、不建自己的 layer，
/// surface_new 内部会把 IOSurfaceLayer 塞进来并转 layer-hosting；壳侧动 layer 会踢掉它。
final class TerminalSurfaceView: NSView {
    private(set) var surface: ghostty_surface_t?
    /// close_surface 回调（进程退出）时由 runtime 调用
    var onCloseRequest: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, surface == nil else { return }
        createSurface()
    }

    private func createSurface() {
        guard let window else { return }
        // 默认值必须来自 config_new()，勿 memset 0
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = window.backingScaleFactor

        // cwd 固定家目录（HANDOVER 8.2：不自动启动 agent）
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        surface = home.withCString { homePtr -> ghostty_surface_t? in
            cfg.working_directory = homePtr
            return ghostty_surface_new(GhosttyRuntime.shared.app, &cfg)
        }
        updateSurfaceSize()
    }

    deinit {
        if let surface { ghostty_surface_free(surface) }
    }

    func requestClose() {
        onCloseRequest?()
    }

    /// 向 PTY 注入文本（粘贴路径）。「收工」「注入」与恢复预填充都走这里。
    func sendText(_ text: String) {
        guard let surface else { return }
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            base.withMemoryRebound(to: CChar.self, capacity: buf.count) {
                ghostty_surface_text(surface, $0, UInt(buf.count))
            }
        }
    }

    // MARK: - 尺寸与缩放（backing 像素，不是 point）

    private func updateSurfaceSize() {
        guard let surface else { return }
        let backing = convertToBacking(bounds)
        ghostty_surface_set_size(surface, UInt32(max(backing.width, 1)), UInt32(max(backing.height, 1)))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface, let window else { return }
        let scale = window.backingScaleFactor
        ghostty_surface_set_content_scale(surface, scale, scale)
        updateSurfaceSize()
    }

    // MARK: - 焦点

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let surface {
            ghostty_surface_set_focus(surface, true)
            onFocusChange?(true)
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok, let surface {
            ghostty_surface_set_focus(surface, false)
            onFocusChange?(false)
        }
        return ok
    }

    // MARK: - 键盘（IME/修饰键为已知欠账，见 HANDOVER 第 10 节）

    override func keyDown(with event: NSEvent) {
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        _ = keyAction(action, event: event)
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    /// cmd 组合键先于 keyDown 走这里；凡 core 认领的 keybind
    /// （用户 config + ghostty 默认，如 cmd+D/cmd+T/cmd+[]）直接转发，
    /// 不让 AppKit 菜单/系统吃掉。壳层菜单只保留 lightty 拓展键。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              window?.isKeyWindow == true,
              window?.firstResponder === self,
              let surface else { return false }

        var keyEvent = makeKeyEvent(GHOSTTY_ACTION_PRESS, event: event)
        var bindingFlags = ghostty_binding_flags_e(rawValue: 0)
        let isBinding = (event.characters ?? "").withCString { ptr -> Bool in
            keyEvent.text = ptr
            return ghostty_surface_key_is_binding(surface, keyEvent, &bindingFlags)
        }
        guard isBinding else { return false }
        keyDown(with: event)
        return true
    }

    private func makeKeyEvent(_ action: ghostty_input_action_e, event: NSEvent) -> ghostty_input_key_s {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = Self.ghosttyMods(event.modifierFlags)
        // 官方启发式：control/command 从不参与文本翻译
        keyEvent.consumed_mods = Self.ghosttyMods(
            event.modifierFlags.subtracting([.control, .command]))
        keyEvent.composing = false
        keyEvent.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp,
           let chars = event.characters(byApplyingModifiers: []),
           let cp = chars.unicodeScalars.first {
            keyEvent.unshifted_codepoint = cp.value
        }
        return keyEvent
    }

    private func keyAction(_ action: ghostty_input_action_e, event: NSEvent) -> Bool {
        guard let surface else { return false }
        var keyEvent = makeKeyEvent(action, event: event)

        // 控制字符不进 text：物理键 + 修饰键交给 core 自己编码
        let text = event.characters ?? ""
        if !text.isEmpty, let first = text.unicodeScalars.first,
           first.value >= 0x20, first.value != 0x7F {
            return text.withCString { ptr in
                keyEvent.text = ptr
                return ghostty_surface_key(surface, keyEvent)
            }
        }
        return ghostty_surface_key(surface, keyEvent)
    }

    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    // MARK: - 鼠标（坐标 Y 翻转：ghostty 用左上原点）

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseDown(with event: NSEvent) {
        // 点击即聚焦该 pane
        window?.makeFirstResponder(self)
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, Self.ghosttyMods(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, Self.ghosttyMods(event.modifierFlags))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return super.rightMouseDown(with: event) }
        if !ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, Self.ghosttyMods(event.modifierFlags)) {
            super.rightMouseDown(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return super.rightMouseUp(with: event) }
        if !ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, Self.ghosttyMods(event.modifierFlags)) {
            super.rightMouseUp(with: event)
        }
    }

    private func sendMousePos(_ event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(
            surface, pos.x, frame.height - pos.y, Self.ghosttyMods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) { sendMousePos(event) }
    override func mouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func mouseEntered(with event: NSEvent) { sendMousePos(event) }

    override func mouseExited(with event: NSEvent) {
        guard let surface else { return }
        if NSEvent.pressedMouseButtons != 0 { return }
        // exited 发 (-1,-1)
        ghostty_surface_mouse_pos(surface, -1, -1, Self.ghosttyMods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas
        if precision {
            // 官方壳同款 2x 手感系数
            x *= 2
            y *= 2
        }
        // bit0 = precision，bits1-3 = momentum（与 ghostty_input_mouse_momentum_e 对应）
        var scrollMods: Int32 = precision ? 1 : 0
        scrollMods |= Int32(Self.momentumValue(event.momentumPhase)) << 1
        ghostty_surface_mouse_scroll(surface, x, y, scrollMods)
    }

    private static func momentumValue(_ phase: NSEvent.Phase) -> UInt8 {
        switch phase {
        case .began: return 1
        case .stationary: return 2
        case .changed: return 3
        case .ended: return 4
        case .cancelled: return 5
        case .mayBegin: return 6
        default: return 0
        }
    }
}
