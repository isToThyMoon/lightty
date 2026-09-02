import AppKit
import Carbon
import CoreText
import GhosttyKit

extension Notification.Name {
    static let terminalTitleDidChange = Notification.Name("terminalTitleDidChange")
}

/// 由 libghostty 产生、壳层只负责保活到下一个 surface_new 的启动参数。
/// 快捷键触发 new_window/new_tab/new_split 时，必须用
/// `ghostty_surface_inherited_config`，不得在 lightty 里自己猜 cwd/font。
struct TerminalSurfaceConfiguration {
    var fontSize: Float32 = 0
    var workingDirectory: String?
    var context: ghostty_surface_context_e = GHOSTTY_SURFACE_CONTEXT_WINDOW
    /// 注入给该 pane shell 的环境变量（当前只用于 LIGHTTY_PANE_ID）。
    ///
    /// 走 per-surface 注入而不是改进程环境：一是每个 pane 需要不同的值，进程级
    /// 变量做不到；二是 main.swift 刻意净化过继承来的会话标记，壳层不该再往
    /// 全局环境里塞东西。`inheriting` 初始化器不复制本字段——新 pane 必须拿到
    /// 属于自己的 id，继承反而是错的。
    var envVars: [String: String] = [:]

    init() {}

    init(inheriting surface: ghostty_surface_t, context: ghostty_surface_context_e) {
        let inherited = ghostty_surface_inherited_config(surface, context)
        fontSize = inherited.font_size
        if let directory = inherited.working_directory {
            workingDirectory = String(cString: directory)
        }
        self.context = inherited.context
    }

    func withCValue<T>(
        view: TerminalSurfaceView,
        scale: CGFloat,
        _ body: (inout ghostty_surface_config_s) -> T
    ) -> T {
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(view).toOpaque()))
        config.userdata = Unmanaged.passUnretained(view).toOpaque()
        config.scale_factor = scale
        config.font_size = fontSize
        config.context = context

        // 传给 core 的 C 字符串统一在这里申请、在 body 返回后统一释放。
        // libghostty 会把 working_directory 与 env 键值 dupeZ 进自己的 arena
        // （vendor/ghostty/src/apprt/embedded.zig 的 env_var_count 分支），
        // 所以它们只需活过 ghostty_surface_new 这一次调用，之后释放是安全的。
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }
        func borrow(_ string: String) -> UnsafePointer<CChar>? {
            guard let copy = strdup(string) else { return nil }
            owned.append(copy)
            return UnsafePointer(copy)
        }

        if let workingDirectory { config.working_directory = borrow(workingDirectory) }

        var pairs = envVars.map {
            ghostty_env_var_s(key: borrow($0.key), value: borrow($0.value))
        }
        return pairs.withUnsafeMutableBufferPointer { buffer in
            // 空数组时 baseAddress 可能为 nil，core 侧以 count > 0 为门槛，安全。
            config.env_vars = buffer.baseAddress
            config.env_var_count = buffer.count
            return body(&config)
        }
    }
}

/// AppKit ↔ libghostty 的单一 surface adapter。
///
/// 这个类只把原生事件和宿主状态翻译给 libghostty；它不定义快捷键、
/// 不解析 terminal config，也不修改 surface 的工作目录。输入语义直接对齐：
/// `vendor/ghostty/macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`。
///
/// 渲染硬约束：不设 wantsLayer、不建自己的 layer。`ghostty_surface_new`
/// 会安装 IOSurfaceLayer 并把视图变成 layer-hosting，壳层不能踢掉它。
final class TerminalSurfaceView: NSView {
    private(set) var surface: ghostty_surface_t?
    /// close_surface 回调（进程退出）时由 runtime 调用。
    var onCloseRequest: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    private var trackingArea: NSTrackingArea?
    private var eventMonitor: Any?
    private var observingWindow = false
    private var suppressNextLeftMouseUp = false
    private var previousPressureStage = 0

    // NSTextInputClient / IME state. The accumulator differentiates text committed by
    // interpretKeyEvents during a hardware key event from external committed text.
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var leadSurrogate: TerminalLeadSurrogate?
    private var lastPerformKeyEvent: TimeInterval?

    /// libghostty 通过 GHOSTTY_ACTION_CELL_SIZE 给宿主的 backing-pixel 尺寸。
    /// 这里转成 point，仅供 IME candidate window 定位。
    private(set) var cellSize: NSSize = .zero

    private var terminalCursor = NSCursor.arrow
    private let launchConfiguration: TerminalSurfaceConfiguration

    override var acceptsFirstResponder: Bool { true }

    init(configuration: TerminalSurfaceConfiguration = .init()) {
        launchConfiguration = configuration
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        installWindowBridgeIfNeeded()
        if surface == nil { createSurface() }
        updateDisplayAndOcclusion()
    }

