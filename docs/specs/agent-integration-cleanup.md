# Agent 接入清理与按家收敛：实施计划

目标：去掉对 Claude Code / Codex **非官方接口**的依赖，把每家 Agent 的知识收进各自一个文件。
依赖现状见 `docs/agent-dependencies.md`。

判断标准（用户定）：CLI 命令行、官方 SDK、`codex app-server`、hook 协议算干净；
读进程表 / 文件表推断、监听私有文件、按安装路径猜身份不算。

## 总览

| 阶段 | 内容 | 依赖 |
|---|---|---|
| A1 | 占用检测只用官方接口，删掉 `lsof` / `ps` | 无 |
| A2 | 删掉转录文件监听，标题靠 hook 事件刷新 | 与 A1 同改 `AgentSessionProvider`、`SessionLibrary`，**同一个人做** |
| A3 | hook 命令行显式带 `--agent`，不再按路径猜身份 | 无 |
| A4 | 找 CLI 只看 tty 的 PATH，删掉写死的目录清单 | 无（与 A3 同一个人做，文件不重叠但都小） |
| B | `AgentSpec`：每家一个文件，枚举只剩一个 switch | A 全部合入之后 |
| C | 文档：`docs/agent-dependencies.md`、`agent-session-apis.md`、`hooks.md`、`session-deletion-research.md` | B 之后 |

每阶段的验收：`unset LIGHTTY_PANE_ID LIGHTTY_SOCK; swift test` 全量 0 失败；
新增测试遵守 `HANDOVER.md`「全量测试要点」（不建 surface、不上屏、不写固定等待、不钉外观）。
**绝不启动第二个 lightty 实例**（`swift run`、`open`、`check-config-parity.sh` 都不许跑）。

## A1 占用检测只用官方接口

### 现状

- Claude：`occupancy` 先问 `claude agents --json`，问不出再 `ps` 找 claude 进程 + `lsof -p` 看谁写着
  `projects/<slug>/<id>.jsonl`；`checkDeletable` 读进程表，要求每个 claude 进程都能对上会话，
  刚启动未登记的等 `registrationWait` 再看一次。
- Codex：`occupancy` / `observeLiveSessions` 全靠 `lsof -c codex` 看谁写着 `rollout-*-<id>.jsonl`。
- 这两条路是全部「安装方式假设」（进程名是版本号、`claude.exe`）的来源。

### 目标行为

| | Claude | Codex |
|---|---|---|
| `occupancy(of:)` | `claude agents --json` 里有这段会话 → `.inUse(pid)`；否则 `.unknown` | 恒 `.unknown` |
| `checkDeletable` | 表读不到 → `unknownOccupancy(nil)`；表里有目标 → `occupiedProcess(pid)`；`known`（本应用 pane 核对过的 pid）里有目标 → `occupiedProcess`；否则通过 | 不变（空实现，codex 自己的写锁是权威） |
| `observeLiveSessions` | 不变（`claude agents --json` 给 pid 与 cwd） | 返回 nil |

后果与接受的代价：Codex 会话不再标「在其他终端中打开」，也不再补工作目录；删除别处开着的
Codex 会话时，由 codex 的写锁拒绝，界面显示 `Failure.failed` 的文案。Claude 刚启动 5 秒内
还没登记进活会话表的外部会话，删除不再有等待重试；接受。

### 改动清单

- 删 `Sources/lightty/SessionOccupancy.swift` 里的 `Owner`、`openFiles`、`forEachWritableSessionFile`、
  `firstWriter`；`Result` 枚举搬到 `AgentSessionProvider.swift`（名字可保留 `SessionOccupancy.Result`
  以少动调用方，但文件里只剩这个枚举时应把文件删掉）。
- `ClaudeSessionProvider`：删 `processTable`、`claudeProcesses`、`inspect`、`unidentifiedProcesses`、
  `inspectProcesses`、`DeletionProbe.processTable` / `identity` / `wait`、`registrationWindow` / `registrationWait`。
  `checkDeletable(_:known:probe:)` 只剩「读活会话表 + 对照 known」，`DeletionProbe` 只保留
  `liveSessions`。文件头注释同步改。
- `CodexSessionProvider`：删 `occupancy` 的 lsof 分支、`inspect`、`decodeOpenSessionPIDs`、`observeLiveSessions` 的实现、
  `transcriptDirectories`。
