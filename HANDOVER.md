# lightty 接手入口

lightty 是基于 libghostty 的 macOS 终端应用，提供 Handoff 任务管理、终端现场导航和 Agent 状态提示。

## 设计与职责

- UI 的语义 token、区域差异与组件选择见 [UI harness](docs/UI-harness.md)。

- 修改配置、工作区快照或组织数据格式前，阅读 [持久化契约](docs/persistence.md)：启动时自动迁移，业务只处理当前格式；Handoff 保持已发布协议。

- 领域术语：[CONTEXT.md](CONTEXT.md)。窗口包含标签页，标签页包含终端；任务绑定点是终端，不是窗口。
- 当前布局：[双侧栏约定](docs/specs/double-sidebar.md)。第一侧栏管理资料，第二侧栏导航当前窗口的标签页与终端。
- 待实现功能：[Handoff / Sessions 模式](docs/specs/primary-sidebar-modes.md)，[CLI 会话调研](docs/specs/session-provider-research.md)。设计文档不代表功能已实现。
- Handoff 持久化：[任务格式](docs/task-format.md)。任务正文为接手 Agent 写，引用已有文档与提交，不重复复制，不记录密钥。
- 与 Claude Code / Codex 的全部接触点（命令、hook、文件、安装方式、脆弱程度）：[依赖清单](docs/agent-dependencies.md)。动任何一处之前先看它，再进对应的细节文档。
- Agent 状态与上下文：[状态契约](docs/specs/pane-status.md)，[hooks 安装与排查](docs/hooks.md)。
- 对会话做任何操作（列表、改名、删除、判断占用）之前，先看 [Agent 会话操作的官方接口清单](docs/specs/agent-session-apis.md)：哪些有官方接口、lightty 用了哪些、剩下的为什么没用。不要先自己解析目录或往终端里敲命令。
- 终端嵌入：[libghostty 契约](docs/libghostty-embedding.md)，[适配核查清单](docs/parity-plan.md)。

## 当前实现入口

- TerminalWindowController：窗口、标签页、pane 树与双侧栏布局；窗口的标签页、排布、标题、放大与焦点都在 LighttyCore 的 WindowArrangement 值里，改树只经 `commit`，关闭只经 `close(panes:)`。见 [pane 排布与移动](docs/specs/pane-layout.md)。
- PrimarySidebar：第一侧栏外壳、模式标题及说明；HandoffSidebarContent / SessionsSidebarContent 分别承载两种内容。
- LaunchComposer / SearchPalette：共享启动浮层；三个入口（Sessions 新建会话、Handoff 新建任务、任务开始处理）只是它的三组初值。ArchivedTasksView 管理设置中的归档恢复与彻底删除。
- SessionLibrary / AgentSessionProvider：分页会话目录、取消、项目持久化；列表、改名、删除、占用检测、存活进程观测都经 provider，Agent 差异只在 CodexSessionProvider / ClaudeSessionProvider 里。占用检测与存活进程只问各家的官方接口（Claude 的 `claude agents --json`；codex 没有对等接口，一律「问不出来」），不读进程表 / 文件表反推。调用 Agent CLI 与 node helper 的进程环境（清 LIGHTTY_*、PATH、配置目录变量、arm64 运行时路径）只在 AgentHelperProcess 里拼。
- AgentSpec（LighttyCore）：一家 Agent 的全部常量——可执行名、配置根、显示名与图标资源、续接与选择器写法、bypass 参数、技能调用前缀、hook 事件表、配置文件名与格式、插件动词与清单路径。值写在 `Sources/LighttyCore/Agents/<家名>Agent.swift`，`SessionAgent.spec` 是全 app 唯一按家穷举的 switch。**加一家 Agent 只加一个文件**：枚举补 case 之后，编译错误只落在 `spec` 那个 switch 与几处枚举桥（HookAgent / LaunchAgent / PluginAgent），再新建一个 `XxxAgent.swift`。剩下要另外补的只有两处：`SessionCatalogSource.makeProvider`（要造 provider，LighttyCore 不依赖 app 目标）和 `HookMarketplace` 里那两份插件清单的内容。
- Claude 官方 SDK helper：`node scripts/prepare-claude-helper.mjs` 准备 debug 依赖，再运行 `swift build && .build/debug/lightty`。打包脚本自动准备双架构运行时；应用运行时不下载依赖。
- PaneLauncher：由 lightty 发起的新终端（启动浮层、续接会话、原生会话选择器、任务开始处理、重启恢复）都构造启动请求交给它；删除互斥、已打开则聚焦、占用检查、会话关联、任务绑定、放置都在这里，结果交回调用方决定怎么提示。原生 CLI 恢复，目录身份跟随原来源，不通过 SDK 执行 Agent。helper 发布签名/公证及旧系统验收尚未完成。
- SessionResumeFlow：续接与原生选择器的呈现层，只按启动器的结果弹目录面板、占用提示和错误框。
- TaskBindings（LighttyCore）：终端 ↔ Handoff 任务文件绑定的唯一所有者，任务的建档、改名、归档、删除也经它发起并发出带载荷的变更通知。任务目录的监听也归它（生产用 PathWatcher，测试注入手动变更源）：Agent 在外部写回任务文件后，它发 `lighttyTasksDidChange` 让列表重读，已绑定任务被外部改名时同步终端标题。
- PaneView / TerminalSurfaceView：终端视图与 libghostty surface；任务绑定只读查询 TaskBindings。
- WorkspaceSnapshot / WorkspaceStore：窗口现场保存与重启恢复；不是全量 Agent 会话目录。
- UserDataMigration / UserDataSchemas / JSONSchemaMigration：启动升级、各文件规则及纯内存版本转换，先于业务初始化。
- AgentLaunchPreference：新任务默认 Agent 为 Codex，启动命令可在通用设置修改。
- LighttyCore：任务文件、运行时目录、状态报文等无 AppKit 逻辑。

