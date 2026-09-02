# libghostty 嵌入笔记（lightty 实测 + 官方壳源码提取）

> 依据：vendor/ghostty（main 快照 `5851d98`，1.3.2-dev）的 `include/ghostty.h` 与 `macos/Sources/`；链接清单来自对 GhosttyKit 归档的 `nm -u` 符号差集实测。API 官方声明不稳定，升级 vendor 后须复核。
>
> ⚠️ **勿改钉 v1.3.1 stable**（2026-08-25 实测结论）：v1.3.1 `requireZig` 钉死 Zig 0.15.2，而 0.15.2 无法链接 macOS 26.5 SDK（libSystem TBD 格式过新，hello world 级 `zig cc` 即失败；0.15.x 无后续修复版）。本机可构建的最新 libghostty 就是 1.3.1 之后的 main 线（Zig 0.16 + 新 SDK 兼容）。当前快照含 1.3.1 全部内容 + 后续修复，API 增量：OSC8 枚举、SET_WINDOW_TITLE/SELECTION_CHANGED 等 action、`ghostty_surface_foreground_pid`/`tty_name`。

## 定位

`ghostty.h` 开头即声明这是 **libghostty-internal**，唯一官方消费者是 Ghostty.app；官方 macOS 壳没有私有通道，用的就是这套 C API——它本身就是唯一的嵌入示例（`example/` 全是 libghostty-vt 的，与渲染/PTY 无关）。

## 最小调用序列（spike 已验证）

1. `ghostty_init(argc, argv)` == GHOSTTY_SUCCESS，进程一次，先于一切 ghostty_* 调用
2. `ghostty_config_new` → `ghostty_config_load_default_files`（读 Ghostty 全局配置）→ `ghostty_config_load_recursive_files` → `ghostty_config_finalize`
3. `ghostty_runtime_config_s`：六个回调只有 `close_surface_cb` 可为 NULL；`action_cb`/`read_clipboard_cb` 可恒 return false，终端照样渲染
4. `ghostty_app_new(&rt, config)`（core 内部 clone；host 可立即 free，也可像 lightty 一样只为后续 reload 保留同一份已 finalize config，绝不能叠加 lightty terminal 配置）
5. 非零 frame 的普通 NSView 入窗口层级（见下方硬约束）
6. 首个 surface 用 `ghostty_surface_config_new()` 取默认值（勿 memset 0），只设平台/view/userdata/scale；不覆盖 cwd/font。core 请求 new window/tab/split 时，先用 `ghostty_surface_inherited_config(source, context)` 取得 cwd/font/context，再交给 `ghostty_surface_new`。PTY/渲染线程自动起。

## Terminal 行为所有权（硬约束）

lightty 只有产品壳，没有第二套 terminal keymap、terminal config 或 PTY 行为。物理键必须先进入 surface，由 libghostty 根据全局 Ghostty config（包括默认与用户 keybind）解析；需要 macOS 宿主完成的行为再由 `action_cb` 回到壳层。AppKit 菜单不得设置非空 `keyEquivalent`，标题栏/菜单的 terminal 操作也只能调用 `ghostty_surface_binding_action`，不能绕过 core 直接修改 pane 树。

实现基准是当前 vendored Ghostty 的 `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`、`NSEvent+Extension.swift` 与 `Ghostty.Input.swift`。升级 vendor 后先逐项复核 bridge，再运行本文末尾门禁；不要凭 AppKit 习惯另写一套近似行为。

这里的 parity 指 terminal 输入/配置/PTY 与 lightty 已承载的 core host action；不是把 Ghostty.app 的整套产品壳复制进 lightty。当前 Ghostty.app 专属的 command palette、terminal inspector、quick terminal 尚未嵌入，相关 `action_cb` 明确返回 `false`，且不会被重映射到其他 lightty 行为。若未来要支持，直接按 vendor 的对应 Feature 实现宿主 UI，仍不得另设键位。

## view 层硬约束（最反直觉处）

- **不要**设 `wantsLayer`、不要建 CAMetalLayer/MTKView——`ghostty_surface_new` 内部把自己的 IOSurfaceLayer 塞给 view 并转成 layer-hosting；壳侧动 layer 会踢掉它
- frame 必须非零，否则渲染器无事可做
- `acceptsFirstResponder = true`
- 无任何 draw/refresh/定时器/CVDisplayLink：官方壳一次都没调 `ghostty_surface_refresh/draw`

## 运行期必须转发

