# 会话列表、改名、删除、占用

列会话、补工作目录、改名、删除、判断有没有人在用，两家各自走哪个接口。总览与入口见[依赖清单](../agent-dependencies.md)。

这些操作都经 `AgentSessionProvider`（`ClaudeSessionProvider` / `CodexSessionProvider`，由 `SessionCatalogSource.makeProvider` 选择），两家差异只在 provider 里。每项接口的取舍理由见 `docs/specs/agent-session-apis.md`；删除的边界见 `docs/session-deletion-research.md`。

| 功能 | Claude Code | Codex | 出问题时 |
|---|---|---|---|
| 列会话 | **不调 claude**。打包的 Node 运行时跑 `@anthropic-ai/claude-agent-sdk 0.3.263` 的 `list-sessions.mjs`（`listSessions`，每页 100，按 offset 翻页） | 常驻的 `codex app-server --listen stdio://`（`CodexAppServer`，同一可执行文件 + 配置根一个，首次请求时启动并 `initialize` → `initialized`），再发 `thread/list`（含 `archived`，`sourceKinds: [cli, vscode]`、`useStateDbOnly: true`，读取官方索引而不在每次刷新时扫描修复历史日志）；只留终端界面建的会话：`source: cli`，或 0.157 起的 `source: vscode` + `originator: codex-tui`（`CodexAgent.terminalOriginator`） | SDK 缺失：报「helper 丢失」；app-server 单次请求 12 秒超时或格式不认识：这一家显示错误，另一家照常；超时、进程退出、可执行文件换过时下一次请求换新进程 |
| 补工作目录 | SDK 只在转录头 64KB 找 `cwd`，找不到时 helper 往后多读转录文件 | app-server 直接给 | |
| 改名 | `rename-session.mjs`（`renameSession`） | `thread/name/set` | |
| 删除 | `delete-session.mjs`（`deleteSession`） | `codex delete --force <id>` | 删除前先做占用检查 |
| 判断是否有人在用 | 只问 `claude agents --json`（pid ↔ sessionId）；表里没有就是「问不出来」 | 没有对等接口，一律「问不出来」 | 「问不出来」和「没人用」严格区分：前者删除时弹确认，后者才放行。Codex 会话因此不再标「在其他终端中打开」 |
| 删除前的核查 | 两个正面证据：活会话表里有目标，或本应用某个 pane（pid + 内核启动时间核对过）开着目标 | 无，codex 自己的写锁是权威 | 不读进程表。外部刚启动、还没登记进活会话表的 Claude 会话是看不见的 |
| 改名信号 | 终端标题的正文变了就重读官方列表（见[状态与上下文 hook](status-hooks.md)）；不监听转录文件 | 同左（线程名在标题里）；0.157 起另听共享后台进程的 `thread/name/updated` 广播（自动起名与 `/rename` 都发，见 `CodexSessionRouter`） | 标题的真值始终是官方列表，终端标题只决定什么时候重读；另在 `Stop` 和状态从非 thinking 变 thinking 时也重读 |

Claude 侧的 SDK 打包与许可见 `docs/specs/claude-sdk-distribution-research.md`。