## 构建与验证

构建依赖及从零安装步骤以 [README](README.md#从源码构建--building-from-source) 为准。
本地调试运行：swift build && .build/debug/lightty；不要误开旧打包实例验证新代码。
测试：swift test。终端适配门禁：scripts/check-terminal-adapter-parity.sh。
全量测试要点：
- 在 lightty 的 pane 里跑，先 `unset LIGHTTY_PANE_ID LIGHTTY_SOCK`。
- 测试里不要广播全局偏好变化（例如 `LanguagePreference.set`）：之前测试留下的窗口会跟着重建，曾让进程稳定卡死在 `ghostty_surface_free`。
- 测试里建 ghostty 运行时一律用 `ensureTerminalRuntime()`（`Tests/LighttyTests/TerminalRuntimeTestSupport.swift`）。测试终端默认跑 `cat`、不跑交互 shell：测试主线程很少 tick，app 邮箱常年是满的，这时释放跑着 zsh 的 surface 会永久卡死在 `ghostty_surface_free`。确实要真 shell 的测试设 `TerminalTestShell.usesRealShell = true`，用完复原。
- 测试里 pane 进窗口默认**不建 surface**（`ensureTerminalRuntime()` 会把 `TerminalSurfaceView.spawnsSurfaces` 关掉）：`TerminalWindowController(...)` 装进去的 pane 只是布局/状态载体，`terminal.surface == nil`，不 spawn `login`/shell、不起渲染和 IO 线程。全量一轮里同时存活的 `cat` 从 66 个降到 0。确实要 pty 的测试（环境变量到 shell、启动命令真执行、等 OSC 7/进程退出之类）在该测试里设 `TerminalTestShell.spawnsSurfaces = true`（要真 zsh 再加 `usesRealShell = true`），用完复原；已在窗口里的 pane 不会补建 surface。目前只有 `SurfaceEnvironmentTests` 和 `AgentLaunchPreferenceTests.testBoundTaskIsReadyBeforeStartupCommandRunsInTaskDirectory` 打开它。
- 测试里等异步结果只用 `waitUntil`（XCTest）/ `awaitUntil`（Swift Testing），见 `Tests/LighttyTests/WaitTestSupport.swift`。超时会结束当前测试；不要手写「截止时间 + 循环 + 断言」，超时后继续往下按行号取行会 trap，整个测试进程崩掉。超时上限本身是契约时（如刷新按钮最多转完一圈）才显式传短超时。
- 不写固定时长的等待（`RunLoop.main.run(until:)`、固定 `Task.sleep`）：负载高时偶发失败，负载低时白等。等的是「排在主队列里的下一拍」（`Coalescer(.nextTick)` 合流刷新、投到下一拍的命令）就用 `drainMainQueue()`（XCTest）/ `awaitMainQueue(hops:)`（async 测试；会话库通知一拍、收到通知的列表再一拍，是两跳）；等控制器 init 排到下一拍装的侧栏用 `controller.waitForInitialLayout()`（`WindowChromeTestSupport.swift`）。任务侧栏的滑入由 CADisplayLink 驱动，不上屏的测试窗口永远不走帧，别等它滑到位。只有「某事**不该**发生」的否定式断言仍用一段固定时长，且要注释它压过的是哪个时间窗。
- 测试的粒度：一条测试守一个不变量或一个用户场景，不是一个小功能一条。修 bug 时优先给已有的场景测试加一步或加一个 case，不新开一条只复现这一个 bug 的测试；同一个纯函数/映射的多个输入写成一张表（XCTest 数组循环、Swift Testing `@Test(arguments:)`），每行带回归背景注释。不用单元测试钉外观决定（颜色、字号、间距、某控件存不存在、图标形态）：改设计就挂、抓不到功能回归；要看外观走 `LIGHTTY_UI_SNAPSHOT_DIR` 截图。全套测试已按这个口径审过一遍（见 afce3a4、1d1ee6d）。
- 测试窗口不上屏：要窗口成为 key 或参与布局时用 `makeKeyAndOrderFrontInvisibly()` / `orderFrontInvisibly()`（`InvisibleWindowTestSupport.swift`），不要 `makeKeyAndOrderFront(nil)`；只有 `LIGHTTY_UI_SNAPSHOT_DIR` 截图那条分支例外。
- 跑真实 `lightty-hook` 的测试一律经 `HookLauncher`（`Tests/LighttyTests/HookLaunchTestSupport.swift`）用 `script -q /dev/null` 造自己的 pty：hook 每一发都先判「是不是工具里拉起的子会话」，判据是祖先链的终端结构，直接 `Process` 起的话形状取决于谁在跑 `swift test`——在某个 agent 的 Bash 工具里跑，测试进程本身就是工具子进程，hook 会正确地静默，用例跟着时灵时不灵。
- `scripts/check-config-parity.sh` 会启动 lightty 二进制，入口会先对真实 `~/.lightty` 跑数据迁移，HOME 覆盖无效，先退出正在使用的 lightty 再跑。
发布打包：scripts/package-app.sh。

Ghostty 内核使用 lightty-patches 分支。更改内核后重新构建 vendor/ghostty、运行 scripts/sync-ghosttykit.sh，再构建 Swift；仅 swift build 不会重建内核。

## 维护约定

产品文档只保留当前契约、明确标注的待实施方案和必要兼容规则。已废弃方案、讨论过程与逐日进展不追加到正文；变更历史由 Git 保存。
终端输入和行为配置由 Ghostty 拥有；lightty 壳层不另造冲突的快捷键体系。动态颜色转成 CGColor 后必须在外观变化时重新解析。
