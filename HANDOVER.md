# lightty 接手入口

lightty 是基于 libghostty 的 macOS 终端应用，提供 Handoff 任务管理、终端现场导航和 Agent 状态提示。

## 设计与职责

- 修改配置、工作区快照或组织数据格式前，阅读 [持久化契约](docs/persistence.md)：启动时自动迁移，业务只处理当前格式；Handoff 保持已发布协议。

- 领域术语：[CONTEXT.md](CONTEXT.md)。窗口包含标签页，标签页包含终端；任务绑定点是终端，不是窗口。
- 当前布局：[双侧栏约定](docs/specs/double-sidebar.md)。第一侧栏管理资料，第二侧栏导航当前窗口的标签页与终端。
- 待实现功能：[Handoff / Sessions 模式](docs/specs/primary-sidebar-modes.md)，[CLI 会话调研](docs/specs/session-provider-research.md)。设计文档不代表功能已实现。
- Handoff 持久化：[任务格式](docs/task-format.md)。任务正文为接手 Agent 写，引用已有文档与提交，不重复复制，不记录密钥。
- Agent 状态与上下文：[状态契约](docs/specs/pane-status.md)，[hooks 安装与排查](docs/hooks.md)。
- 对会话做任何操作（列表、改名、删除、判断占用）之前，先看 [Agent 会话操作的官方接口清单](docs/specs/agent-session-apis.md)：哪些有官方接口、lightty 用了哪些、剩下的为什么没用。不要先自己解析目录或往终端里敲命令。
- 终端嵌入：[libghostty 契约](docs/libghostty-embedding.md)，[适配核查清单](docs/parity-plan.md)。

## 当前实现入口

- TerminalWindowController：窗口、标签页、pane 树与双侧栏布局。
- PrimarySidebar：第一侧栏外壳、模式标题及说明；HandoffSidebarContent / SessionsSidebarContent 分别承载两种内容。
- LaunchComposer / SearchPalette：共享启动浮层；三个入口（Sessions 新建会话、Handoff 新建任务、任务开始处理）只是它的三组初值。ArchivedTasksView 管理设置中的归档恢复与彻底删除。
- SessionLibrary / SessionCatalogProvider：分页会话目录、取消、项目持久化；CodexSessionCatalog / ClaudeSessionCatalog 隔离来源协议。
- Claude 官方 SDK helper：`node scripts/prepare-claude-helper.mjs` 准备 debug 依赖，再运行 `swift build && .build/debug/lightty`。打包脚本自动准备双架构运行时；应用运行时不下载依赖。
- SessionResumeFlow：原生 CLI 恢复；目录身份跟随原来源，不通过 SDK 执行 Agent。helper 发布签名/公证及旧系统验收尚未完成。
- PaneView / TerminalSurfaceView：任务绑定与 libghostty surface。
- WorkspaceSnapshot / WorkspaceStore：窗口现场保存与重启恢复；不是全量 Agent 会话目录。
- UserDataMigration / UserDataSchemas / JSONSchemaMigration：启动升级、各文件规则及纯内存版本转换，先于业务初始化。
- AgentLaunchPreference：新任务默认 Agent 为 Codex，启动命令可在通用设置修改。
- LighttyCore：任务文件、运行时目录、状态报文等无 AppKit 逻辑。

## 构建与验证

构建依赖及从零安装步骤以 [README](README.md#building-from-source) 为准。
本地调试运行：swift build && .build/debug/lightty；不要误开旧打包实例验证新代码。
测试：swift test。终端适配门禁：scripts/check-terminal-adapter-parity.sh。
发布打包：scripts/package-app.sh。

Ghostty 内核使用 lightty-patches 分支。更改内核后重新构建 vendor/ghostty、运行 scripts/sync-ghosttykit.sh，再构建 Swift；仅 swift build 不会重建内核。

## 维护约定

产品文档只保留当前契约、明确标注的待实施方案和必要兼容规则。已废弃方案、讨论过程与逐日进展不追加到正文；变更历史由 Git 保存。
终端输入和行为配置由 Ghostty 拥有；lightty 壳层不另造冲突的快捷键体系。动态颜色转成 CGColor 后必须在外观变化时重新解析。
