# libghostty 嵌入笔记（lightty 实测 + 官方壳源码提取）

> 依据：vendor/ghostty（1.3.2-dev）的 `include/ghostty.h` 与 `macos/Sources/`；链接清单来自对 GhosttyKit 归档的 `nm -u` 符号差集实测。API 官方声明不稳定，升级 vendor 后须复核。

## 定位

`ghostty.h` 开头即声明这是 **libghostty-internal**，唯一官方消费者是 Ghostty.app；官方 macOS 壳没有私有通道，用的就是这套 C API——它本身就是唯一的嵌入示例（`example/` 全是 libghostty-vt 的，与渲染/PTY 无关）。

## 最小调用序列（spike 已验证）

1. `ghostty_init(argc, argv)` == GHOSTTY_SUCCESS，进程一次，先于一切 ghostty_* 调用
2. `ghostty_config_new` → `ghostty_config_load_default_files`（读 `~/.config/ghostty/config`）→ `ghostty_config_finalize`
3. `ghostty_runtime_config_s`：六个回调只有 `close_surface_cb` 可为 NULL；`action_cb`/`read_clipboard_cb` 可恒 return false，终端照样渲染
4. `ghostty_app_new(&rt, config)`（内部 clone config，之后可 `ghostty_config_free`）
5. 非零 frame 的普通 NSView 入窗口层级（见下方硬约束）
6. `ghostty_surface_config_new()` 取默认值（勿 memset 0），设 `platform_tag=GHOSTTY_PLATFORM_MACOS`、`platform.macos.nsview`、`scale_factor`，`ghostty_surface_new` → PTY/渲染线程自动起

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
| become/resignFirstResponder | `ghostty_surface_set_focus` |
| keyDown/Up | `ghostty_surface_key`；控制字符不进 `text`（keycode 交给内部编码） |
| mouse | `ghostty_surface_mouse_button/_pos/_scroll`；**坐标 Y 翻转**（左上原点），exited 发 (-1,-1) |

正式版待补：IME（NSTextInputClient + `ghostty_surface_ime_point`）、`flagsChanged` 修饰键、`ghostty_surface_key_translation_mods`（macos-option-as-alt）、换屏 `set_display_id`、遮挡 `set_occlusion`。

## 链接契约（Package.swift 已固化）

- 必须：`-lc++`（124 个 C++ 符号，头号失败源）+ AppKit / CoreGraphics / CoreText / CoreVideo / QuartzCore / Metal / IOSurface / Carbon / GameController
- 不需要：`-lz`（zlib 已静态打进归档）、MetalKit、Security
- 官方工程的链接列表不可照抄——它靠 Swift import 自动链接掩盖了真实依赖
- **SwiftPM 坑**：binaryTarget 静态库必须 `lib` 前缀命名，zig 产物 `ghostty-internal.a` 不符合，SwiftPM 报 error 后照样 "Build complete"（空链接）。`scripts/sync-ghosttykit.sh` 负责改名 + 修 plist。冒烟验证必须真实调用符号（如 `ghostty_info()`）。

## 已知问题 / 待办

- 当前 vendored 构建**带 sentry-native**（启动日志可见）。cmux 用 `-Dsentry=false` 重建，因双崩溃处理器打架致 Intel 机启动崩溃有前科。lightty 正式构建应加 `-Dsentry=false`。（已执行）
- 私有 SPI：归档引用 `_CGSSetWindowBackgroundBlurRadius` 等 CGS 符号，过不了 App Store 审核（本项目无所谓，备忘）。
- 钉版本策略：cmux 用"预构建 GhosttyKit tarball + 校验和"而非开发机现编，稳定后可仿效。

## 配置对齐清单（防上游分叉的铁律执行细则）

原则：**每个视觉/行为配置项的取值方式和推导公式必须照抄官方壳**（macos/Sources/Ghostty/Ghostty.Config.swift 等），上游更新后按此清单复核。当前对齐状态：

| 配置项 | 我们的实现 | 官方出处 | 状态 |
|---|---|---|---|
| 配置加载顺序 | default_files → recursive_files → **lightty overlay** → finalize | Ghostty.Config.swift loadConfig | 对齐 + **有意扩展**：跳过 load_cli_args（命令行属于自己）；最后叠加 `~/.config/lightty/config`（同 ghostty 语法的专属覆盖，如压顶部 padding 抵偿标题栏+header chrome；文件内 config-file 包含不递归展开） |
| background / foreground | ghostty_config_get + color struct | 同式 | 对齐 |
| background-opacity | Double get，<1 时窗口非不透明 + 白 0.001 背景 | TerminalWindow.syncAppearance | 对齐 |
| background-blur | ghostty_set_window_background_blur（窗口就绪后） | 同 API | 对齐 |
| split-divider-color 默认 | 亮背景 darken 8% / 暗背景 darken 40%（HSB） | Config.splitDividerColor + OSColor+Extension | 对齐（公式照抄） |
| window-theme | light/dark/system/auto(按背景亮度) → NSAppearance | Config.windowTheme | 对齐 |
| window-colorspace | **壳层不碰**（core 渲染层自行消费） | 官方壳同样不设 window.colorSpace | 对齐 |
| macos-titlebar-style | 恒为 hidden 风格（含 NSTitlebarContainerView 整体隐藏） | HiddenTitlebarTerminalWindow | **有意分叉**：pane header 取代标题栏，不读该配置 |
| 热重载 | 启动读一次 | 官方监听 reload + 系统外观变化重载 | 待办 |

## 透明排查实录（2026-08-22，防复发）

现象：窗口/层级全部非不透明、surface 像素 alpha 正确（实测 224），视觉仍不透明。

根因：**layer 化后 NSView 自绘内容落在超出 bounds 的 ContentLayer 里**（实测 header 24pt 的绘制内容出现在全窗口尺寸的 ContentLayer 上），父 layer 不裁剪 → 半透明底色整张盖住终端。

修复：自绘 NSView 必须 `clipsToBounds = true`（PaneHeaderView）。

排查路径备忘：逐层排除（config 读取 → 像素 alpha 采样 → 官方壳同 core 对照 → 素窗口二分 → 层级对照 dump），最快路径其实是最后一步的**双窗口 layer 树 diff**——下次遇合成异常直接从它开始。