- `AgentSession.swift` 里 `executableName` 的注释「也是 `lsof -c` / `ps` 里看到的进程名」改掉。
- **保留** `ProcessTree`（npm 版 codex 强杀连子进程仍然需要）。
- 测试：删 `SessionOccupancyTests`（`testClaudeLiveRegistryDecodesOrRefuses` 搬到 `ClaudeSessionCatalogTests`）；
  `SessionDeletionTests` 里 `unrelatedClaudeDoesNotBlockDeletion` 与 `ProbeScript` 一组登记窗口测试改写成
  「活会话表 × known」的表驱动测试：表不可读 → unknown；表里有目标 → occupied；known 里有目标 → occupied；
  都没有 → 通过；known 里的 pid 已换人（`identity` 不等）不算。`AgentSessionProviderTests` 里用假 provider 的不动。
- `Localizable.strings`：`unknownOccupancy` 文案里「external or unassociated Claude process」如仍准确则不动。

## A2 标题刷新只靠 hook 事件

### 现状

`SessionTitleSignals` 监听 Claude 的 `projects/*/<id>.jsonl` 与 Codex 的 `session_index.jsonl`，
文件一变就重读官方列表。理由是终端里敲 `/rename` 不触发 hook。

### 目标行为

- 删 `SessionTitleSignals`、协议里的 `titleSignalFiles` / `titleSignalRequiresIdleSession`、
  `SessionLibrary.titleFileChanged` / `syncTitleSignals` / `titleSignals`、`SessionTitleSignalTests`、
  `SessionProviderFakes` 里对应的桩。
- 刷新时机：已有的两条不动——lightty 自己发的 `/rename` 之后 `PaneView.renameSession` 调
  `invalidateMetadata`；hook 报 `.done` 时 `statusDidChange` 调 `invalidateMetadata`。
  **新增一条**：状态从非 thinking 变为 thinking（`UserPromptSubmit` 到达，用户开始下一轮）时也
  `invalidateMetadata`，这样用户手敲 `/rename` 后一提问标题就更新，不必等回合结束。
  `invalidateMetadata` 已有 5 次有界重试，不再加别的。
- 接受的代价：Codex 自动生成的标题要到下一次 hook 事件才显示；用户手敲 `/rename` 后一直不提问，
  标题停在旧名直到下次刷新。

### 测试

`SessionLibraryTests`（或最贴近的现有套件）加一条：假 provider 先返回旧标题，pane 状态从 done 变 thinking
后列表重读并显示新标题；`.done` 那条若已有则不重复。

## A3 hook 显式带 `--agent`

### 现状

`lightty-hook` 靠父进程链上的可执行路径认是哪家（`HookAgentDetection.agent`），退回看 `transcript_path` 形状，
再退回环境变量。路径形状随安装方式变（原生是 `versions/<版本号>`，npm 是 `claude.exe`）。

### 目标行为

- `HookMarketplace.hooksDocument(for:command:)` 写进两家 hooks 文件的命令改为
  `"<shim 路径> --agent claude"` / `"<shim 路径> --agent codex"`。两家的 hook 命令都经 shell 执行，
  参数会原样传到 hook。路径先不加引号（现状也没加；`~/.lightty/bin` 不含空格）。
  版本串由内容哈希得出，改了自然要求用户重装一次，正常。
- `lightty-hook`：解析 `--agent <名>`，`SessionAgent(rawValue:)` 认得就直接用；**没给**（用户装的还是旧版
  插件）才走现有 `detectAgent(payload:)`。旧路保留是为兼容，注释写明。
- `AgentProcessIdentity.agentAncestor(startingAt:)` 加 `agent:` 参数：已知是哪家时只认那一家的祖先
  进程，跨家嵌套不会认错人。找进程仍要走父进程链、按路径认（这一步没有官方替代，`HookAgentDetection.agentInPath`
  与 `isNestedSession` 保留）。
- `HookAgentDetection.agent(...)` 保留作兼容退路，不再是主路径。

### 测试

- `HookMarketplaceTests`：两家 hooks 文档里每条命令都以 ` --agent <名>` 结尾，且两家不同。
- `HookAgentEndToEndTests.testAgentIsIdentifiedByTheParentProcessChain` 改为「`--agent` 优先于链、载荷与环境；
  没给 `--agent` 时退回链」。仍用真实 hook 二进制。
- `HookAgentDetectionTests` 不删，标题改成说明它测的是兼容退路。

## A4 找 CLI 只看 tty 的 PATH

### 现状

`HookInstaller.searchPath()` = 进程 PATH → 登录 shell PATH（`LoginShellPath`）→ 写死的十几个常见目录
（homebrew、nvm、volta、fnm、pnpm、bun…）→ 系统目录。

### 目标行为

