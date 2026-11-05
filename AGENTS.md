# lightty

为并行运行多个 AI agent 设计的 macOS 终端：内核是带补丁的 libghostty（`vendor/ghostty`，`lightty-patches` 分支，不入本仓库），壳层用 Swift + AppKit（SwiftPM，macOS 13+），提供 Handoff 任务、终端现场导航和 Claude Code / Codex 状态提示。术语以 [CONTEXT.md](CONTEXT.md) 为准：窗口包含标签页，标签页包含终端；任务绑定点是终端。

代码分三个目标：`Sources/LighttyCore`（无 AppKit 的模型、协议与 Agent 常量），`Sources/lightty`（AppKit 壳），`Sources/lightty-hook`（Agent hook helper，只链 Foundation + LighttyCore）。

## 命令

- 构建：`swift build`。首次运行前 `node scripts/prepare-claude-helper.mjs` 准备 Claude SDK helper。只重建 Swift，改内核走 `ghostty-kernel` 技能。
- 测试：`scripts/test.sh [过滤]`，只输出失败项与 `file:line`。
- 改完跑检查，通过才算完成：`scripts/check.sh`（构建、全量测试、终端适配门禁、本地化、UI token、文档核对）。
- 看界面：`scripts/snapshot.sh <过滤>`，渲染截图到 `.build/ui-snapshots/`（测试窗口会短暂上屏）；各区域的过滤见 [UI harness](docs/UI-harness.md#工作与验证)。
- 打包与发布：`scripts/package-app.sh`，流程见 [发布](docs/releasing.md)。

完成标准：`scripts/check.sh` 通过；改了界面就看过截图，交付时写明未覆盖的状态（窄宽度、长文本、明暗）。

## 找代码

业务词先查 [CONTEXT.md](CONTEXT.md)，拿到代码标识后 grep；出现新业务概念时，在同一次改动里补进词表。Shell 是 zsh，`grep --include='*.swift'` 的通配符要加引号。

`Sources/lightty` 是平铺目录，改下面这些状态只走这个入口，绕过去会让界面、持久化和恢复各算各的：

| 要改什么 | 唯一入口 |
| --- | --- |
| 标签页与分屏树、放大、焦点、关闭 | `WindowArrangement` 值，经 `TerminalWindowController` 的 `commit` / `close(panes:)` |
| 新开终端、续接会话 | `PaneLauncher` + `AgentCommand`，界面只传意图 |
| 终端绑定的任务；任务文件读写 | `TaskBindings`；`TaskStore` |
| 会话列表、项目归属、终端与会话的对应 | `SessionLibrary` 汇总，事实来自 `AgentSessionProvider`，归属在 `SessionOrganization` |
| Agent 活动状态 | `lightty-hook` → `PaneStatusDatagram` → `PaneStatusStore`，取色经 `ShellStyle.dotColor` |
| 注入给 Agent 的 Handoff 文本 | `HandoffProtocol` |
| 写用户的 Agent 配置 | `HookInstaller`、`HookMarketplace`、`PluginConfigEdit` |
| `~/.lightty` 数据格式 | `UserDataSchemas`、`UserDataMigration` |

## 测试

功能开发优先。出问题时 AI coding 能很快修好，所以测试只守修复来不及或发现不了的地方：

- 用户数据：`~/.lightty` 迁移与读写、任务文件写回、工作区恢复。
- 不可逆或写到外部的操作：永久删除会话、写用户的 Agent 配置。
- 对接协议：hook 事件与状态报文、Agent 官方接口的 schema、Handoff 协议。
- 排布不变量：关闭、移动、撤销不能丢终端。
- 只在负载下或时序上才暴露的问题：卡死、竞态。

其余改动靠编译、截图和实际运行验证。修 bug 时，只有这类 bug 落在上面的范围或已反复出现，才留回归测试。开发中用 `scripts/test.sh <过滤>` 只跑相关测试。

## 硬约束

- 用户的 lightty 正在运行：验证用测试 fixture 与截图，真实界面交给用户在当前实例里验收。第二个实例会共用真实的 `~/.lightty`，仓库 hook 会拦下启动命令与 `scripts/check-config-parity.sh`。
- 终端输入、快捷键和 terminal 配置归 Ghostty；壳层经 `action_cb` / `ghostty_surface_binding_action` 回到 core，见 [libghostty 契约](docs/libghostty-embedding.md)。
- Agent 会话的事实（列表、改名、删除、占用、存活）只问各家官方接口，见 [官方接口清单](docs/specs/agent-session-apis.md)。
- 界面文案写 `L("English key")`，同时在 `Sources/lightty/Resources/zh-Hans.lproj/Localizable.strings` 补中文；Handoff 协议文本固定英文，不走本地化。
- 模块的单一所有者与不变量写在类型的文档注释里，改一个类型前先读它的注释。
- 文档只写现行契约、标明状态的待实施方案和兼容规则；历史交给 Git。改了行为就同步改对应文档。

## 按任务读

- 写或改测试：[测试约定](docs/testing.md)。
- 改 UI（布局、文字层级、颜色、图标、交互状态）：token 的值与选择依据见 [DESIGN.md](DESIGN.md)，区域、组件与行为见 [UI harness](docs/UI-harness.md) 的相关部分。样式引用 `ShellStyle` 的语义 token，缺合适的颜色 token 时先加 token 再用。侧栏结构与行为见 [双侧栏](docs/specs/double-sidebar.md)、[标签页分组](docs/specs/tab-groups.md)、[第一侧栏模式](docs/specs/primary-sidebar-modes.md)。
- 动标签页与分屏树（移动、关闭、放大、撤销）：[pane 排布](docs/specs/pane-layout.md)。
- 新开终端、终端与 Agent 会话 / 任务的关联、重启恢复：[终端关联契约](docs/terminal-associations.md)。
- 动任何 Claude Code / Codex 接触点（命令、hook、文件、安装方式）：先看 [依赖清单](docs/agent-dependencies.md)；状态与上下文注入见 [状态契约](docs/specs/pane-status.md) 与 [hooks](docs/hooks.md)。接入新 Agent 用 `add-agent` 技能，检查对接兼容性用 `agent-compat` 技能。
- 改配置、工作区快照或组织数据格式：[持久化契约](docs/persistence.md)；Handoff 任务文件：[任务格式](docs/task-format.md)。
- 终端嵌入与内核：[libghostty 契约](docs/libghostty-embedding.md)、[适配核查清单](docs/parity-plan.md)。

技能源文件在 `.agents/skills/`（`.claude/skills` 是它的软链）。`docs/specs/` 每篇开头标着状态，`待实施` / `调研记录` 不代表已实现。

新规则等 agent 反复犯同一个错之后再加，能写成检查的优先写成检查。