    private func createSurface() {
        guard let window else { return }

        // 必须从 libghostty 的 default constructor 开始。默认 surface 不覆盖 cwd；
        // 由 core 请求的新 surface 仅使用 core 返回的 inherited config。
        surface = launchConfiguration.withCValue(
            view: self,
            scale: window.backingScaleFactor
        ) { config in
            ghostty_surface_new(GhosttyRuntime.shared.app, &config)
        }

        updateContentScale()
        updateSurfaceSize()
        updateDisplayAndOcclusion()
        updateColorScheme()
        registerDropTypes()
    }

    /// 官方 BaseTerminalController.updateColorSchemeForSurfaceTree 的单 surface 版：
    /// 系统明暗切换时上报给 core，`theme = light:X,dark:Y` 才会跟随。
    private func updateColorScheme() {
        guard let surface else { return }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ghostty_surface_set_color_scheme(
            surface,
            dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColorScheme()
    }

    private func installWindowBridgeIfNeeded() {
        if eventMonitor == nil {
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyUp, .leftMouseDown, .leftMouseUp]
            ) { [weak self] event in
                self?.handleLocalEvent(event) ?? event
            }
        }

        guard !observingWindow else { return }
        observingWindow = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidChangeScreen(_:)),
            name: NSWindow.didChangeScreenNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidChangeOcclusion(_:)),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: nil)
    }

    deinit {
        if passwordInput { DisableSecureEventInput() }
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        NotificationCenter.default.removeObserver(self)
        if let surface { ghostty_surface_free(surface) }
    }

    func requestClose() {
        onCloseRequest?()
    }

    /// 用户主动关闭（header ✕）：交给内核的 close 流程（与 cmd+W 的
    /// close_surface keybind 同路），最终经 close_surface_cb 回到壳层。
    func requestCloseFromUser() {
        guard let surface else { return }
        ghostty_surface_request_close(surface)
    }

    /// 壳层明确请求向 PTY 注入文本的边界（「收工」/「注入」）。
    /// 这不参与键盘事件或快捷键配置。
    func sendText(_ text: String) {
        guard let surface else { return }
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            base.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                ghostty_surface_text(surface, $0, UInt(buffer.count))
            }
        }
    }

    /// 宿主 UI 把用户操作表达为 Ghostty action 的唯一入口。
    /// action 的解析和行为仍在 core，这不是 lightty 的快捷键配置。
    @discardableResult
    func performBindingAction(_ action: String) -> Bool {
        guard let surface else { return false }
        return action.withCString { pointer in
            ghostty_surface_binding_action(surface, pointer, UInt(action.utf8.count))
        }
    }

    func setCellSize(backingWidth: UInt32, backingHeight: UInt32) {
        cellSize = convertFromBacking(NSSize(
            width: CGFloat(backingWidth),
            height: CGFloat(backingHeight)))
    }

    // MARK: - 尺寸、缩放、屏幕与遮挡

    private func updateSurfaceSize() {
        guard let surface else { return }
        let backing = convertToBacking(bounds)
        ghostty_surface_set_size(
            surface,
            UInt32(max(backing.width, 1)),
            UInt32(max(backing.height, 1)))

        if ProcessInfo.processInfo.environment["LIGHTTY_DEBUG_LAYOUT"] != nil {
            let size = ghostty_surface_size(surface)
            NSLog(
                "set_size %.0fx%.0f px | grid %dx%d, grid_px %dx%d, cell %dx%d | leftover_y_px %.0f",
                backing.width, backing.height,
                size.columns, size.rows, size.width_px, size.height_px,
                size.cell_width_px, size.cell_height_px,
                backing.height - CGFloat(UInt32(size.rows) * size.cell_height_px))
        }
    }

    private func updateContentScale() {
        guard let surface, frame.width > 0, frame.height > 0 else { return }
        let backingFrame = convertToBacking(frame)
        ghostty_surface_set_content_scale(
            surface,
            backingFrame.width / frame.width,
            backingFrame.height / frame.height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    // Auto Layout 的最终尺寸在 layout 落地；只监听 setFrameSize 会漏。
    override func layout() {
        super.layout()
        updateSurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentScale()
        updateSurfaceSize()
    }

    @objc private func windowDidChangeScreen(_ notification: Notification) {
        guard notification.object as AnyObject? === window else { return }
        updateDisplayAndOcclusion()
        // 换屏可能同时换 scale。下一轮主队列再取 AppKit 稳定后的值。
        DispatchQueue.main.async { [weak self] in
            self?.updateContentScale()
            self?.updateSurfaceSize()
        }
    }

    @objc private func windowDidChangeOcclusion(_ notification: Notification) {
        guard notification.object as AnyObject? === window else { return }
        updateDisplayAndOcclusion()
    }

    func setPromptClearOnResize(_ clear: Bool) {
        guard let surface else { return }
        ghostty_surface_set_prompt_clear_on_resize(surface, clear)
    }

    private func updateDisplayAndOcclusion() {
        guard let surface, let window else { return }
        if let number = window.screen?.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber {
            ghostty_surface_set_display_id(surface, number.uint32Value)
        }
        // 后台 tab（隐藏容器里的 pane）视为被遮挡：渲染线程降级不画帧。
        ghostty_surface_set_occlusion(
            surface,
            window.occlusionState.contains(.visible) && !isHiddenOrHasHiddenAncestor)
    }

    // tab 切换用 isHidden 翻转容器；AppKit 会向下广播 hide/unhide。
    override func viewDidHide() {
        super.viewDidHide()
        updateDisplayAndOcclusion()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateDisplayAndOcclusion()
    }

    // MARK: - 焦点与 AppKit 局部事件

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let surface {
            ghostty_surface_set_focus(surface, true)
            onFocusChange?(true)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result, let surface {
            suppressNextLeftMouseUp = false
            ghostty_surface_set_focus(surface, false)
            onFocusChange?(false)
        }
        return result
    }

    private func handleLocalEvent(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyUp:
            return handleLocalKeyUp(event)
        case .leftMouseDown:
            return handleLocalLeftMouseDown(event)
        case .leftMouseUp:
            guard suppressNextLeftMouseUp else { return event }
            suppressNextLeftMouseUp = false
            return nil
        default:
            return event
        }
    }

    /// AppKit 不会把 Command 组合的 keyUp 送入普通 responder chain。
    private func handleLocalKeyUp(_ event: NSEvent) -> NSEvent? {
        guard event.modifierFlags.contains(.command),
              window?.firstResponder === self else { return event }
        keyUp(with: event)
        return nil
    }

    /// 已激活窗口内切换 pane 焦点时，第一下点击只负责聚焦。
    /// 官方壳会同时吞掉配对的 mouseUp，避免 PTY 收到无 press 的 release。
    private func handleLocalLeftMouseDown(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window,
              let contentView = window.contentView else { return event }
        let location = contentView.convert(event.locationInWindow, from: nil)
        guard contentView.hitTest(location) === self else { return event }

        suppressNextLeftMouseUp = false
        guard window.firstResponder !== self else { return event }

        if NSApp.isActive && window.isKeyWindow {
            window.makeFirstResponder(self)
            suppressNextLeftMouseUp = true
            return nil
        }

        window.makeFirstResponder(self)
        return event
    }

    // MARK: - 键盘（直接对齐 Ghostty SurfaceView_AppKit）

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }

        // option-as-alt 等翻译完全由 core config 决定。
        let translatedGhosttyMods = ghostty_surface_key_translation_mods(
            surface,
            Self.ghosttyMods(event.modifierFlags))
        let translatedIndependentFlags = Self.eventModifierFlags(translatedGhosttyMods)

        // 保留 NSEvent 中对 dead key / IME 有意义的隐藏 bits，只替换四个主修饰键。
        var translationFlags = event.modifierFlags
        for flag in [
            NSEvent.ModifierFlags.shift,
            .control,
            .option,
            .command,
        ] {
            if translatedIndependentFlags.contains(flag) {
                translationFlags.insert(flag)
            } else {
                translationFlags.remove(flag)
            }
        }

        // 修饰键没变时必须复用原 event；重建对象会破坏韩文 IME。
        let translationEvent: NSEvent
        if translationFlags == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationFlags,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationFlags) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let hadMarkedText = markedText.length > 0
        let keyboardIDBefore = hadMarkedText ? nil : TerminalKeyboardLayout.id
        lastPerformKeyEvent = nil
        interpretKeyEvents([translationEvent])

        // 切换输入法的那个物理键不应进入 terminal。
        if !hadMarkedText && keyboardIDBefore != TerminalKeyboardLayout.id { return }

        syncPreedit(clearIfNeeded: hadMarkedText)
        let composing = markedText.length > 0 || hadMarkedText

        // IME 可能在处理物理键时提交 preedit。先发提交文本，再仅重放
        // 依然应该影响 terminal 的方向键。
        if hadMarkedText, let accumulated = keyTextAccumulator, !accumulated.isEmpty {
            for text in accumulated where !Self.shouldSuppressComposingControlInput(
                text,
                composing: composing) {
                _ = committedTextAction(action, text: text)
            }
            if shouldReplayCommittedPreeditKey(translationEvent) {
                _ = keyAction(
                    action,
                    event: event,
                    translationEvent: translationEvent,
                    composing: false)
            }
            return
        }

        if let accumulated = keyTextAccumulator, !accumulated.isEmpty {
            for text in accumulated where !Self.shouldSuppressComposingControlInput(
                text,
                composing: composing) {
                _ = keyAction(
                    action,
                    event: event,
                    translationEvent: translationEvent,
                    text: text)
            }
        } else {
            guard !Self.shouldSuppressComposingControlInput(
                event.characters,
                composing: composing) else { return }
            _ = keyAction(
                action,
                event: event,
                translationEvent: translationEvent,
                text: translationEvent.terminalGhosttyCharacters,
                composing: composing)
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    /// Command/control 组合会先走 AppKit key-equivalent 路径。只问 core 这是否是
    /// binding；如果是，就交回同一条 keyDown 管线。壳层不拥有键位表。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return false }
        return routeKeyEquivalentFromShell(event)
    }

    /// 供官方宿主型 overlay（如 terminal search）在自己未消费键时调用。
    /// 它仍然只查询 core 的 binding table，不接受壳层 key map。
    func routeKeyEquivalentFromShell(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let surface else { return false }

        var coreEvent = makeKeyEvent(GHOSTTY_ACTION_PRESS, event: event)
        var bindingFlags = ghostty_binding_flags_e(rawValue: 0)
        let isBinding = (event.characters ?? "").withCString { pointer in
            coreEvent.text = pointer
            return ghostty_surface_key_is_binding(surface, coreEvent, &bindingFlags)
        }
        if isBinding {
            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"

        case "/":
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else {
                return false
            }
            // 对齐官方：C-/ 按 C-_ 编码，同时避免 AppKit beep。
            equivalent = "_"

        default:
            guard event.timestamp != 0 else { return false }
            guard event.modifierFlags.contains(.command) ||
                    event.modifierFlags.contains(.control) else {
                lastPerformKeyEvent = nil
                return false
            }

            if let previous = lastPerformKeyEvent {
                lastPerformKeyEvent = nil
                if previous == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }

            lastPerformKeyEvent = event.timestamp
            return false
        }

        guard let redispatched = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode) else { return false }
        keyDown(with: redispatched)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        let changedModifier: UInt32
        switch event.keyCode {
        case 0x39: changedModifier = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: changedModifier = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: changedModifier = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: changedModifier = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: changedModifier = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }

        // 预编辑期的 modifier 属于 IME，不送 terminal。
        if hasMarkedText() { return }

        let modifiers = Self.ghosttyMods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if modifiers.rawValue & changedModifier != 0 {
            let correctSideIsPressed: Bool
            switch event.keyCode {
            case 0x3C:
                correctSideIsPressed = event.modifierFlags.rawValue &
                    UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E:
                correctSideIsPressed = event.modifierFlags.rawValue &
                    UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D:
                correctSideIsPressed = event.modifierFlags.rawValue &
                    UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36:
                correctSideIsPressed = event.modifierFlags.rawValue &
                    UInt(NX_DEVICERCMDKEYMASK) != 0
            default:
                correctSideIsPressed = true
            }
            if correctSideIsPressed { action = GHOSTTY_ACTION_PRESS }
        }
        _ = keyAction(action, event: event)
    }

    private func makeKeyEvent(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationFlags: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.text = nil
        keyEvent.composing = false
        keyEvent.mods = Self.ghosttyMods(event.modifierFlags)
        keyEvent.consumed_mods = Self.ghosttyMods(
            (translationFlags ?? event.modifierFlags)
                .subtracting([.control, .command]))
        keyEvent.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp,
           let characters = event.characters(byApplyingModifiers: []),
           let codepoint = characters.unicodeScalars.first {
            keyEvent.unshifted_codepoint = codepoint.value
        }
        return keyEvent
    }

    private func keyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }
        var keyEvent = makeKeyEvent(
            action,
            event: event,
            translationFlags: translationEvent?.modifierFlags)
        keyEvent.composing = composing

        // C0 control 字符由 core 编码，这样 Kitty keyboard protocol 仍能看到
        // 物理键和 modifiers。
        if let text, !text.isEmpty, !text.startsWithASCIIControlCharacter {
            return text.withCString { pointer in
                keyEvent.text = pointer
                return ghostty_surface_key(surface, keyEvent)
            }
        }
        return ghostty_surface_key(surface, keyEvent)
    }

    private func committedTextAction(
        _ action: ghostty_input_action_e,
        text: String
    ) -> Bool {
        guard let surface else { return false }
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = 0
        keyEvent.text = nil
        keyEvent.composing = false
        keyEvent.mods = GHOSTTY_MODS_NONE
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.unshifted_codepoint = 0
        return text.withCString { pointer in
            keyEvent.text = pointer
            return ghostty_surface_key(surface, keyEvent)
        }
    }

    private func shouldReplayCommittedPreeditKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 0x7D, 0x7C, 0x7E: // down, right, up
            return true
        case 0x7B: // left
            return !event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command])
        default:
            return false
        }
    }

    private static func shouldSuppressComposingControlInput(
        _ text: String?,
        composing: Bool
    ) -> Bool {
        guard composing, let text else { return false }
        let scalars = text.unicodeScalars
        guard let first = scalars.first,
              scalars.index(after: scalars.startIndex) == scalars.endIndex else {
            return false
        }
        return first.value < 0x20
    }

    static func eventModifierFlags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var modifiers = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { modifiers |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { modifiers |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { modifiers |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { modifiers |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { modifiers |= GHOSTTY_MODS_CAPS.rawValue }

        // Ghostty 的 keybind 支持左右修饰键，AppKit 的公开 flags 只给聚合位，
        // 右侧信息在 device-dependent bits 中。
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 {
            modifiers |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue
        }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 {
            modifiers |= GHOSTTY_MODS_CTRL_RIGHT.rawValue
        }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 {
            modifiers |= GHOSTTY_MODS_ALT_RIGHT.rawValue
        }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 {
            modifiers |= GHOSTTY_MODS_SUPER_RIGHT.rawValue
        }
        return ghostty_input_mods_e(rawValue: modifiers)
    }

    // MARK: - 鼠标（Ghostty 坐标原点在左上）

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

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: terminalCursor)
    }

    func setCursorShape(_ shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT: terminalCursor = .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER: terminalCursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: terminalCursor = .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB: terminalCursor = .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: terminalCursor = .closedHand
        case GHOSTTY_MOUSE_SHAPE_E_RESIZE,
             GHOSTTY_MOUSE_SHAPE_W_RESIZE,
             GHOSTTY_MOUSE_SHAPE_EW_RESIZE,
             GHOSTTY_MOUSE_SHAPE_COL_RESIZE:
            terminalCursor = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_N_RESIZE,
             GHOSTTY_MOUSE_SHAPE_S_RESIZE,
             GHOSTTY_MOUSE_SHAPE_NS_RESIZE,
             GHOSTTY_MOUSE_SHAPE_ROW_RESIZE:
            terminalCursor = .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP:
            terminalCursor = .operationNotAllowed
        default:
            terminalCursor = .arrow
        }
        window?.invalidateCursorRects(for: self)
    }

    func setCursorVisibility(_ visible: Bool) {
        NSCursor.setHiddenUntilMouseMoves(!visible)
    }

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(
            surface,
            GHOSTTY_MOUSE_PRESS,
            GHOSTTY_MOUSE_LEFT,
            Self.ghosttyMods(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        if suppressNextLeftMouseUp {
            suppressNextLeftMouseUp = false
            return
        }
        previousPressureStage = 0
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(
            surface,
            GHOSTTY_MOUSE_RELEASE,
            GHOSTTY_MOUSE_LEFT,
            Self.ghosttyMods(event.modifierFlags))
        ghostty_surface_mouse_pressure(surface, 0, 0)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return super.rightMouseDown(with: event) }
        if !ghostty_surface_mouse_button(
            surface,
            GHOSTTY_MOUSE_PRESS,
            GHOSTTY_MOUSE_RIGHT,
            Self.ghosttyMods(event.modifierFlags)) {
            super.rightMouseDown(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return super.rightMouseUp(with: event) }
        if !ghostty_surface_mouse_button(
            surface,
            GHOSTTY_MOUSE_RELEASE,
            GHOSTTY_MOUSE_RIGHT,
            Self.ghosttyMods(event.modifierFlags)) {
            super.rightMouseUp(with: event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(
            surface,
            GHOSTTY_MOUSE_PRESS,
            Self.ghosttyMouseButton(event.buttonNumber),
            Self.ghosttyMods(event.modifierFlags))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(
            surface,
            GHOSTTY_MOUSE_RELEASE,
            Self.ghosttyMouseButton(event.buttonNumber),
            Self.ghosttyMods(event.modifierFlags))
    }

    override func pressureChange(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
        previousPressureStage = event.stage
    }

    private func sendMousePosition(_ event: NSEvent) {
        guard let surface else { return }
        let position = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(
            surface,
            position.x,
            frame.height - position.y,
            Self.ghosttyMods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) { sendMousePosition(event) }
    override func mouseDragged(with event: NSEvent) { sendMousePosition(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMousePosition(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMousePosition(event) }
    override func mouseEntered(with event: NSEvent) { sendMousePosition(event) }

    override func mouseExited(with event: NSEvent) {
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        ghostty_surface_mouse_pos(
            surface,
            -1,
            -1,
            Self.ghosttyMods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise {
            // 官方 AppKit 壳的手感系数。
            x *= 2
            y *= 2
        }
        var scrollModifiers: Int32 = precise ? 1 : 0
        scrollModifiers |= Int32(Self.momentumValue(event.momentumPhase)) << 1
        ghostty_surface_mouse_scroll(surface, x, y, scrollModifiers)
    }

    private static func ghosttyMouseButton(_ number: Int) -> ghostty_input_mouse_button_e {
        switch number {
        case 0: return GHOSTTY_MOUSE_LEFT
        case 1: return GHOSTTY_MOUSE_RIGHT
        case 2: return GHOSTTY_MOUSE_MIDDLE
        case 3: return GHOSTTY_MOUSE_EIGHT
        case 4: return GHOSTTY_MOUSE_NINE
        case 5: return GHOSTTY_MOUSE_SIX
        case 6: return GHOSTTY_MOUSE_SEVEN
        case 7: return GHOSTTY_MOUSE_FOUR
        case 8: return GHOSTTY_MOUSE_FIVE
        case 9: return GHOSTTY_MOUSE_TEN
        case 10: return GHOSTTY_MOUSE_ELEVEN
        default: return GHOSTTY_MOUSE_UNKNOWN
        }
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
    // MARK: - 标题与状态

    private(set) var terminalTitle: String = "" {
        didSet {
            guard terminalTitle != oldValue else { return }
            NotificationCenter.default.post(
                name: .terminalTitleDidChange,
                object: self,
                userInfo: ["title": terminalTitle])
        }
    }

    var readonly: Bool = false

    var needsConfirmQuit: Bool {
        guard let surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    var processExited: Bool {
        guard let surface else { return true }
        return ghostty_surface_process_exited(surface)
    }

    func setTitle(_ title: String) {
        terminalTitle = title
    }

    // MARK: - 密码安全输入

    var passwordInput: Bool = false {
        didSet {
            guard passwordInput != oldValue else { return }
            if passwordInput {
                EnableSecureEventInput()
            } else {
                DisableSecureEventInput()
            }
        }
    }

    // MARK: - 剪贴板 / 编辑菜单

    @objc func copy(_ sender: Any?) {
        performBindingAction("copy_to_clipboard")
    }

    @objc func paste(_ sender: Any?) {
        performBindingAction("paste_from_clipboard")
    }

    @objc func pasteAsPlainText(_ sender: Any?) {
        performBindingAction("paste_from_clipboard")
    }

    @objc func pasteSelection(_ sender: Any?) {
        performBindingAction("paste_from_selection")
    }

    @objc override func selectAll(_ sender: Any?) {
        performBindingAction("select_all")
    }

    // MARK: - 搜索菜单入口

    @objc func find(_ sender: Any?) {
        performBindingAction("start_search")
    }

    @objc func selectionForFind(_ sender: Any?) {
        performBindingAction("search_selection")
    }

    @objc func scrollToSelection(_ sender: Any?) {
        performBindingAction("scroll_to_selection")
    }

    @objc func findNext(_ sender: Any?) {
        performBindingAction("search_next")
    }

    @objc func findPrevious(_ sender: Any?) {
        performBindingAction("search_previous")
    }

    @objc func findHide(_ sender: Any?) {
        performBindingAction("end_search")
    }

    // MARK: - Split 菜单入口

    @objc func splitRight(_ sender: Any?) {
        guard let surface else { return }
        ghostty_surface_split(surface, GHOSTTY_SPLIT_DIRECTION_RIGHT)
    }

    @objc func splitLeft(_ sender: Any?) {
        guard let surface else { return }
        ghostty_surface_split(surface, GHOSTTY_SPLIT_DIRECTION_LEFT)
    }

    @objc func splitDown(_ sender: Any?) {
        guard let surface else { return }
        ghostty_surface_split(surface, GHOSTTY_SPLIT_DIRECTION_DOWN)
    }

    @objc func splitUp(_ sender: Any?) {
        guard let surface else { return }
        ghostty_surface_split(surface, GHOSTTY_SPLIT_DIRECTION_UP)
    }

    // MARK: - 终端功能

    @objc func resetTerminal(_ sender: Any?) {
        performBindingAction("reset")
    }

    @objc func toggleTerminalInspector(_ sender: Any?) {
        performBindingAction("inspector:toggle")
    }

    @objc func toggleReadonly(_ sender: Any?) {
        performBindingAction("toggle_readonly")
    }

    // MARK: - 右键上下文菜单

    override func menu(for event: NSEvent) -> NSMenu? {
        guard event.type == .rightMouseDown else { return nil }
        guard let surface else { return nil }

        // 如果终端程序在捕获鼠标，不弹菜单
        if ghostty_surface_mouse_captured(surface) { return nil }

        let menu = NSMenu()
        if let text = accessibilitySelectedText(), !text.isEmpty {
            menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        }
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")

        menu.addItem(.separator())
        menu.addItem(withTitle: "Split Right", action: #selector(splitRight(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Split Left", action: #selector(splitLeft(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Split Down", action: #selector(splitDown(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Split Up", action: #selector(splitUp(_:)), keyEquivalent: "")

        menu.addItem(.separator())
        menu.addItem(withTitle: "Reset Terminal", action: #selector(resetTerminal(_:)), keyEquivalent: "")
        let readonlyItem = menu.addItem(withTitle: "Terminal Read-only", action: #selector(toggleReadonly(_:)), keyEquivalent: "")
        readonlyItem.state = readonly ? .on : .off

        return menu
    }

    // MARK: - 文件拖入终端

    static let dropTypes: Set<NSPasteboard.PasteboardType> = [.string, .fileURL]

    func registerDropTypes() {
        registerForDraggedTypes(Array(Self.dropTypes))
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types else { return [] }
        if Set(types).isDisjoint(with: Self.dropTypes) { return [] }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let content = GhosttyRuntime.opinionatedString(from: pb)
        guard let content else { return false }
        DispatchQueue.main.async {
            self.insertText(content, replacementRange: NSRange(location: 0, length: 0))
        }
        return true
    }
}

// MARK: - NSMenuItemValidation

extension TerminalSurfaceView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            return accessibilitySelectedText().map { !$0.isEmpty } ?? false
        case #selector(pasteSelection(_:)):
            let pb = GhosttyRuntime.selectionPasteboard
            return GhosttyRuntime.opinionatedString(from: pb).map { !$0.isEmpty } ?? false
        case #selector(findHide(_:)):
            return false  // TODO: check search state when tracked
        case #selector(toggleReadonly(_:)):
            item.state = readonly ? .on : .off
            return true
        default:
            return true
        }
    }
}

// MARK: - NSServicesMenuRequestor

extension TerminalSurfaceView: NSServicesMenuRequestor {
    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        let receivable: [NSPasteboard.PasteboardType] = [.string, .init("public.utf8-plain-text")]
        let sendable = receivable

        if (returnType == nil || receivable.contains(returnType!)) &&
           (sendType == nil || sendable.contains(sendType!)) {
            if let sendType, sendable.contains(sendType) {
                if surface == nil || !ghostty_surface_has_selection(surface) {
                    return super.validRequestor(forSendType: sendType, returnType: returnType)
                }
            }
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func writeSelection(
        to pboard: NSPasteboard,
        types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        guard let surface else { return false }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return false }
        defer { ghostty_surface_free_text(surface, &text) }
        pboard.declareTypes([.string], owner: nil)
        pboard.setString(String(cString: text.text), forType: .string)
        return true
    }

    func readSelection(from pboard: NSPasteboard) -> Bool {
        guard let str = GhosttyRuntime.opinionatedString(from: pboard) else { return false }
        let len = str.utf8CString.count
        if len == 0 { return true }
        str.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(len - 1))
        }
        return true
    }
}

// MARK: - Accessibility

extension TerminalSurfaceView {
    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

    override func accessibilityHelp() -> String? { "Terminal content area" }

    override func accessibilityValue() -> Any? {
        guard let surface else { return nil }
        var text = ghostty_text_s()
        let topLeft = ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
            x: 0, y: 0)
        let bottomRight = ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
            x: UInt32.max, y: UInt32.max)
        let sel = ghostty_selection_s(
            top_left: topLeft, bottom_right: bottomRight, rectangle: false)
        guard ghostty_surface_read_text(surface, sel, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        selectedRange()
    }

    override func accessibilitySelectedText() -> String? {
        guard let surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        let str = String(cString: text.text)
        return str.isEmpty ? nil : str
    }

    override func accessibilityNumberOfCharacters() -> Int {
        (accessibilityValue() as? String)?.count ?? 0
    }

    override func accessibilityVisibleCharacterRange() -> NSRange {
        let count = accessibilityNumberOfCharacters()
        return NSRange(location: 0, length: count)
    }

    override func accessibilityLine(for index: Int) -> Int {
        guard let content = accessibilityValue() as? String else { return 0 }
        let substring = String(content.prefix(index))
        return substring.components(separatedBy: .newlines).count - 1
    }

    override func accessibilityString(for range: NSRange) -> String? {
        guard let content = accessibilityValue() as? String,
              let swiftRange = Range(range, in: content) else { return nil }
        return String(content[swiftRange])
    }

    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard let surface else { return nil }
        guard let plainString = accessibilityString(for: range) else { return nil }
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let fontRaw = ghostty_surface_quicklook_font(surface) {
            let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
            attributes[.font] = font.takeUnretainedValue()
            font.release()
        }
        return NSAttributedString(string: plainString, attributes: attributes)
    }
}

// MARK: - NSTextInputClient

extension TerminalSurfaceView: NSTextInputClient {
    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(0...(markedText.length - 1))
    }

    func selectedRange() -> NSRange {
        guard let surface else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        switch string {
        case let value as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: value)
        case let value as String:
            markedText = NSMutableAttributedString(string: value)
        default:
            return
        }

        // 输入法可以在 keyDown 之外更新 preedit（例如 dead key 期间切换布局）。
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        guard range.length > 0, let surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }

        var attributes: [NSAttributedString.Key: Any] = [:]
        if let fontPointer = ghostty_surface_quicklook_font(surface) {
            let font = Unmanaged<CTFont>.fromOpaque(fontPointer)
            attributes[.font] = font.takeUnretainedValue()
            font.release()
        }
        return NSAttributedString(string: String(cString: text.text), attributes: attributes)
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        guard let surface else {
            return NSRect(x: frame.origin.x, y: frame.origin.y, width: 0, height: 0)
        }

        let fallbackCell = effectiveCellSize
        var x = 0.0
        var y = 0.0
        var width = Double(fallbackCell.width)
        var height = Double(fallbackCell.height)

        if range.length > 0 && range != selectedRange() {
            var text = ghostty_text_s()
            if ghostty_surface_read_selection(surface, &text) {
                x = text.tl_px_x - 2
                y = text.tl_px_y + 2
                ghostty_surface_free_text(surface, &text)
            } else {
                ghostty_surface_ime_point(surface, &x, &y, &width, &height)
            }
        } else {
            ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        }

        if range.length == 0, width > 0 {
            width = 0
            x += Double(fallbackCell.width) * Double(range.location + range.length)
        }

        let viewRectangle = NSRect(
            x: x,
            y: frame.height - y,
            width: width,
            height: max(height, Double(fallbackCell.height)))
        let windowRectangle = convert(viewRectangle, to: nil)
        return window?.convertToScreen(windowRectangle) ?? windowRectangle
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }

        let characters: String
        switch string {
        case let value as NSAttributedString:
            characters = value.string
        case let value as NSString:
            if let lead = TerminalLeadSurrogate(value) {
                leadSurrogate = lead
                characters = ""
            } else if let trail = TerminalTrailSurrogate(value) {
                characters = leadSurrogate?.encode(trail: trail) ?? ""
                leadSurrogate = nil
            } else {
                characters = value as String
                leadSurrogate = nil
            }
        default:
            return
        }

        unmarkText()
        if var accumulator = keyTextAccumulator {
            accumulator.append(characters)
            keyTextAccumulator = accumulator
            return
        }
        if !characters.isEmpty {
            _ = committedTextAction(GHOSTTY_ACTION_PRESS, text: characters)
        }
    }

    /// 防止 AppKit 对未实现 selector beep，并完成 Cmd-period 等指令键的
    /// performKeyEquivalent 重分发。
    override func doCommand(by selector: Selector) {
        if let lastPerformKeyEvent,
           let current = NSApp.currentEvent,
           lastPerformKeyEvent == current.timestamp {
            NSApp.sendEvent(current)
        }
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let string = markedText.string
            let length = string.utf8CString.count
            if length > 0 {
                string.withCString { pointer in
                    ghostty_surface_preedit(surface, pointer, UInt(length - 1))
                }
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    private var effectiveCellSize: NSSize {
        if cellSize.width > 0, cellSize.height > 0 { return cellSize }
        guard let surface else { return NSSize(width: 1, height: 1) }
        let size = ghostty_surface_size(surface)
        return convertFromBacking(NSSize(
            width: CGFloat(max(size.cell_width_px, 1)),
            height: CGFloat(max(size.cell_height_px, 1))))
    }
}

private extension NSEvent {
    /// 官方 Ghostty 的文本提取规则：control 字符重做无 control 翻译，
    /// AppKit function-key PUA 不作为文本送入 core。
    var terminalGhosttyCharacters: String? {
        guard let characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700, scalar.value <= 0xF8FF { return nil }
        }
        return characters
    }
}

private extension String {
    var startsWithASCIIControlCharacter: Bool {
        unicodeScalars.first.map { $0.value < 0x20 } ?? false
    }
}

private enum TerminalKeyboardLayout {
    static var id: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return unsafeBitCast(pointer, to: CFString.self) as String
    }
}

private struct TerminalLeadSurrogate {
    let character: UTF16Char

    init?(_ text: NSString) {
        guard text.length == 1 else { return nil }
        let character = text.character(at: 0)
        guard UTF16.isLeadSurrogate(character) else { return nil }
        self.character = character
    }

    func encode(trail: TerminalTrailSurrogate) -> String {
        String(decoding: [character, trail.character], as: UTF16.self)
    }
}

private struct TerminalTrailSurrogate {
    let character: UTF16Char

    init?(_ text: NSString) {
        guard text.length == 1 else { return nil }
        let character = text.character(at: 0)
        guard UTF16.isTrailSurrogate(character) else { return nil }
        self.character = character
    }
}