- 删掉写死的目录清单与 `nvmBinDirectories`，只剩：进程 PATH → 登录 shell PATH → `/usr/bin:/bin:/usr/sbin:/sbin`。
  理由：pane 里的 shell 就是登录 shell，它看不到的 CLI 用户自己也敲不了。
- `LoginShellPath.prime()` 首启同步解析（2 秒上限）不变。
- 测试：`LoginShellPathTests` 里 `testSearchPathIncludesLoginShellDirectoriesAndVersionManagers` 改成只断言
  三段顺序与去重；删 `testNvmVersionsAreListedNewestFirst`。

## B `AgentSpec`：每家一个文件

### 现状

四个枚举（`SessionAgent`、`HookAgent`、`PluginAgent`、`LaunchAgent`）各自穷举 switch，散在
`AgentSession.swift`、`HookInstaller.swift`、`AgentLaunchPreference.swift`、`HookMarketplace.swift`、
`PluginCatalog.swift`、`HookSetupOverlay.swift`、`AgentSessionProvider.swift`、`AgentSessionIcon.swift`。
用户已决定**保留这几个枚举并存**（rawValue 已写进用户偏好），不合并。

### 目标

- 新建 `Sources/LighttyCore/AgentSpec.swift`：一个 struct，字段是**纯数据**——
  `executableName`、`configurationVariable`、`standardConfigurationDirectory`、`sourceName`、`launchName`、
  `iconToolTip`、`resumeShape`（flag 在前还是子命令在前）、`pickerArguments`、`bypassArguments`、
  `skillInvocationSigil`、`hookEvents`、`hookInstallCommands(marketplaceRoot:isInstalled:)`、
  `hookUninstallCommands(...)`、`hookConfigFile`（相对配置根）、`hooksDocumentPath`（插件里 hooks 文件相对路径）、
  `pluginManifestPath`、`marketplaceManifestPath`。凡是现在某个 switch 里返回的常量或纯函数，都进来。
- 新建 `Sources/LighttyCore/Agents/ClaudeAgent.swift`、`CodexAgent.swift`，各一个 `static let spec`。
- `SessionAgent.spec` 是**唯一**的穷举 switch；其余属性一律 `spec.xxx`。`HookAgent`、`LaunchAgent`、`PluginAgent`
  的 `init(_ agent:)` / `sessionAgent` 映射保留（那是枚举之间的桥），其余 switch 改成经 `sessionAgent.spec`。
- 不能纯数据化的留在原地，但按家拆到各自扩展里：`AgentSessionProvider` 工厂（`makeProvider` 的 switch 改成
  `spec.makeProvider`？——**不要**：LighttyCore 不依赖 app 目标；保留 `SessionCatalogSource.makeProvider` 这一个 switch）；
  `HookAgent.readDeclaration` 的 JSON / TOML 读法各留一个私有函数，按 `spec.hookConfigFormat` 分派。
- 设置页三个目录（Skills / Plugins / MCP）的按家读取**不动**，记为后续项。
- 加一家新 Agent 的路径：枚举加 case → 编译错误只落在 `spec` 那一个 switch 与几处枚举桥 → 新建一个
  `XxxAgent.swift`。没有的能力用可选项表达（例如 `hookEvents: nil` 表示这家没有插件 / hook 机制），
  调用方按 nil 隐藏功能。**本阶段不真的加第三家**，但要有一条测试证明：spec 的每个字段两家都填了、
  且两家不完全相同（防复制粘贴）。

### 验收

行为零变化：全量测试不改断言只改类型名；`HookMarketplace.version(for:)` 两家的版本串在改前后**必须相同**
（改前先记下来，改后比对——否则用户会无故看到「有更新」）。

## C 文档

- `docs/agent-dependencies.md`：删「安装方式的假设」大部分内容（只剩「找 CLI 只看 tty 的 PATH」与不支持项）；
  第三节占用检测、改名信号两行改成新做法；第二节「判断事件来自哪家」改成 `--agent`；第六节脆弱程度去掉 `lsof`。
- `docs/specs/agent-session-apis.md`「占用检测为什么两家不一样」「改名为什么分两条路」两节改写。
- `docs/hooks.md`：注册命令那段加 `--agent`；排查里手动喂事件的例子加 `--agent claude`。
- `docs/session-deletion-research.md`：实现小节补一句「进程表核查已移除，只认活会话表与本应用 pane」。
- `HANDOVER.md`：架构段落提一句 `AgentSpec` 与「加一家 Agent 只加一个文件」。
- 本文件末尾补「实施结果与验收」。

## 执行方式

