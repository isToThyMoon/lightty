# lightty 对 Claude Code / Codex 的依赖清单

lightty 与两家 CLI 的每一处接触点，按功能列出，每项写清两家各自的实现和出问题时的表现。
这是**总览与入口**，细节在各行指向的文档与源文件里，不在这里重复。

依赖分四种形状：**我们调它们**（子进程）、**它们调我们**（hook）、**它们写进终端的协议**
（OSC 0 标题、OSC 7 cwd）、**读写它们的文件**。每张表的「实现」列标明是哪一种。

每家 Agent 的常量（可执行名、配置根、显示名、命令行写法、hook 事件表、插件路径与动词）
写在 `Sources/LighttyCore/Agents/<家名>Agent.swift` 的一个 `AgentSpec` 里，
`SessionAgent.spec` 是全 app 唯一按家穷举的 switch。下面表里的每一格，值都从那里来。

## 一、启动与恢复会话

命令行只在 `Sources/lightty/AgentCommand.swift` 一处拼装。

| 功能 | Claude Code | Codex | 出问题时 |
|---|---|---|---|
| 找可执行文件 | 只在三段里找 `claude`：进程 PATH → 登录 shell 的 PATH（`LoginShellPath`）→ `/usr/bin:/bin:/usr/sbin:/sbin` | 同左，找 `codex` | 找不到：设置页显示「未检测到」，会话列表跳过这一家，重启后恢复 pane 只开终端不启动 Agent |
| 新会话 | `claude [--permission-mode bypassPermissions] [自定义参数]` | `codex [--yolo] [自定义参数]` | 参数取自设置，见 `AgentLaunchPreference` |
| 恢复会话 | `claude [参数] --resume <id>` | `codex resume [参数] <id>` | 会话 ID 来自 hook 或列表；配置根不是默认时用 `CLAUDE_CONFIG_DIR` / `CODEX_HOME` 显式传入 |
| 打开 CLI 自带的选择器 | `claude --resume` | `codex resume --all` | |
| 让开着的会话改名 | 往 TUI 粘 `/rename <名字>` | 同左 | 两家写法一致；会话没开时走第三节的官方接口 |
| 让开着的会话重写交接文档 | 往 TUI 粘 `/lightty:handoff <路径>` | 粘 `$lightty:handoff <路径>` | **插件没装或调用名写错两家都静默失败**，所以粘之前先查插件装没装；没装就粘完整指令（`HandoffProtocol.directInstruction`） |

配置根：`SessionConfigurationLocation`，`CLAUDE_CONFIG_DIR` / `CODEX_HOME` 设了就是自定义来源，否则是 `~/.claude` / `~/.codex`。

## 二、状态与上下文（hook，它们调我们）

我们不改用户的 hook 配置，而是生成一个插件 marketplace（`~/.lightty/marketplace`），
用两家**自己的 CLI** 装进去。协议见 `docs/specs/pane-status.md`，安装与排查见 `docs/hooks.md`。