| 时机 | 调用 |
|---|---|
| wakeup 回调（任意线程） | main queue → `ghostty_app_tick(app)`，仅此一处 tick |
| layout / setFrameSize | `ghostty_surface_set_size(surface, backing 像素宽, 高)`（不是 point） |
| viewDidChangeBackingProperties | `ghostty_surface_set_content_scale` • 再 set_size |
| window 换屏 / 遮挡变化 | `ghostty_surface_set_display_id` / `ghostty_surface_set_occlusion`，换屏后再同步 scale + size |
| become/resignFirstResponder | `ghostty_surface_set_focus` |
| keyDown/Up | 先经 `ghostty_surface_key_translation_mods`，再 `ghostty_surface_key`；Command keyUp 用 local monitor 补送；`performKeyEquivalent` 只向 `ghostty_surface_key_is_binding` 查询 core |
| flagsChanged | 左右 Shift/Ctrl/Option/Command/Caps Lock 分别转成 Ghostty modifier press/release，包含 `NX_DEVICER*` 侧别位 |
| IME / 文本输入 | 实现 `NSTextInputClient`，marked text → `ghostty_surface_preedit`，提交文本进入 key/text 路径，候选框由 `ghostty_surface_ime_point` 定位；输入源变化通知 app |
| mouse | left/right/middle/扩展键、drag、pressure、精确滚动与 momentum 均转发；**坐标 Y 翻转**（左上原点），exited 发 (-1,-1)，已激活窗口切 pane 的首击只聚焦并吞配对 mouseUp |
| app 激活 / 输入源变化 | `ghostty_app_set_focus` / `ghostty_app_keyboard_changed` |
| core 宿主动作 | 只在 `action_cb` 实现窗口、pane/split、搜索、reload、fullscreen、clipboard、URL 等 macOS 宿主能力；触发键位仍归 core |

上述桥接已在 `TerminalSurfaceView.swift` / `GhosttyRuntime.swift` 落地。与 Ghostty.app 的差异只能发生在 core 回调后的产品壳呈现，不能发生在按键解释、surface 配置或 PTY 输入层。当前 `new_tab`/`goto_tab` 使用 macOS 原生 tab group，`new_split`/`goto_split` 使用 tab 内 split tree；二者保持 vendored Ghostty 的动作边界，不互相重映射。

## 链接契约（Package.swift 已固化）

- 必须：`-lc++`（124 个 C++ 符号，头号失败源）+ AppKit / CoreGraphics / CoreText / CoreVideo / QuartzCore / Metal / IOSurface / Carbon / GameController
- 不需要：`-lz`（zlib 已静态打进归档）、MetalKit、Security
- 官方工程的链接列表不可照抄——它靠 Swift import 自动链接掩盖了真实依赖
- **SwiftPM 坑**：binaryTarget 静态库必须 `lib` 前缀命名，zig 产物 `ghostty-internal.a` 不符合，SwiftPM 报 error 后照样 "Build complete"（空链接）。`scripts/sync-ghosttykit.sh` 负责改名 + 修 plist。冒烟验证必须真实调用符号（如 `ghostty_info()`）。

## 已知问题 / 待办

- 当前 vendored 构建**带 sentry-native**（启动日志可见）。cmux 用 `-Dsentry=false` 重建，因双崩溃处理器打架致 Intel 机启动崩溃有前科。lightty 正式构建应加 `-Dsentry=false`。（已执行）
- **必须 `-Doptimize=ReleaseFast`**：Debug 构建的 core 防御断言（`if (runtime_safety) unreachable`）会把上游容忍性 bug 升级为 SIGABRT——实测点击提示符区域即可触发 Surface.maybePromptClick 崩溃（Surface.zig:4214/4240）。官方发布形态即 Release，同路径静默返回。完整命令：`zig build -Demit-macos-app=false -Dsentry=false -Doptimize=ReleaseFast`。
- 私有 SPI：归档引用 `_CGSSetWindowBackgroundBlurRadius` 等 CGS 符号，过不了 App Store 审核（本项目无所谓，备忘）。
- 钉版本策略：cmux 用"预构建 GhosttyKit tarball + 校验和"而非开发机现编，稳定后可仿效。

## 配置对齐清单（防上游分叉的铁律执行细则）

原则：**凡属于 terminal 视觉域的配置项，其取值方式和推导公式必须照抄官方壳**（macos/Sources/Ghostty/Ghostty.Config.swift 等）；lightty 应用 chrome 是独立产品层，不在此规则内。上游更新后按此清单复核。当前对齐状态：

