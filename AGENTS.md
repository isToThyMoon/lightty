# lightty

为并行运行多个 AI agent 设计的 macOS 终端：内核是带补丁的 libghostty（`vendor/ghostty`，`lightty-patches` 分支，不入本仓库），壳层用 Swift + AppKit（SwiftPM，macOS 13+），提供 Handoff 任务、终端现场导航和 Claude Code / Codex 状态提示。术语以 [CONTEXT.md](CONTEXT.md) 为准：窗口包含标签页，标签页包含终端；任务绑定点是终端。

代码分三个目标：`Sources/LighttyCore`（无 AppKit 的模型、协议与 Agent 常量），`Sources/lightty`（AppKit 壳），`Sources/lightty-hook`（Agent hook helper，只链 Foundation + LighttyCore）。

## 命令

- 构建：`swift build`。首次运行前 `node scripts/prepare-claude-helper.mjs` 准备 Claude SDK helper。只重建 Swift，改内核走 `ghostty-kernel` 技能。
- 测试：`scripts/test.sh [过滤]`，只输出失败项与 `file:line`。
- 交付前：`scripts/check.sh`（构建、全量测试、终端适配门禁、本地化、文档核对）。
- 看界面：`scripts/snapshot.sh <过滤>`，渲染截图到 `.build/ui-snapshots/`（测试窗口会短暂上屏）；各区域的过滤见 [UI harness](docs/UI-harness.md#工作与验证)。
- 打包与发布：`scripts/package-app.sh`，流程见 [发布](docs/releasing.md)。

完成标准：`scripts/check.sh` 通过；改了界面就看过截图，交付时写明未覆盖的状态（窄宽度、长文本、明暗）。

## 硬约束

- 用户的 lightty 正在运行：验证用测试 fixture 与截图，真实界面交给用户在当前实例里验收。第二个实例会共用真实的 `~/.lightty`，仓库 hook 会拦下启动命令与 `scripts/check-config-parity.sh`。
- 终端输入、快捷键和 terminal 配置归 Ghostty；壳层经 `action_cb` / `ghostty_surface_binding_action` 回到 core，见 [libghostty 契约](docs/libghostty-embedding.md)。
- Agent 会话的事实（列表、改名、删除、占用、存活）只问各家官方接口，见 [官方接口清单](docs/specs/agent-session-apis.md)。
- 界面文案写 `L("English key")`，同时在 `Sources/lightty/Resources/zh-Hans.lproj/Localizable.strings` 补中文；Handoff 协议文本固定英文，不走本地化。
- 模块的单一所有者与不变量写在类型的文档注释里，改一个类型前先读它的注释。
- 文档只写现行契约、标明状态的待实施方案和兼容规则；历史交给 Git。改了行为就同步改对应文档。

## 按任务读

- 写或改测试：[测试约定](docs/testing.md)。
- 改 UI（布局、文字层级、颜色、图标、交互状态）：[UI harness](docs/UI-harness.md) 的相关部分，再看所在区域的组件与 token。侧栏结构与行为见 [双侧栏](docs/specs/double-sidebar.md)、[标签页分组](docs/specs/tab-groups.md)、[第一侧栏模式](docs/specs/primary-sidebar-modes.md)。
- 动标签页与分屏树（移动、关闭、放大、撤销）：[pane 排布](docs/specs/pane-layout.md)。
- 新开终端、终端与 Agent 会话 / 任务的关联、重启恢复：[终端关联契约](docs/terminal-associations.md)。
- 动任何 Claude Code / Codex 接触点（命令、hook、文件、安装方式）：先看 [依赖清单](docs/agent-dependencies.md)；状态与上下文注入见 [状态契约](docs/specs/pane-status.md) 与 [hooks](docs/hooks.md)。接入新 Agent 用 `add-agent` 技能，检查对接兼容性用 `agent-compat` 技能。
- 改配置、工作区快照或组织数据格式：[持久化契约](docs/persistence.md)；Handoff 任务文件：[任务格式](docs/task-format.md)。
- 终端嵌入与内核：[libghostty 契约](docs/libghostty-embedding.md)、[适配核查清单](docs/parity-plan.md)。

技能源文件在 `.agents/skills/`（`.claude/skills` 是它的软链）。`docs/specs/` 每篇开头标着状态，`待实施` / `调研记录` 不代表已实现。