- A1+A2 一个 agent，A3+A4 一个 agent，各自 worktree 并行；合入 main 后再起 B；C 随 B。
- worktree 里要从主检出软链 `Frameworks/GhosttyKit.xcframework` 与 `.build/claude-session-helper`。
- 提交信息不加 Co-Authored-By / Claude-Session 尾注。
- 做过进程类实验后按 PPID 1 扫残留：`ps -axo pid,ppid,etime,%cpu,command | awk '$2==1'`。

## 实施结果与验收

全部阶段已落地。改动内容看提交，这里只记落点与验收结论，不复制正文。

| 阶段 | 提交 |
|---|---|
| A1 占用检测只用官方接口 | `342f30f` |
| A2 标题刷新只靠 hook 事件 | `087746c` |
| A3 hook 显式带 `--agent` | `8f84a83` |
| A4 找 CLI 只看 tty 的 PATH | `4068890` |
| B `AgentSpec`：每家一个文件 | `a4bd380` |
| C 文档 | `a5b5578` |
| D 找 agent 进程只看终端结构 | `d826663` + 本次提交 |

当前契约已写进常驻文档，不在这里重复：接触点清单见 `docs/agent-dependencies.md`，
会话接口取舍见 `docs/specs/agent-session-apis.md`，hook 安装与排查见 `docs/hooks.md`，
删除边界见 `docs/session-deletion-research.md`，`AgentSpec` 的位置与「加一家 Agent
只加一个文件」见 `HANDOVER.md`「当前实现入口」。

### B 阶段的验收

- **行为零变化**：`HookMarketplace.version(for:command:)` 用同一个 command
  （`/Users/u/.lightty/bin/lightty-hook`）改前改后逐字相同——Claude Code `0.1.0+d58384fc`、
  Codex `0.1.0+ff31a2c8`。版本串一变就是所有既有用户无故看到一次「有更新」。
- 全量测试不改断言，只新增一条：`AgentDescriptionTests`
  `everySpecFieldIsFilledInAndDiffersBetweenTheAgents` 用 `Mirror` 逐字段比两家的 spec，
  空值与两家相同都算失败。加字段自动进这条断言，防的是「抄一份改一半」。

### D 阶段的验收

- 结构规则写进了 `docs/specs/pane-status.md` §2.1（含实测事实表），`docs/agent-dependencies.md`
  第二节两行与第五节、`docs/hooks.md` 的子会话与排查段随之改写。
- `HookMarketplace.version` 不受影响：hook 命令行与两份 hooks 文档一个字没动。
- 判定是纯函数 `AgentProcessIdentity.foregroundJobLeader(in:)`，表驱动覆盖实测表的八行
  加「没有 pty」；端到端 `HookAgentEndToEndTests` 用 `script -q /dev/null` 造真 pty，
  跑真实二进制覆盖主会话 / 包装 / 子会话 / 无 pty 四种位置。
- **凡是直接 `Process` 起真 hook 的用例都得改**：hook 每一发都先判子会话，而测试进程的
  祖先链取决于谁在跑 `swift test`。在某个 agent 的 Bash 工具里跑，实测
  `xctest → swift-package → zsh` 三层都已脱离终端、再往上才是终端上的 agent，
  hook 会正确地静默。`HookHandoffTests` 因此一并改走 `HookLauncher` 造 pty；
  `PaneStatusLoadTests`（默认跳过的压测）测的就是裸 spawn 成本，不加 pty，只加了
  「必须在真终端里跑」的注释。

### 没做、留作后续的

- **agent 不在前台时会认错组长**：`claude &` 放后台、或 Ctrl-Z 挂起后从别处触发 hook 时，
  前台作业组长是 pane 的 shell，会被记成 agent 进程（监视一个不会退出的 shell）。
  实际路径上 hook 只在 agent 跑着时才触发，没构造出真实场景；要不要加「组长必须是
  hook 的祖先中最近的那一个之下」之类的限制，由用户定。
- 设置页三个目录（Skills / Plugins / MCP）按家读取配置的那些分支没动，
  其中 `.claude-plugin` / `.codex-plugin` 这两个目录名与 `AgentSpec.pluginManifestPath`
  是同一个事实，现在写在两处。
- `HookMarketplace` 里两份插件清单与两份 marketplace 清单的**内容**仍各是一个 switch：
  它们引用应用侧的 marketplace / 插件名，且是任意嵌套的 JSON，进纯数据 spec 只会换来
  一个不 Sendable 的字段。
- `Localizable.strings` 的 `unknownOccupancy` 文案（“external or unassociated Claude
  process… check that process”）在 A1 之后只在活会话表读不出时触发、pid 恒为 nil，
  措辞已不准。改成什么由用户定。