| 功能 | Claude Code | Codex | 出问题时 |
|---|---|---|---|
| 安装 / 更新插件 | `claude plugin marketplace add <目录>`、`claude plugin install\|update lightty@lightty` | `codex plugin marketplace add <目录>`、`codex plugin add lightty@lightty` | 命令超时或失败：设置页显示原始错误；Codex 装完后下次运行会弹信任提示，不批准 hook 不执行 |
| 卸载 | `claude plugin uninstall`、`claude plugin marketplace remove lightty` | `codex plugin remove`、`… marketplace remove` | |
| 判断装没装、版本对不对 | 读 `settings.json` 的 `extraKnownMarketplaces` / `enabledPlugins` | 读 `config.toml` 的 `[marketplaces.lightty]` / `[plugins."lightty@lightty"]` | 文件损坏：显示「无法读取」。版本串带内容哈希，不一致就要求重装（两家都是**拷贝**插件进缓存，改我们的文件不会自动生效） |
| 插件里的 hook 定义 | `plugins/lightty/hooks/hooks.json`（目录约定） | `plugins/lightty/hooks.json`（清单指路） | 事件表不同：两家共有 `SessionStart`、`UserPromptSubmit`、`PreToolUse`、`PostToolUse`、`Stop`、`SessionEnd`；Claude 另有 `PostToolUseFailure`、`Notification`（Claude 的 `Stop` 在用户中断时不触发，这两个是替代信号），Codex 另有 `PermissionRequest`、`Interrupt` |
| hook 发回的状态 | `lightty-hook` 读 stdin 的 JSON（`hook_event_name`、`session_id`、`cwd`、`tool_name`、`tool_input`、`transcript_path`），经 socket 发给 lightty | 同一个二进制，Codex 沿用 Claude 兼容的载荷 | 任何一步失败静默 exit 0，agent 照跑。字段名变了：状态不更新，不崩 |
| 判断事件来自哪家 | 注册的命令行里就写着：`lightty-hook --agent claude` | `… --agent codex` | 这两份 hooks 文件是我们自己生成的，哪家读哪份是确定的。旧版插件没带这个参数，退回 `transcript_path` 形状 → 环境变量（`HookAgentDetection`，只作兼容）；认不出 agent 字段留空 |
| 忙 / 闲 / 等处理、会话改名的即时信号 | 终端标题（OSC 0）`<前缀> <会话标题>`：◐ ◑ 忙、✳ 闲；按 Esc 中断即变 ✳，`/rename` 即推送 | 终端标题（OSC 0，`tui.terminal_title` 默认项）：braille 旋转字符 + `线程名 \| 项目名` 忙、无前缀闲、`[ ! ] Action Required` 等处理 | 形状写在 `AgentSpec.terminalTitle`，解析见 `AgentTerminalTitle`。格式变了：解析成 nil 或认成闲，退回只靠 hook——Claude 按 Esc 后停在「思考中」直到下次提问；Codex 有 `Interrupt`，不缺边。Claude 另备有私有 OSC 21337 文字状态，2.1.274 未启用 |
| 嵌套会话（工具里跑 `claude -p`） | 从 hook 的父进程往上走，到终端的前台作业组长之前经过了**脱离终端**的进程就算子会话，静默退出 | 同左 | 实测两家的工具子进程一律脱离终端（见 `docs/specs/pane-status.md` §2.1），不认进程名；找不到组长时**不按嵌套处理**，宁可多报一发状态 |
| Agent 进程身份、退出检测 | hook 记下祖先链上最近的**前台作业组长**（`kinfo_proc` 的 `e_pgid` / `e_tpgid` / `e_tdev`）的 pid + 启动时间；lightty 用 `DispatchSource` 监视退出 | 同左 | npm 版 codex 的 node 包装、用户的启动脚本，组长就是包装进程，监视它等价；没有 pty 时身份留空，退化为只靠 `SessionEnd` |
| 注入 handoff 文档 | `SessionStart` / `UserPromptSubmit` 返回 `hookSpecificOutput.additionalContext` | 同一格式 | 去重靠 `~/.lightty/panes/<uuid>/handoff.injected` |
| handoff 技能 | `plugins/lightty/skills/handoff/SKILL.md`，两家共用一份 | 同左 | 调用前缀不同，见第一节 |

## 三、会话列表、改名、删除、占用

每项接口的取舍理由见 `docs/specs/agent-session-apis.md`；删除的边界见 `docs/session-deletion-research.md`。

| 功能 | Claude Code | Codex | 出问题时 |
|---|---|---|---|
| 列会话 | **不调 claude**。打包的 Node 运行时跑 `@anthropic-ai/claude-agent-sdk 0.3.263` 的 `list-sessions.mjs`（`listSessions`，每页 100，按 offset 翻页） | `codex app-server --listen stdio://`，JSON-RPC `initialize` → `initialized` → `thread/list`（含 `archived`） | SDK 缺失：报「helper 丢失」；app-server 超时（单次 12 秒、整体 45 秒）或格式不认识：这一家显示错误，另一家照常 |
| 补工作目录 | SDK 只在转录头 64KB 找 `cwd`，找不到时 helper 往后多读转录文件 | app-server 直接给 | |
| 改名 | `rename-session.mjs`（`renameSession`） | `thread/name/set` | |
| 删除 | `delete-session.mjs`（`deleteSession`） | `codex delete --force <id>` | 删除前先做占用检查 |
| 判断是否有人在用 | 只问 `claude agents --json`（pid ↔ sessionId）；表里没有就是「问不出来」 | 没有对等接口，一律「问不出来」 | 「问不出来」和「没人用」严格区分：前者删除时弹确认，后者才放行。Codex 会话因此不再标「在其他终端中打开」 |
| 删除前的核查 | 两个正面证据：活会话表里有目标，或本应用某个 pane（pid + 内核启动时间核对过）开着目标 | 无，codex 自己的写锁是权威 | 不读进程表。外部刚启动、还没登记进活会话表的 Claude 会话是看不见的 |
| 改名信号 | 终端标题的正文变了就重读官方列表（第二节）；不监听转录文件 | 同左（线程名在标题里） | 标题的真值始终是官方列表，终端标题只决定什么时候重读；另在 `Stop` 和状态从非 thinking 变 thinking 时也重读 |

