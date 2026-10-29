# 测试约定

写或改测试前读本文。每条约定都对应一次真实踩过的卡死或偶发失败。

## 运行

- `scripts/test.sh [过滤]`：清掉继承的 `LIGHTTY_PANE_ID` / `LIGHTTY_SOCK` 后跑 `swift test`，只输出失败项与 `file:line`，完整日志留在 `.build/test-logs/`。跳过的测试单独列出，跳过不算通过。
- `scripts/check.sh`：交付前的总检查（构建、全量测试、终端适配门禁、文档核对）。
- `scripts/snapshot.sh <过滤>`：带 `LIGHTTY_UI_SNAPSHOT_DIR` 跑测试并列出截图，外观改动用它看渲染结果，入口见 [UI harness](UI-harness.md#工作与验证)。
- Agent 对接的 schema 契约：`scripts/test.sh AgentContractTests`（本机没装那一家就跳过）。新用到 app-server 方法、字段、枚举值时补充契约表。

## 粒度

一条测试守一个不变量或一个用户场景。修 bug 时优先给已有的场景测试加一步或加一个 case；同一个纯函数/映射的多个输入写成一张表（XCTest 数组循环、Swift Testing `@Test(arguments:)`），每行带回归背景注释。

外观决定（颜色、字号、间距、某控件存不存在、图标形态）交给截图，单元测试只守行为：钉外观的断言改设计就挂、抓不到功能回归。

## 等待异步

- 等异步结果只用 `waitUntil`（XCTest）/ `awaitUntil`（Swift Testing），见 `Tests/LighttyTests/WaitTestSupport.swift`。超时会结束当前测试；手写的「截止时间 + 循环 + 断言」超时后继续按行号取行会 trap，整个测试进程崩掉。超时上限本身是契约时（如刷新按钮最多转完一圈）才显式传短超时。
- 等「排在主队列里的下一拍」（`Coalescer(.nextTick)` 合流刷新、投到下一拍的命令）用 `drainMainQueue()`（XCTest）/ `awaitMainQueue(hops:)`（async 测试；会话库通知一拍、收到通知的列表再一拍，是两跳）。等控制器 init 排到下一拍装的侧栏用 `controller.waitForInitialLayout()`（`Tests/LighttyTests/WindowChromeTestSupport.swift`）。
- 固定时长的等待（`RunLoop.main.run(until:)`、固定 `Task.sleep`）负载高时偶发失败、负载低时白等，只留给「某事**不该**发生」的否定式断言，并注释它压过的是哪个时间窗。
- 任务侧栏的滑入由 CADisplayLink 驱动，不上屏的测试窗口永远不走帧，断言滑入后的状态而不是等它滑到位。

## 终端运行时与 surface

- 建 ghostty 运行时一律用 `ensureTerminalRuntime()`（`Tests/LighttyTests/TerminalRuntimeTestSupport.swift`）。
- 测试终端默认跑 `cat`：测试主线程很少 tick，app 邮箱常年是满的，这时释放跑着 zsh 的 surface 会永久卡死在 `ghostty_surface_free`。确实要真 shell 的测试设 `TerminalTestShell.usesRealShell = true`，用完复原。
- pane 进窗口默认**不建 surface**（`ensureTerminalRuntime()` 会把 `TerminalSurfaceView.spawnsSurfaces` 关掉）：`TerminalWindowController(...)` 装进去的 pane 只是布局/状态载体，`terminal.surface == nil`。确实要 pty 的测试（环境变量到 shell、启动命令真执行、等 OSC 7/进程退出）在该测试里设 `TerminalTestShell.spawnsSurfaces = true`，用完复原；已在窗口里的 pane 不会补建 surface。目前只有 `SurfaceEnvironmentTests` 和 `AgentLaunchPreferenceTests.testBoundTaskIsReadyBeforeStartupCommandRunsInTaskDirectory` 打开它。
- 测试里的全局偏好变化（例如 `LanguagePreference.set`）保持不广播：之前测试留下的窗口会跟着重建，曾让进程稳定卡死在 `ghostty_surface_free`。

## 窗口

测试窗口不上屏：要窗口成为 key 或参与布局时用 `makeKeyAndOrderFrontInvisibly()` / `orderFrontInvisibly()`（`Tests/LighttyTests/InvisibleWindowTestSupport.swift`）。只有 `LIGHTTY_UI_SNAPSHOT_DIR` 截图分支上屏。

## 跑真实 `lightty-hook`

一律经 `HookLauncher`（`Tests/LighttyTests/HookLaunchTestSupport.swift`）用 `script -q /dev/null` 造自己的 pty。hook 每一发都先判「是不是工具里拉起的子会话」，判据是祖先链的终端结构；直接 `Process` 起的话，形状取决于谁在跑 `swift test`——在某个 agent 的 Bash 工具里跑，测试进程本身就是工具子进程，hook 会正确地静默，用例跟着时灵时不灵。

## 会碰真实数据的脚本

`scripts/check-config-parity.sh` 会启动 lightty 二进制，入口先对真实 `~/.lightty` 跑数据迁移，HOME 覆盖无效。只在用户退出 lightty 后运行；仓库的 PreToolUse hook 会在 lightty 运行时拦下它。