## D 找 agent 进程只看终端结构，不认名字

### 现状

`--agent` 之后，hook 仍要回答「父进程链上哪个进程是 agent」（记 pid + 启动时间给退出监视、
删除核查、「在其他终端中打开」）和「这发 hook 是不是工具里起的子会话」。这两件事仍靠
`HookAgentDetection.agentInPath` 按路径认名字（`claude`、`claude.exe`、`codex`、含 `claude` 段），
是最后一处随安装方式变化的知识。

### 实测事实（2026-09-16，Claude Code 2.1.274、Codex 0.154.0，`script` 造 pty，记录 hook 的祖先链）

| 进程 | 进程组 | 终端前台组 | 控制终端 |
|---|---|---|---|
| Claude 主会话（pty 上） | = 自己 pid | = 自己 pid | 有 |
| Claude 起的 hook（`sh -c`） | 自己一组 | 0 | **无**（Claude 把 hook 脱离终端） |
| Claude 的 Bash 工具子进程 | 自己一组 | 0 | 无 |
| 工具里起的 `claude -p` | 沿用工具 shell 的组 | 0 | 无 |
| Codex 主会话（pty 上） | = 自己 pid | = 自己 pid | 有 |
| Codex 起的 hook | 自己一组 | = codex pid | 有 |
| Codex 的 shell 工具子进程 | 自己一组 | 0 | 无 |
| 工具里起的 `codex exec` | 沿用工具 shell 的组 | 0 | 无 |

两家一致：主会话是终端的**前台作业组长**（pid = 进程组 = 前台组，有控制终端）；工具子进程一律**脱离终端**。

### 目标行为

- **agent 进程** = hook 父进程链上最近的、有控制终端且 `pid == e_pgid == e_tpgid` 的进程
  （`kinfo_proc` 的 `e_tdev != NODEV`、`e_pgid`、`e_tpgid`，`sysctl KERN_PROC_PID` 读，
  不用 `proc_pidpath`）。npm 版 codex 的 node 包装、用户的启动脚本，组长就是包装进程，监视它退出等价。
- **嵌套** = 从 hook 的父进程往上走到组长之前，经过了**没有控制终端**的进程。
  主会话：hook 父进程就是组长，中间为空 → 不嵌套。npm 包装：中间只有带终端的 codex → 不嵌套。
  工具里起的子会话：中间有脱离终端的内层 agent 与工具 shell → 嵌套，静默退出。
- 找不到组长（agent 被 Ctrl-Z 挂起、hook 在没有 pty 的环境里跑）：不记进程身份，**不按嵌套处理**
  （宁可多报一发状态，不能把主会话的事件丢掉）。
- `HookAgentDetection.agentInPath`、`isNestedSession(ancestorExecutablePaths:)` 与 `agent(...)` 里的
  父进程链那一段全部删除；`--agent` 缺失时的兼容退路只剩 `transcript_path` 形状与环境变量。
  `AgentProcessIdentity.agentAncestor(startingAt:agent:)` 改名为按结构找组长的函数，不再收 agent 名。
  上一版为安装方式写的路径样本测试（`testEveryInstallMethodIsRecognizedInTheProcessChain` 等）一并删。
- `lightty-hook` 里 `ancestorExecutablePaths` 只剩「走到 lightty 为止」这一用途时也删掉，
  嵌套判断改用上面的结构规则（lightty 自己不是作业组长，不会被误认）。
- `SessionLibrary.isExternalProcess`（判断 `claude agents --json` 报的 pid 是不是 lightty 后代）不动。

### 测试

- `AgentProcessIdentity`（或新类型）的纯函数：输入一条祖先链的 `(pid, pgid, tpgid, hasTTY)` 表，
  输出组长与是否嵌套。表驱动覆盖上表八种情形加「找不到组长」。
- `HookAgentEndToEndTests` 用 `script -q /dev/null` 造 pty 跑真实 hook：
  主会话（假 agent 是 pty 上的前台作业）→ 报文里的 `agentProcess` 是它；
  包装（前台作业再起一个带终端的子 shell 去跑 hook）→ 身份是外层；
  嵌套（前台作业用 `setsid` 起脱离终端的子 shell 再跑 hook）→ 静默；
  无 pty → 有报文、无进程身份。
- 其余测试不改断言。

### 验收

全量 0 失败；`HookMarketplace.version` 不受影响（hook 文档没变）。`docs/agent-dependencies.md`
第二节「嵌套会话」「Agent 进程身份」两行与第五节改成结构规则；`docs/specs/pane-status.md` §2 补上表。