Claude 侧的 SDK 打包与许可见 `docs/specs/claude-sdk-distribution-research.md`。

## 四、设置页读写的配置

只读为主，写入只改一个布尔值，先备份（`*.lightty-backup`）再原子替换。

| 页面 | Claude Code | Codex | 写入 |
|---|---|---|---|
| Skills | `~/.claude/skills`；共享目录 `~/.agents/skills` 与 `~/.agents/.skill-lock.json` | `$CODEX_HOME/skills`，内置技能 `skills/.system` | 不写技能目录；收藏 / 标签存 `~/.lightty/skills-organization.json` |
| Plugins | `~/.claude/plugins/installed_plugins.json` + `settings.json` 的 `enabledPlugins`；使用计数读 `~/.claude.json` 的 `pluginUsage` / `skillUsage` | `codex plugin list --json` 拿清单，再读 `plugins/cache` 里的内容；命令失败沿用上次结果 | Claude 改 `settings.json` 的 `enabledPlugins`；Codex 改 `config.toml` 的 `[plugins."…"].enabled` |
| MCP | `~/.claude.json` 的 `mcpServers`（没有启用开关，配了就是开着） | `config.toml` 的 `[mcp_servers.*]` 与其 `enabled` | 只有 Codex 可切换 |
| Handoff | 读插件安装状态（第二节） | 同左 | 无 |

## 五、安装方式

**我们对安装方式只有一个假设：CLI 在 tty 的 PATH 上。** 找可执行文件只看进程 PATH、
登录 shell 的 PATH 和系统目录（见第一节），不写死 homebrew / nvm / volta / pnpm 那一串目录，
也不按安装路径的形状认身份。理由：pane 里跑的就是这个登录 shell，它的 PATH 看不见的 CLI，
用户自己在终端里也敲不出来；替他找到反而更糟——设置页说「已检测到」，真去 pane 里启动却失败。

hook 认「哪个进程是 agent」也不看名字，只看终端作业结构（第二节），所以原生安装的
`versions/<版本号>`、npm 的 `claude.exe`、node 包装脚本这些差异都不再进入任何判断。

不支持的两种安装：Claude 桌面应用自带的 Claude Code；ChatGPT.app 自带的 `codex`
（不在 PATH，也不是给命令行用的）。

唯一还与安装方式有关的实现细节：npm 装的 codex 是个 node 包装脚本再启动平台包里的原生
`codex`，强杀时要连子进程一起杀（`ProcessTree`），否则留孤儿。

## 六、脆弱程度

改了会**直接失效**的，按影响面排序：

1. hook 载荷字段名、`hookSpecificOutput.additionalContext` 协议、插件目录约定 —— 状态、绑定、注入全没。
2. `codex app-server` 的方法名与响应形状（官方仍标 experimental）—— Codex 会话列表与改名。
3. `@anthropic-ai/claude-agent-sdk` 的 `listSessions` / `renameSession` / `deleteSession` —— Claude 会话列表；版本锁在 `scripts/claude-session-helper/package.json`。
4. `claude agents --json` 的输出格式 —— 占用一律变成「问不出来」，删除时每次都弹确认。
5. `claude plugin …` / `codex plugin …` 子命令形状 —— hook 装不上，已装的照常工作。

改了只是**功能变弱**的：终端标题的前缀格式（Claude 中断后停在「思考中」、改名延后）、配置文件的键名（设置页显示不全）、CLI 在 PATH 上的位置（找不到 CLI）。
这些都必须退化成「问不出来」或空列表，不能崩、也不能把「不知道」当成「没有」。

## 相关文档

- `docs/hooks.md`：hook 安装、Codex 信任提示、排查
- `docs/specs/pane-status.md`：状态报文、状态机、handoff 注入与写回
- `docs/terminal-associations.md`：pane、会话、任务、Agent 进程的绑定关系
- `docs/specs/agent-session-apis.md`：会话操作的官方接口清单
- `docs/session-deletion-research.md`、`docs/specs/claude-sdk-distribution-research.md`
- `docs/specs/skills-settings.md`、`plugins-settings.md`、`mcp-settings.md`、`handoff-settings.md`
