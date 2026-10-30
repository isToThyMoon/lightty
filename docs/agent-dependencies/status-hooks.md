# 状态与上下文（hook，它们调我们）

插件与 hook 的安装、两家各自的事件表与载荷、终端标题信号、嵌套会话与 Agent 进程身份、共享后台进程里的 pane 归属、handoff 注入。总览与入口见[依赖清单](../agent-dependencies.md)。

我们不改用户的 hook 配置，而是生成一个插件 marketplace（`~/.lightty/marketplace`），
用两家**自己的 CLI** 装进去。协议见 `docs/specs/pane-status.md`，安装与排查见 [hooks 文档](../hooks.md)。

| 功能 | Claude Code | Codex | 出问题时 |
|---|---|---|---|
| 安装 / 更新插件 | `claude plugin marketplace add <目录>`、`claude plugin install\|update lightty@lightty` | `codex plugin marketplace add <目录>`、`codex plugin add lightty@lightty` | 命令超时或失败：设置页显示原始错误；Codex 装完后下次运行会弹信任提示，不批准 hook 不执行 |
| 卸载 | `claude plugin uninstall`、`claude plugin marketplace remove lightty` | `codex plugin remove`、`… marketplace remove` | |
| 判断装没装、版本对不对 | 读 `settings.json` 的 `extraKnownMarketplaces` / `enabledPlugins` | 读 `config.toml` 的 `[marketplaces.lightty]` / `[plugins."lightty@lightty"]` | 文件损坏：显示「无法读取」。版本串带内容哈希，不一致就要求重装（两家都是**拷贝**插件进缓存，改我们的文件不会自动生效） |
| 插件里的 hook 定义 | `plugins/lightty/hooks/hooks.json`（目录约定） | `plugins/lightty/hooks.json`（清单指路） | 事件表不同：两家共有 `SessionStart`、`UserPromptSubmit`、`PreToolUse`、`PostToolUse`、`Stop`、`SessionEnd`；Claude 另有 `PostToolUseFailure`、`Notification`（Claude 的 `Stop` 在用户中断时不触发，这两个是替代信号），Codex 另有 `PermissionRequest`、`Interrupt` |
| hook 发回的状态 | `lightty-hook` 读 stdin 的 JSON（`hook_event_name`、`session_id`、`cwd`、`tool_name`、`tool_input`、`transcript_path`），经 socket 发给 lightty | 同一个二进制，Codex 沿用 Claude 兼容的载荷 | 任何一步失败静默 exit 0，agent 照跑。字段名变了：状态不更新，不崩 |
| 判断事件来自哪家 | 注册的命令行里就写着：`lightty-hook --agent claude` | `… --agent codex` | 这两份 hooks 文件是我们自己生成的，哪家读哪份是确定的。旧版插件没带这个参数，退回 `transcript_path` 形状 → 环境变量（`HookAgentDetection`，只作兼容）；认不出 agent 字段留空 |
| 终端标题：Agent 识别、改名信号、Claude 中断补偿 | 终端标题（OSC 0）`<前缀> <会话标题>`：◐ ◑ 忙、✳ 闲；按 Esc 中断即变 ✳，`/rename` 即推送 | 终端标题（OSC 0，`tui.terminal_title` 默认项）：braille 旋转字符 + `线程名 \| 项目名` 忙、无前缀闲、`[ ! ] Action Required` 等处理 | 形状写在 `AgentSpec.terminalTitle`，解析见 `AgentTerminalTitle`。活动状态以 hook 为准；仅 Claude 明确的闲前缀可把 thinking / tool 收回 idle，不覆盖 done / attention。Codex 有 `Interrupt`，hook 在管时标题不改状态；hook 全失效时标题与桌面通知（OSC 9）兜底推状态，见 [hooks 文档](../hooks/codex-terminal-fallback.md)。格式变了退回 hook，Claude 中断后可能停在「思考中」直到下次提问。Claude 的私有 OSC 21337 文字状态未启用，见 `docs/specs/pane-status.md` |
| 嵌套会话（工具里跑 `claude -p`） | 从 hook 的父进程往上走，到终端的前台作业组长之前经过了**脱离终端**的进程就算子会话，静默退出 | 同左 | 实测两家的工具子进程一律脱离终端（见 [进程识别](../specs/pane-status/process-identity.md)），不认进程名；找不到组长时**不按嵌套处理**，宁可多报一发状态。仅 Codex：链上一个带终端的进程都没有（被系统收养的共享后台进程）时静默，继承的 pane 不可信 |
| Agent 进程身份、退出检测 | hook 记下祖先链上最近的**前台作业组长**（`kinfo_proc` 的 `e_pgid` / `e_tpgid` / `e_tdev`）的 pid + 启动时间；lightty 用 `DispatchSource` 监视退出 | 同左；走会话路由记录时用记录里的界面进程 | npm 版 codex 的 node 包装、用户的启动脚本，组长就是包装进程，监视它等价；没有 pty 时身份留空，退化为只靠 `SessionEnd` |
| agent view 的后台会话在哪个 pane | agent view（2.1.28x）的后台会话跑在 supervisor 自己的伪终端里，hook 带的 pane 身份不可信：hook 按终端归属认出它，只认路由记录；记录由 `ClaudeAgentView` 按 pane 终端标题 + `claude agents --json` 写。规则与边界见 [hooks 文档](../hooks/claude-agent-view.md) | — | 标题或 `claude agents --json` 的 `name` / `kind` 变了：pane 不再跟着 agent view 切换，后台会话的 hook 静默（不会送错 pane）；前台会话不受影响 |
| 共享后台进程里的 hook 属于哪个 pane | 不涉及 | 0.157 起会话跑在共用的 app-server 后台进程里，hook 继承的 `LIGHTTY_PANE_ID` 属于拉起它的终端。lightty 经 `codex app-server proxy`（官方入口）旁听 `thread/started` / `thread/status/changed` / `thread/closed`，按进程事实把会话对到 pane，写 `~/.lightty/run/sessions/<session_id>`；hook 先查这条记录 | 广播字段变了或 `proxy` 不可用：写不出记录，hook 查不到就静默，Codex 会话没有状态但不会送错 pane。规则与边界见 [hooks 文档](../hooks/codex-shared-daemon.md) |
| 注入 handoff 文档 | `SessionStart` / `UserPromptSubmit` 返回 `hookSpecificOutput.additionalContext` | 同一格式 | 去重靠 `~/.lightty/panes/<uuid>/handoff.injected` |
| handoff 技能 | `plugins/lightty/skills/handoff/SKILL.md`，两家共用一份 | 同左 | 调用前缀不同，见[启动与恢复会话](launch-and-resume.md) |
