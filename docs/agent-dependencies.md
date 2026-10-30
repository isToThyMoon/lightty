# lightty 对 Claude Code / Codex 的依赖清单

lightty 与两家 CLI 的每一处接触点，按功能列出，每项写清两家各自的实现和出问题时的表现。
这是**总览与入口**：形状与归属在这里，按功能分开的接触点表在 `agent-dependencies/` 下，按任务读对应的一份。

依赖分四种形状：**我们调它们**（子进程）、**它们调我们**（hook）、**它们写进终端的协议**
（OSC 0 标题、OSC 7 cwd）、**读写它们的文件**。每张表的「实现」列标明是哪一种。

## 归属

每家 Agent 的常量（可执行名、配置根、显示名、命令行写法、hook 事件表、插件路径与动词）
写在 `Sources/LighttyCore/Agents/<家名>Agent.swift` 的一个 `AgentSpec` 里，
`SessionAgent.spec` 是全 app 唯一按家穷举的 switch。各表里的每一格，值都从那里来。

- 命令行只在 `Sources/lightty/AgentCommand.swift`（`AgentCommand`）一处拼装。
- 调 CLI 与 node helper 的进程环境（清 `LIGHTTY_*`、PATH、配置目录变量、arm64 运行时路径）只在 `AgentHelperProcess` 里拼。
- 会话的列表、改名、删除、占用都经 `AgentSessionProvider`（`ClaudeSessionProvider` / `CodexSessionProvider`，由 `SessionCatalogSource.makeProvider` 选择），两家差异只在 provider 里。
- 配置根：`SessionConfigurationLocation`，`CLAUDE_CONFIG_DIR` / `CODEX_HOME` 设了就是自定义来源，否则是 `~/.claude` / `~/.codex`。

## 按任务读哪份

- 改启动或恢复会话的命令行、找不到 CLI、安装方式相关判断、往开着的会话里粘 `/rename` 或 handoff 指令时，读[启动与恢复会话](agent-dependencies/launch-and-resume.md)。
- 改 hook 插件的安装与卸载、事件表与载荷、终端标题识别、嵌套会话、Agent 进程身份与退出检测、共享后台进程或 agent view 的 pane 归属、handoff 注入时，读[状态与上下文 hook](agent-dependencies/status-hooks.md)。
- 改会话列表、改名、删除、占用检查，或 `codex app-server` / Claude SDK helper 的调用时，读[会话列表、改名、删除、占用](agent-dependencies/sessions.md)。
- 改设置页的 Skills / Plugins / MCP / Handoff 读写的配置文件时，读[设置页读写的配置](agent-dependencies/settings-config.md)。
- 升级 CLI 后评估影响面、判断某个改动会直接失效还是只是功能变弱、输出速度计依赖的日志格式时，读[脆弱程度与输出速度](agent-dependencies/fragility.md)。

## 相关文档

- [兼容验证](agent-compatibility.md)：统一执行入口、按功能的报告与验证边界
- `docs/hooks.md`：hook 安装、Codex 信任提示、排查
- `docs/specs/pane-status.md`：状态报文、状态机、handoff 注入与写回
- `docs/specs/output-speed.md`：输出速度的日志字段与计算口径
- `docs/terminal-associations.md`：pane、会话、任务、Agent 进程的绑定关系
- `docs/specs/agent-session-apis.md`：会话操作的官方接口清单
- `docs/session-deletion-research.md`、`docs/specs/claude-sdk-distribution-research.md`
- `docs/specs/skills-settings.md`、`plugins-settings.md`、`mcp-settings.md`、`handoff-settings.md`