| 配置项 | 我们的实现 | 官方出处 | 状态 |
|---|---|---|---|
| libghostty resources | `ghostty_init` 前解析：显式 `GHOSTTY_RESOURCES_DIR` → app `Contents/Resources/ghostty` → 从开发期可执行文件向上查找 `vendor/ghostty/zig-out/share/ghostty` | `src/os/resourcesdir.zig` | 纯资源定位 adapter；不解析或修改配置。app 打包必须复制整个 `zig-out/share/ghostty` |
| 配置加载顺序 | default_files → recursive_files → finalize；finalize 后同一对象原样传给 `ghostty_app_new` | Ghostty.Config.swift loadConfig | 对齐全局 Ghostty config；仅跳过 load_cli_args（命令行属于 lightty）。**不存在 lightty terminal 覆盖层** |
| background / foreground | ghostty_config_get + color struct | 同式 | 对齐 |
| background-opacity | Double get，<1 时 terminal 窗口底座非不透明 + 白 0.001 背景；应用标题栏/侧栏另铺不透明实底 | TerminalWindow.syncAppearance | terminal 对齐，chrome 有意分叉 |
| background-blur | ghostty_set_window_background_blur（窗口就绪后） | 同 API | 对齐 |
| split-divider-color 默认 | 亮背景 darken 8% / 暗背景 darken 40%（HSB） | Config.splitDividerColor + OSColor+Extension | 对齐（公式照抄） |
| window-theme | 保留在传给 libghostty 的完整 config 中；lightty host 不再读取它来设置整窗 NSAppearance，应用 chrome 固定为产品定义的 Codex 浅色外观 | Config.windowTheme | **有意分叉**：terminal config ≠ app chrome theme |
| window-colorspace | **壳层不碰**（core 渲染层自行消费） | 官方壳同样不设 window.colorSpace | 对齐 |
| macos-titlebar-style | 保留 lightty 原生标题栏，不读取该项 | HiddenTitlebarTerminalWindow | **有意分叉**：标题栏只承载系统三键与侧栏开关，pane 操作位于侧栏标题行 |
| 热重载 | core `reload_config` action 重新执行同一条 default_files → recursive_files → finalize 链，并用 `ghostty_app_update_config` / `ghostty_surface_update_config` 更新 | 官方监听 reload + 系统外观变化重载 | terminal core 已接；依赖启动快照的 pane chrome/window base 刷新待补 |

配置一致性回归：先 `swift build`，再运行 `scripts/check-config-parity.sh`。脚本从
`/tmp` 启动 lightty（排除 cwd 偶然命中资源），并将 lightty 的实际 libghostty
加载结果与 `/Applications/Ghostty.app/Contents/MacOS/ghostty +show-config` 对比。
`--print-effective-terminal-config` 只输出 background/foreground/opacity/blur 和配置
diagnostics，供这个差分检查使用；脚本同时拒绝重新引入额外 config loader、
`~/.config/lightty/config` 或 `TerminalWindow` 级 appearance 强制。

Terminal adapter 回归：运行 `scripts/check-terminal-adapter-parity.sh`。它拒绝任何
AppKit 非空快捷键和 surface Home cwd override，并钉住 inherited config、IME、
modifier、key-equivalent、display/occlusion 及常用 core host action 桥。完整本地验收：

```sh
swift test
scripts/check-config-parity.sh
scripts/check-terminal-adapter-parity.sh
git diff --check
```

> GhosttyKit 是静态库，`.a` 不包含 themes、terminfo 与 shell-integration。只同步
> `GhosttyKit.xcframework` 不足以得到与 Ghostty.app 相同的配置结果；`.app` 打包时
> 必须把 `vendor/ghostty/zig-out/share/ghostty` 放到
> `Contents/Resources/ghostty`。缺失时带名字的内置主题会报 `theme ... not found`，
> background/foreground 随后保留为 libghostty 默认 `#282c34/#ffffff`。

## 透明排查实录（2026-08-22，防复发）

现象：窗口/层级全部非不透明、surface 像素 alpha 正确（实测 224），视觉仍不透明。

根因：**layer 化后 NSView 自绘内容落在超出 bounds 的 ContentLayer 里**（实测 header 24pt 的绘制内容出现在全窗口尺寸的 ContentLayer 上），父 layer 不裁剪 → 半透明底色整张盖住终端。

修复：自绘 NSView 必须 `clipsToBounds = true`（PaneHeaderView）。

排查路径备忘：逐层排除（config 读取 → 像素 alpha 采样 → 官方壳同 core 对照 → 素窗口二分 → 层级对照 dump），最快路径其实是最后一步的**双窗口 layer 树 diff**——下次遇合成异常直接从它开始。
