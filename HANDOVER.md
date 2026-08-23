# 🧭 HANDOVER: 多终端 / 多 Session 任务追溯管理系统（lightty）

> ✅ **本页已自足可重建**：第 9 节声明的"最小重建集"中除本文外的文件（docs 两份、scripts、Package.swift）均已作为本页子页面逐字镜像。重建路径：读本页 → 按第 9 节 vendor SHA 取源 → 按第 10 节环境坑与构建命令编 GhosttyKit → 按子页面附件搭工程 → 按第 6-8 节决议实现功能。仓库 `~/project/ai/lightty` 为真源，代码与 git 历史不在镜像范围（预期）。
>
> 用途：本文件本身就是一份 handoff 文档示例，记录"如何解决 Claude Code / Codex 多 terminal 任务丢失追溯"这个需求的设计过程。下次继续这个需求时，先读这份文件，而不是从头回忆。

---

## 1. 我想做什么（目标）

构建一个**独立于 Claude Code / Codex 之外**的轻量索引系统，解决三个具体痛点：

1. **看不到清单**：终端窗口一多，不知道现在到底有几个任务在跑、分别是什么内容，只能靠肉眼扫 tab 或 tmux window 名字猜。
2. **关闭后找不回**：终端关掉（或电脑重启、SSH 断开）后，下次想接着做，只能靠 `claude --resume` / `--continue` 翻历史，而这套机制是按**工作目录**索引的，不是按**任务语义**索引的——目录对不上就找不到，找到了也只能看第一条消息当预览，无法判断"这是关于什么、进展到哪"。
3. **Claude Code 和 Codex 混用时没有统一视图**：两个工具的 session 存储格式、路径、resume 命令都不一样，没有一个共同的地方能看到"我今天到底开了哪些任务、分别用哪个工具、进展如何"。

期望的最终形态：**一个总控清单文件（或轻量数据库）+ 每个任务自带的 handoff 文档 + 一套"开任务自动登记、收工自动写总结"的脚本/hook**，让"回来接着干"这件事变成"看清单 → 找到对应 handoff → 直接继续"，而不是"开一堆终端窗口试图回忆"。

---

## 2. 当前的初步方案（尚未落地，仅停留在讨论阶段）

### 2.1 三层结构设想

- **L1 项目级记忆**：`CLAUDE.md`，存放几乎不变的架构/约定/坑，一次写好长期复用。
- **L2 任务级记忆**：每个 worktree/task 目录下的 `HANDOVER.md`，活的日志，每次收工前追加带日期的记录（做了什么、测什么、卡在哪、下一步）。
- **L3 全局索引**：目前设想的是一个 `~/dev/_index.md` 或 SQLite/JSON 文件，字段大致包括：
	- 任务名 / worktree 路径 / 关联分支
	- 使用的工具（Claude Code / Codex）
	- tmux session 名（如果用 tmux）
	- 状态（进行中 / 等 review / 卡住 / 已完成待合并）
	- handoff 文档路径
	- 最近更新时间

### 2.2 隔离层面

- 用 `claude --worktree <task-name>` 或手动 `git worktree add` 做文件隔离，worktree 命名要和 L3 索引里的任务名严格对应，不用 Claude 自动生成的随机名（如 `bright-running-fox`），否则索引和实际目录会脱节。

### 2.3 强制机制的设想

- 手动记录容易忘，设想用 Claude Code 的 hook（session 结束 / compact 前触发）强制自动生成 handoff 摘要并写入固定路径，减少"记得才写"的依赖。
- 但 Codex CLI 没有等价的 hook 机制，这是混用场景下的一个已知缺口。

---

## 3. 当前疑问（需要深入验证的点）

1. **L3 索引到底该用纯 Markdown 还是结构化存储？**
	- Markdown 简单、可读、可 grep，但多任务并发更新时容易冲突，也没有"状态"字段的强约束。
	- SQLite/JSON 结构化程度更高，方便配合 fzf 或小工具做检索/过滤，但引入了额外的读写脚本维护成本，值得不值得为这个需求单独维护一个小工具还没想清楚。
2. **"自动登记"这一步具体怎么触发？**
	- 设想是在启动 worktree/session 的 shell 函数里顺手写一条索引记录，但还没设计这个 shell 函数的具体实现（用什么语言、放在 `.zshrc` 还是单独脚本、怎么处理 Codex 和 Claude Code 两种不同的启动方式）。
3. **Claude Code 的 hook 具体挂在哪个生命周期事件上最合适？**
	- 是 session 退出时、还是每次 `/compact` 前、还是两者都要？如果两者都挂，会不会导致 handoff 文档被过度频繁地重写、噪音过多？
4. **Codex 侧的等价机制怎么补？**
	- Codex CLI 没有 hook，是否可以用一个包装脚本（wrapper），在 `codex` 命令退出时（trap EXIT）触发一次"请总结这次做了什么"的收尾动作？这个思路还没验证可行性。
5. **tmux 是否要作为强制依赖？**
	- 如果不强制所有任务都在 tmux 里跑，L3 索引里的"tmux session 名"字段就会经常是空的，索引的实用性打折。要不要干脆把 tmux 作为这套系统的前提条件，统一规定"所有任务必须在 tmux session 里启动"？
6. **多机器场景怎么处理？**
	- 如果同时在本地和远程服务器上跑任务（比如 SSH 到某台机器跑一个 Claude Code 任务），L3 索引是否需要区分"这条记录是哪台机器上的"，否则清单会误导。

---

## 4. 当前进度

- [x] 明确了问题的本质：不是并行调度问题，是**语义索引缺失**问题，resume 机制无法替代。
- [x] 确认了 handoff 文档（CLAUDE.md + HANDOVER.md 双文件模式）能解决"单任务内的连续性"，但解决不了"多任务间的清单可见性"。
- [x] 确定了大方向：需要一个独立于 Claude Code/Codex 的 L3 全局索引层。
- [x] 2026-08-21 第二轮讨论：第 3 节疑问 1/2/3/4/5/6 全部有了决议，见第 6 节。
- [x] 2026-08-21 第三轮讨论：statusline 方案否决，产品形态定为自建壳子 app（libghostty 倾向），见第 7 节。session→任务绑定问题由"app 当启动入口"消解。
- [ ] 未验证：libghostty 嵌入的实际可行性（API 未稳定，需要 spike 验证）；hook 内调 `claude -p` 生成摘要的稳定性与成本；Codex `notify` 的事件范围。
- [ ] 未决：app 外启动的会话（临时在普通终端里手起的）如何补录进任务体系，见 7.4。

---

## 5. 下一步建议（供继续讨论时参考，非最终决定）

按验证成本从低到高排序，建议下次讨论时按此顺序推进：

1. 先手写一个最简 `_index.md`，用一周实际记录几个真实任务，看看纯 Markdown 是否真的会出现"并发更新冲突"的问题——如果实际使用中问题不大，就不必上 SQLite。
2. 同时验证 Claude Code 的 session-end hook 能否稳定触发 handoff 自动生成，避免"记得才写"。
3. 再考虑 Codex 侧的 wrapper 脚本和多机器字段——这两个是锦上添花，不阻塞核心流程先跑起来。

---

## 6. 2026-08-21 第二轮讨论决议

### 6.1 架构定型：事实层 + 语义层

- **事实层**：由扫描脚本从两个官方存储**生成**，不登记、不手写：
	- Claude Code：`~/.claude/projects/<目录编码>/<session-id>.jsonl`，每行含 `sessionId`/`cwd`/`gitBranch`/时间戳（本机已核实）。
	- Codex：`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`，首行 `session_meta` 含 `session_id`/`cwd`/时间戳（本机已核实）。
	- ⚠️ Claude Code session 文件默认 **30 天自动清理**（`cleanupPeriodDays`，官方文档已确认），因此官方存储只是滚动缓存，**不能**作为持久数据源——这是语义层必须独立存在的硬理由。
- **语义层**：**集中的全局 handoff 文件夹**（具体路径待定，如 `~/tasks/`），每任务一个 md 文件。frontmatter 字段：任务名、状态、cwd、工具、session id 列表、最近更新时间；正文为 handoff 内容（进展、前置条件、坑、下一步）。重命名/改状态 = 编辑文件，不需要常驻服务或第三方 app（cmux 被否决：太重且强绑定）。
- 原设想的"启动自动登记"整个取消——session 文件本身就是登记，索引改为读时生成。
- L3 存储形式之争（Markdown vs SQLite）随之失效：事实层是脚本输出的视图，语义层是文件夹里的 markdown，均不需要数据库。

### 6.2 找回机制（已验证）

- `claude --resume <session-id>` 可在**任意目录**执行，自动全机查找并恢复到原 cwd（官方文档已确认）。因此语义层只需记 session id，"找回"= 从任务文件里取 id 执行 resume。
- tmux 不作前提，相关字段删除；多机器场景不设计、不留占位字段。

### 6.3 实时识别（Ghostty 十几个分屏"谁在干什么"）

- 主通道：**自定义 statusline**。已确认 statusline 脚本经 stdin 拿到 `session_id`/`cwd`/`transcript_path`，可输出任意文本 → 脚本反查语义层映射，把「任务名 · 状态」显示在每个分屏底部。零第三方依赖。
- 辅通道（待验证）：设置 Ghostty tab/窗口标题。注意即使可行，**分屏共用一个 tab 标题**，无法逐分屏标注——statusline 才是唯一的逐分屏通道，tab 标题只是锦上添花。
- 总览：一个 `tasks` CLI，列出全部任务（名称/状态/最近更新/resume 命令），fzf 选中直接恢复。

### 6.4 hook 挂载与最大未决问题

- 挂载点：**SessionEnd + PreCompact** 都挂，写入方式为**覆盖式快照**（重写任务文件的"当前状态"节），人工里程碑才追加，避免噪音。摘要生成用 hook 内调 `claude -p` 读 `transcript_path`（两事件均含 `session_id`；SessionEnd 另含 `transcript_path`，均已确认）。
- ⚠️ SessionEnd 在终端被强杀时**不保证触发**（文档未承诺），由事实层扫描兑底：最多丢最后一段的语义摘要，session 事实不丢。
- Codex 侧：不需要等价 hook——摘要器统一用 `claude -p` 读 Codex rollout JSONL；`config.toml` 的 `notify` 或 wrapper + trap EXIT 作兑底。
- **最大未决问题**：用户确认"经常一目录多任务"，因此 cwd 不能当任务标识，worktree 隔离保留在方案内，且 **session → 任务的绑定必须显式建立**。候选交互：
	1. 启动 wrapper 传任务名（回到"靠自觉"，但一目录多任务时可能不得不有个启动入口）；
	2. hook 收尾时自动摘要挂"未归档"区，用户看清单时确认归属；
	3. SessionStart hook 结合当前 worktree/分支名推断。
	下次讨论从这里开始。

---

## 7. 2026-08-21 第三轮讨论决议（部分推翻第 6 节）

### 7.1 找回机制修正（推翻 6.2 的主路径）

- **session id 从"找回主路径"降级为"30 天内同工具的快捷方式"**。理由：session 文件 30 天过期；且任务经常跨工具接力（Codex 做一半交给 Claude Code），resume 覆盖不了这两个场景。
- **找回主路径改为：读 handoff → 在任务 cwd 起新会话、注入 handoff 内容**。跨工具、永不过期。
- session id 仍由 hook 顺手记进 frontmatter（成本为零，30 天内同工具续做时 resume 的完整上下文优于有损摘要）。
- transcript JSONL **不归档**进任务文件夹——只靠 handoff 摘要，30 天外的原始对话接受丢失。这意味着 **handoff 生成质量是整个系统的生命线**（唯一的持久语义载体），提示词模板要按"这是该任务未来唯一的记忆"来设计。

### 7.2 实时识别修正（否决 6.3 的 statusline 方案）

statusline 方案否决，两条结构性缺陷：

1. 滚动会话历史时 statusline 看不到，而滚动读对话是超高频动作；
2. Codex 的 status_line 是预定义组件，塞不进自定义任务名。

### 7.3 产品形态定型：自建壳子 app（不分两步，直接做）

- **形态**：类 cmux 的侧栏 + 终端 pane，但数据永远在 markdown 文件夹（app 只是可替换的视图，app 死了文件夹 + CLI 还能用——这是与 cmux 的本质区别）。
- **关键架构点：app 是任务的启动入口（spawner）**。"新建任务" = 创建 handoff 文件 + 在 pane 里以任务身份启动 claude/codex（注入环境变量）。pane ↔ 任务对应关系 app 天生知道，第 6.4 节的 session→任务绑定问题由此消解，不再需要推断或归档确认。侧栏任务名永远可见，与滚动无关。
- **终端内核倾向 libghostty**（用户选定，不锁死）。现状（2026-08 查证）：嵌入 API 未稳定、版本间可能大改，但已有第三方项目实际在用（wintty 等）。第一个技术动作应是 **libghostty 嵌入 spike**——能跑通一个最小终端 pane 再往下走；跑不通则回退 SwiftTerm。
- 路线：不分两步，数据层（handoff 文件夹 + hooks）与 app 一起设计一起做，接受数据层设计返工的风险。

**同日第四轮补充（cmux 事实纠正与代码路线）：**

- 事实纠正：cmux **不是 Electron**，正是 Swift + AppKit + libghostty 的原生应用（github.com/manaflow-ai/cmux，18k+ star）——即本方案设想的同款架构。推论：libghostty 第三方嵌入已被证明可行，spike 风险大降；cmux 的嵌入代码是最贴近的参考实现。
- Ghostty 本身**完全开源**（MIT，github.com/ghostty-org/ghostty，含 Zig 核心 + Metal 渲染器 + Swift/GTK 壳）。GPU 渲染性能不需要"参考重写"——渲染器就在 libghostty 核心里，嵌入即直接复用同一份代码。需要参考的只是壳层：Ghostty.app 的 Swift 源码（surface 创建、输入桥接、配置加载/重载）和 cmux 的第三方壳写法。两者均 MIT，无授权障碍。
- cmux"占内存"需重新归因：技术栈是原生的，可疑点在功能面（内置浏览器 = WebKit、通知、SSH、Teams 集成）。**开工前先实测**：cmux 裸壳 vs Ghostty 本体的内存对比，确认重量来自附加功能而非嵌入本身——若裸壳就重，从零写也躲不开同样的问题，必须先找到原因。
- 代码路线：**从零写**（用户选定），cmux 仅作嵌入参考，不 fork。目标：功能最小集（侧栏任务列表 + 终端 pane + spawner），性能与内存第一，启动与渲染对齐原生 Ghostty。
- ~~早期判断：壳层的窗口/tab/split 行为、部分 keybind 由 lightty 自行定义或忽略。~~ **已被 8.2.2 推翻**：terminal 输入、快捷键、cwd 继承和 core host action 都直接对齐 vendored Ghostty macOS 壳；lightty 只定义任务语义与可见 chrome。

### 7.4 遗留问题

- **app 外启动的会话怎么办**：临时在普通终端手起的 claude/codex 会话游离在任务体系外。候选：hook 检测无任务环境变量时挂"未归档"区（沿用 6.4 候选 2 作为兑底）；或干脆规定所有正式任务必须从 app 启动，游离会话不管。未定。
- ~~hooks（SessionEnd + PreCompact 快照、`claude -p` 摘要）设计不变~~ **2026-08-22 用户否决 hooks 方案**，理由：handoff 生成耗 token、hook 时机会重复触发、写全局 settings.json 不干净。**改为 UI 主动触发**：pane header 右侧「收工」按钮 → lightty 向该 pane 的 PTY 注入一条固定指令（`ghostty_surface_text` 粘贴路径 + 回车），由 pane 内正在跑的 agent 用自身会话上下文生成 handoff 并原子写入任务文件。指令模板在 Sources/lightty/HandoffPrompt.swift，对 claude/codex 通用（顺带消解了 Codex 无 hook 的缺口）。session id 自动回填随 hooks 一并放弃（frontmatter sessions 字段降为可选）。已知限制：pane 内没跑 agent 时注入文本会打进 shell（无害）；TaskFolderWatcher 尚未接进壳，文件更新后 header/面板不会自动刷新。

---

## 8. 2026-08-22 形态决议（壳与功能）【修订版：同日第二次讨论推翻固定侧栏】

### 8.1 定位原则

lightty 的差异化不是"更好的终端"，而是**给终端补任务语义层**。用户日常用 aerospace 管窗口——窗口管理在桌面层已被解决，app 内再造常驻侧栏是重复窗管、互相打架、白吃屏宽（首版 cmux 式固定侧栏方案因此被推翻）。lightty 不抢窗管的活：**窗口有名字、任务有档案、休眠可召回**，定位是"Ghostty 加大脑"而非"cmux 减功能"。

### 8.2 已定形态

- **任务绑定粒度 = pane（第二次修正，用户澄清后定稿）**：一个 window 内部可并排住着**不同任务**的终端（用户的真实用法：同 window 左边 Claude Code 跑任务 A、右边 shell 跑任务 B）。层级：**window/frame（aerospace 管，最小 WM 粒度）→ tab（可选分组）→ 分屏布局（纯布局，不承载任务语义）→ pane（任务绑定点）**。此前"任务 = NSWindow"、"分屏限制在任务内"两条作废——分屏是布局，任务是每个 pane 的属性。
- **每 pane 一条细 header 显示「任务名 + 状态标记」**（●运行 / ⏳等待输入）：原生 window/tab 标题无法逐 pane 显示，header 由壳自绘（tmux pane border / iTerm2 per-pane title 思路），同任务多 pane 用同色点标识。常显、滚动无关、对 claude/codex 一视同仁——当初 statusline 方案的两个结构性缺陷（滚动即失、Codex 无通道）在此均不存在。window/tab 标题退化为衍生信息（激活 pane 的任务名）。
- **默认行为（2026-08-24 按 vendored Ghostty 再次校正）**：Ghostty 的 `new_tab` 创建当前窗口的 macOS 原生 tab，`new_window` 创建独立窗口，`new_split` 才在当前 tab 的 split tree 中创建 pane；新 surface 一律继承 core 返回的 cwd/font config。嵌套 NSSplitView 只负责 tab 内 pane 布局（方向一致插相邻位、方向不同原位包反向 split）。`cmd+T/N/D` 只是当前用户 Ghostty config 的默认触发例，不是 lightty 固定键位。
- ~~早期形态：cmd+K 呼出独立任务面板。~~ **已废弃**：`cmd+K` 保留给 Ghostty 默认 `clear_screen`；任务侧栏仅由标题栏按钮 hover/click 进入。
- **环境信号**（全选，用户选定）：标题状态标记 + menu bar 图标（等待中任务数，点开迷你任务列表）+ 系统通知（agent 等待输入/任务结束）。
- **任务生命周期（用户定稿：命名即落盘）**：新开 pane **不创建文件**——未命名只是内存中的 header title（灰点"未命名"）；**双击命名那一刻才创建 `<任务名>.md`**。`LIGHTTY_TASK` 已整体移除；「收工」/「注入」只在点击时向 PTY 注入明确指令。不自动启动 agent。默认 surface 的 cwd 由 Ghostty 全局 config 决定；core 请求的新窗口/tab/split 使用 `ghostty_surface_inherited_config`，lightty 不再固定 Home。
- **恢复流程**：面板选休眠任务 → 新窗口显示 handoff 摘要（进展/卡点/下一步）→ 确认 → 开 shell + 预填充建议命令（30 天内同工具 `claude --resume <id>`，否则注入 handoff 的新会话命令），回车即走。
- **明确不做**：常驻侧栏（退路：若"一键可见"实测不够，再考虑 40px 可收合状态 rail）、内置浏览器、SSH 管理。
- **已知风险**：呼出面板要求养成热键习惯，环境信号是其兑底；pane header 的高度/密度要实测（太高吃行数、太低看不清）。

### 8.2.1 视觉主题边界（2026-08-24 重构后定稿）

**Ghostty config 只控制 terminal 视觉域，不控制 lightty 应用壳层。** terminal surface 的字体、主题、背景/前景、padding、光标、透明度与 blur 继续原样读取 `~/.config/ghostty/config`；紧贴 surface 的 pane header 读取同一背景/前景/透明度，split 分隔线读取 `split-divider-color`（未设时沿用官方推导）。窗口标题栏、任务侧栏、搜索/选中/hover/按钮等应用 chrome 使用 `ShellStyle.swift` 中独立的 Codex 浅色设计 token，不读取 terminal `background`、`foreground`、`background-opacity` 或 `window-theme`。理由：壳层是产品导航，不能因深色或半透明 terminal 而整体变黑、透出 glyph；用户提供的 Codex 参考图优先决定壳层视觉。语义状态点仍只用绿/橙/灰。**未接入待办**：terminal 的 unfocused-split-opacity/fill；core `reload_config` 已接，但依赖启动期 config 快照的 pane chrome/window base 热刷新尚未做。

### 8.2.2 Terminal 行为边界（2026-08-24 用户再次确认，硬约束）

**lightty 不拥有 terminal 快捷键或 terminal 行为配置。** 所有物理键事件先进 `TerminalSurfaceView` adapter，再由 libghostty 按 Ghostty 全局 config（含默认 keybind）解析；需要 macOS 宿主的动作只经 `action_cb` 回来。AppKit 菜单不设非空 `keyEquivalent`，标题栏/菜单的终端操作按钮也通过 `ghostty_surface_binding_action` 进 core，不直接调壳层布局方法。

AppKit ↔ libghostty 的实现源是 vendored `SurfaceView_AppKit.swift` / `NSEvent+Extension.swift` / `Ghostty.Input.swift`：已对齐 key translation（含 option-as-alt）、左右 modifier + `flagsChanged`、IME `NSTextInputClient`/preedit、Command keyUp、焦点首击抑制、多键鼠标/滚动/压力、backing scale、display ID 与 occlusion。core 请求的 new window/tab/split 必须使用 `ghostty_surface_inherited_config`。可见的任务名、侧栏、pane 布局是 lightty 的产品壳语义，但它们不能反向改写 terminal 输入语义。

回归门禁：`scripts/check-terminal-adapter-parity.sh`。它拒绝重新引入 AppKit 非空快捷键或 Home cwd override，并钉住 vendor bridge 的关键 API。

### 8.3 handoff 正文规范（参考 mattpocock 的 handoff skill，本机 ~/.claude/skills/handoff）

任务文件的 markdown 正文（即 handoff 内容）与将来 hook 生成快照的提示词模板，采纳该 skill 的原则：

- **读者是接手的新 agent**：为"继续干活"写，不为人类汇报写。
- **引用不复制**：specs/plans/commit/diff/issue 已记录的内容一律以路径或 URL 引用，正文不重复。
- **脱敏**：API key、密码、PII 不写入。
- **建议命令/技能节**：直接告诉接手 agent 该调用的 skill、该跑的命令。
- **面向下一步**：围绕"下次要干什么"裁剪内容。

正文模板（hook 覆盖式快照按此结构重写，人工里程碑另起日期段追加）：

```
## 下一步          ← 接手 agent 读的第一句话
## 当前状态
## 关键决策与约束   ← 引用式：commit/文件路径/文档链接
## 卡点与风险
## 建议命令与技能
```

**刻意背离该 skill 的一点**：它把 handoff 存系统临时目录（用完即弃），lightty 存 `~/.lightty/tasks/` 持久化——持久语义层正是本项目的立足点（见 6.1/7.1）。

### 8.4 实施顺序

**先做（最小可用）**：任务数据层（`~/.lightty/tasks/` 扫描/frontmatter 解析/写入，TDD）→ 窗口 + pane header（任务名绑定与显示）→ Cmd+T 新建任务 → 呼出任务面板（列表 + 模糊搜索 + 跳转）→ 恢复流程（摘要展示 + 开 shell）。先只做单 pane 单窗口，但数据模型从一开始就按"多个 pane 归属一个任务"设计。

**随后（历史规划；分屏与原生 tab 已完成）**：活动指示与状态标记（等待输入检测）、resume 入口、menu bar 图标、系统通知。

**最后**：Codex 侧收尾机制、打磨与性能核对（内存对照 Ghostty 本体）。

---

## 9. 重建与依赖锚点

- **最小重建集**：本文件 + `docs/`（libghostty-embedding.md、task-format.md）+ `scripts/` + `Package.swift`。只有 HANDOVER 单文件可做"设计级重建"（功能等价），但会重付 docs 里记录的全部实测坑成本（链接符号清单、SwiftPM 空链接、ContentLayer 裁剪等）。代码与 git 历史不可由文档再生，属预期。
- **vendor 钉点**（shallow clone 无历史，凭此 SHA 重取）：
	- ghostty：`5851d98615187d85052e41042bcf66e0ccec11d4`（main，1.3.2-dev，2026-08-22 取）
	- ⚠️ **改钉 v1.3.1 stable 已尝试并放弃**（2026-08-25）：v1.3.1 `requireZig` 钉死 Zig 0.15.2，而 0.15.2 链不动 macOS 26.5 SDK（TBD 格式过新，`zig cc` hello world 即失败，0.15.x 无修复版）→ 本机不可构建。当前 main 快照含 1.3.1 全部内容 + 后续修复，即本机可构建的最新 libghostty。下次升级直接在 main 线上前移快照。过程中另录得两个坑备将来用：v1.3.1 有 `git+https` 传递依赖（vaxis→uucode）不在 build.zig.zon.txt 清单、换 zig 版本后依赖缓存需用对应版本 `zig fetch` 重灌 + 清 `.zig-cache`。
	- cmux：`e77660de978ed76b108ebf5c15fc3295f2b7ff62`（仅参考用）
	- 重取命令：`git fetch --depth 1 origin <sha>`（GitHub 支持按任意 SHA 取，见进展日志 libvaxis 条目同法）
- 升级 vendor 时：先按 docs/libghostty-embedding.md 的配置对齐清单逐项复核官方壳实现，再更新本节 SHA。

## 10. 进展日志

### 2026-08-22 开工：仓库落地 + 构建环境打通

- 仓库定名 **lightty**，落在 `~/project/ai/lightty`，本文档随仓库维护（Downloads 原件不再更新）。
- 参考源码浅克隆在 `vendor/`（gitignore，不入库）：`vendor/ghostty`（main，1.3.2-dev）、`vendor/cmux`。
- **cmux 源码证实了"重"的归因**：仓库里有 `web/`、`webviews/`、`cmux-browser`、`bun.lock`、`daemon`、`agent-chat`——内置浏览器/聊天面板是 WebView 实现，还带常驻 daemon。原生壳 + Web 内容的混合体。lightty 纯原生最小集的差异化成立。
- 构建环境（踩坑记录，重装机器时照此恢复）：
	- Xcode 26.4 + Swift 6.3 + **Zig 0.16.0**（brew，恰好满足 ghostty main 的 minimum_zig_version）。
	- ⚠️ **Zig 包管理器不认 proxy 环境变量**，本机走 127.0.0.1:7890 代理，`zig build` 拉依赖直连报 400。解法：按 `build.zig.zon.txt`（38 个依赖 URL 清单）用 curl/git 预下载，`zig fetch <本地路径>` 灌入全局缓存后即可离线构建。
	- ⚠️ libvaxis 钉的 commit 不在默认分支可达历史里，普通 clone 后 checkout 会失败；需 `git fetch --depth 1 origin <sha>` 按 SHA 直取。
	- ⚠️ Xcode 26 的 **Metal Toolchain 是独立组件**，缺失时 metal shader 编译报错；`xcodebuild -downloadComponent MetalToolchain` 安装。
- 构建命令（来自 ghostty 仓库 AGENTS.md）：库用 `zig build -Demit-macos-app=false`（产出 GhosttyKit xcframework）；官方壳参考 `macos/Ghostty.xcodeproj` + `macos/build.nu`。
- **构建打通** ✅：产物 `vendor/ghostty/macos/GhosttyKit.xcframework`（Debug、universal，378MB，含 `ghostty.h` + modulemap，可直接被 Swift 工程 import）。
- **Spike 验证通过** ✅（2026-08-22）：SwiftPM 工程 + 单文件 AppKit 壳，窗口渲染出真实终端，PTY 链路（login→zsh）与用户本机 Ghostty 配置（主题/字体/starship）全部生效，用户已目视确认。嵌入契约沉淀在 `docs/libghostty-embedding.md`。仓库 git 身份为 istothymoon@gmail.com（仓库级配置，历史已重写）。
- Spike 当时的欠账：GhosttyKit 需用 `-Dsentry=false` 重建（已完成）；当时未接的 IME/修饰键/换屏等事件已在 2026-08-24 terminal adapter 对齐中补齐（见 8.2.2）。

### 2026-08-22（续）："先做"阶段功能落地（双轮四 agent 并行）

- **数据层 LighttyCore** ✅（TDD，31 测试全绿）：TaskFile parse/serialize（正文与未知键字节保真）、TaskStore（list/create/update/rename/appendSession，原子写 + 时钟注入 + `/var` 符号链接陷阱处理）、TaskFolderWatcher（200ms 防抖）、FuzzyMatch（贪心子序列评分）。格式规范 docs/task-format.md。
- **壳层（当时实现，保留作演进记录）** ✅：spike 拆成模块；pane header（24pt，状态点 + 任务名 + 收工/注入按钮 + 双击改名）；曾按固定 cmd+D/cmd+shift+D、cmd+W、cmd+K、cmd+shift+K 做壳层快捷键。该键位方案和隐藏标题栏形态均已被 8.2.2 及后续 UI 定稿推翻，不能作为当前实现依据。
- **透明排查实录**（防复发）：现象——窗口/层级全部非不透明、surface 像素 alpha 正确，视觉仍不透明。根因——**layer 化后 NSView 自绘内容落在超出 bounds 的 ContentLayer 里**（实测 header 24pt 的绘制内容出现在全窗口尺寸的 ContentLayer 上），父 layer 不裁剪 → 半透明底色整张盖住终端。修复：自绘 NSView 必须 `clipsToBounds = true`。排查最快路径：**双窗口 layer 树 diff**（有可工作参照物时直接从它开始）。
- **实现层坑（备忘）**：macOS 上 `login` setuid 谱系导致 `ps eww` 读不到子进程 env，验证只能从 shell 内部做；`homeDirectoryForCurrentUser` 走 getpwuid 不认 `$HOME`，壳层依赖 home 的路径无法用环境变量沙箱化。
- **split 官方结构（"随后"阶段直接引用）**：split 全在窗口内——每窗口一棵 `SplitTree`（不可变值类型），每个 split 是独立 surface（与 tab 同一 `ghostty_surface_new`，仅归属不同），SwiftUI 递归渲染，焦点走 core `goto_split` action。lightty 的"pane = 任务绑定点"精确对应 leaf。
- cmux 的钉版本策略（备忘）：CI 用预构建 GhosttyKit + 校验和，不在开发机现编。lightty 稳定后可仿效。

### 2026-08-22 重建演练：按本文档从零重建成功（新仓库 ~/project/one-thousand-plan/lightty）

- **本节由重建会话补写**。原仓库 `~/project/ai/lightty` 在重建机器上不存在，完全按第 9 节路径执行：Notion 镜像 → 最小重建集落盘 → vendor 按 SHA `5851d98` 浅克隆 → 环境搭建 → GhosttyKit 构建 → 数据层 TDD + 壳层设计级重建。
- 环境坑**全部如实复现**，文档解法全部有效：brew zig 恰为 0.16.0；Metal Toolchain 缺失（`xcodebuild -downloadComponent MetalToolchain` 解决）；zig 拉依赖 400（curl 预下载 38 依赖 + `zig fetch` 灌缓存解决）。
- **新坑（原文档未记）**：`zig fetch <本地路径>` 必须在含 build.zig 的目录（如 vendor/ghostty）内执行，否则报 "no build.zig file found"；scratchpad 里直接跑会全部失败。
- 重建结果对照验收标准（scripts 附件页）：① `swift test` 全绿——数据层重写为 **48 测试**（覆盖面为原 31 测试的超集）；② `.build/debug/lightty` 窗口渲染真实终端（login→zsh，oh-my-zsh/主题/透明全部生效，截图目视确认）；③ 冒烟 `ghostty_info()` 真实调用已固化在 main.swift。
- 代码为**设计级重建**（功能等价，第 9 节预期）：LighttyCore（TaskFile/TaskStore/TaskFolderWatcher/FuzzyMatch）+ 壳层（pane header、嵌套分屏、恢复流程、HandoffPrompt 收工/注入、配置对齐）。本段记录的是重建当日状态：当时的固定壳层键位、IME/修饰键缺口和配置重启要求，均以后文 8.2.2 与 2026-08-24 最新进展为准。

### 2026-08-23 重建后首轮实测修正（快捷键架构 + 侧边栏形态修订）

- **快捷键架构对齐官方壳（用户定为原则）**：壳层不自设任何 terminal 快捷键。按键进 surface → core 按 `~/.config/ghostty/config` keybind（含默认值）匹配 → `action_cb` 回调壳层执行（new_tab / new_split 四方向 / goto_tab / goto_split / equalize_splits / resize_split / new_window / close / quit）。其中 `new_tab` 使用 macOS 原生 tab group，`new_split` 使用 tab 内 pane tree。补了官方壳的 `performKeyEquivalent` + `key_is_binding` 路径防 Command 组合键被 AppKit 吞。lightty 产品壳入口只走鼠标 hover/click，不另设键位。
- **分屏尺寸对齐 Ghostty**：`new_split` 的新 pane 与当前 pane 对半分、其余不动；反向包裹时外层尺寸不变。`new_tab` 与分屏树完全分离，不触发 pane 均分。
- **形态修订（历史过渡态）**：cmd+K 独立居中任务面板曾被取消并并入窗口内左侧栏；这一版仍允许 Esc/外部点击收起。最终交互已再次修订为「标题栏 hover 预览 + click 钉住」：Cmd+K 回归 Ghostty `clear_screen`，钉住后空白点击不消失。
- pane header 改名编辑器精修：与 label 同字体、firstBaseline 对齐、占位符延续原 title（零位移）；Enter 提交 / Esc 取消 / 失焦提交，结束后焦点回终端。

### 2026-08-24 UI 定稿修正（顶部操作栏 + 抽屉式侧边栏 + 恢复流程简化）

- **标题栏回归（推翻"整体隐藏 NSTitlebarContainerView"）**：每窗口保留一条原生标题栏作顶部操作栏——红黄绿三键 + 侧边栏开关按钮（`sidebar.left` 图标，直接挂进标题栏视图、以缩放键锚点对齐保证同一水平线）。无系统标题文字。最初采用透明底随 config，已被 8.2.1 的新主题边界推翻。理由：纯快捷键入口对普通用户不友好。
- **侧边栏改整体式抽屉（形态有效，布局规则已修订）**：上下左顶满内容区（非悬浮卡片），右缘 1px 分隔线；早期投影已在 Codex 浅色重构中移除。hover 预览态覆盖 terminal 并可由外部点击收起；click 钉住后切成 300pt docked 布局、terminal 从侧栏右缘开始，既不悬浮覆盖也不因终端点击而消失。
- **恢复流程简化**：摘要确认后只开绑定任务的新窗口，**不再自动预填/注入任何命令**（多行命令预填在 shell 里易碎；pane header 已有「注入」按钮，用户起 agent 后自行点击，职责不重叠）。`RestoreFlow.suggestedCommand` 随之删除；sessions 字段仍保留在格式中但恢复路径不再消费。
- 仓库已推送 GitHub：github.com/isToThyMoon/lightty（public，main）。

**同日续（侧边栏形态第三轮 + 顶部间距排查定案）：**

- **侧边栏合成层定稿（展示模式以后文 docked 修订为准）**。侧栏使用不透明 Codex 暖灰白，标题栏使用不透明近白，terminal opacity 不扩散到 chrome；左栏右缘 1px 分隔线从窗口顶贯到底。hover 临时态继续覆在 terminal 上，click 钉住态后来改成无浮层感的 docked 布局。红绿灯 + 侧边栏按钮浮于其上（z-order 用"从 closeButton 向上溯源到 themeFrame 直接子视图"定位标题栏容器，私有类名匹配不可靠会导致按钮被盖）。标题栏按钮做成幂等 ensure（标题栏私有视图会在插拔/全屏时重建丢子视图）。
- **顶部间距定案（红线标尺实测）**：终端内容距视图上缘 ≈29pt = padding-y 10 + window-padding-balance 余数 + 字形内边距，与真 Ghostty 同级——非渲染 bug。此前的"巨大空隙"两个真因：① macOS 窗口状态恢复用旧框架覆盖 core 的 INITIAL_SIZE（已修：接管 INITIAL_SIZE action + isRestorable=false）；② shell 内容（Last login 滚掉后 starship 前置空行）。surface 尺寸同步补了 layout() 路径（只挂 setFrameSize 会漏 Auto Layout 终值）。
- 调试工具沉淀：`LIGHTTY_DEBUG_LAYOUT=1` 启动 → set_size/grid/cell/INITIAL_SIZE 日志 + 终端上缘红线标尺。
- **GhosttyKit 构建形态改 ReleaseFast**（崩溃诊断结论）：Debug 构建的 core 满是 `if (runtime_safety) unreachable` 防御断言，实测点击提示符区域触发 `Surface.maybePromptClick`（Surface.zig:4214/4240，视口坐标拿不到 pin）→ SIGABRT 全程崩溃；Release 下同路径静默 `return false` 无害，官方发布形态即 Release。正式构建命令定为：`zig build -Demit-macos-app=false -Dsentry=false -Doptimize=ReleaseFast`。教训：嵌入 dev 分支 core 时，Debug 库把上游"容忍性 bug"全部升级成崩溃。
- **环境净化**：lightty 被别的 agent/终端拉起时会继承 `CLAUDE_CODE_CHILD_SESSION` 等会话标记并传给 pane shell（pane 里 claude 被当嵌套子会话、关 transcript）。main.swift 启动时统一 unsetenv，对齐 Finder 启动的干净登录环境。
- **配置边界纠正**：不得存在 lightty terminal 覆盖层。libghostty 只加载 Ghostty 全局 default/recursive config，finalize 后原样用于 app/surface；lightty 的视觉差异只能画在 terminal 之外的壳层。

### 2026-08-24 当前状态快照（接手从这里开始）

**仓库**：github.com/isToThyMoon/lightty（public，main，真源）；本机 `~/project/one-thousand-plan/lightty`。构建：`vendor/ghostty` 按第 9 节 SHA 取 → `zig build -Demit-macos-app=false -Dsentry=false -Doptimize=ReleaseFast` → `scripts/sync-ghosttykit.sh` → `swift build`；`swift test` 48 全绿。

**已落地并实测的功能面**：
- 数据层 LighttyCore：TaskFile/TaskStore/TaskFolderWatcher/FuzzyMatch（格式见 docs/task-format.md）
- 窗口：Codex 式原生标题栏操作栏（三键 + 侧边栏按钮 + 新 tab / 分屏鼠标入口，幂等重装）+ 独立近白实底；单 tab 时任务名只在 pane header 显示，原生多 tab 时 tab label 显示任务名但系统 window title 保持空，避免标题重复；窗口尺寸由 core INITIAL_SIZE 决定（isRestorable=false）
- pane：header（灰点未命名 → 双击命名落盘绿点；收工/注入按钮实时嵌路径；基线对齐的改名编辑器）；任务绑定粒度 = pane；可从 header 拖到目标 pane 四个边缘重排布局，移动现有 surface/PTY 而非新建 shell
- terminal 输入/操作：**全部由 core keybind 驱动**；AppKit 菜单没有非空 `keyEquivalent`。adapter 已覆盖 key translation、左右 modifier/`flagsChanged`、IME/preedit、Command keyUp、鼠标/滚动/压力、focus click、scale/display/occlusion；action_cb 承接 new window/tab/split、导航/均分/resize/zoom、close、search、reload 等宿主动作。新 surface 的 cwd/font 由 `ghostty_surface_inherited_config` 给出。
- 任务侧边栏（仅标题栏按钮）：Codex 式 300pt 不透明暖灰白任务抽屉，列表（搜索/运行中置顶/圆角 hover 与选中态/双击跳转或恢复）↔ 详情（md 正文与状态编辑、脏编辑钉住）；hover 临时 overlay 预览，click 后切为真实占位的 docked 侧栏，再次 click 收起；Cmd+K 由 Ghostty core 执行 `clear_screen`
- 恢复流程：摘要确认 → 开绑定窗口，不自动注入（由「注入」按钮承担）
- 配置：terminal 只遵守 Ghostty 全局 config，lightty 不叠加、不改写；应用 chrome 使用独立 ShellStyle；启动时净化继承的 agent 会话环境标记
- 调试：`LIGHTTY_DEBUG_LAYOUT=1` → 尺寸日志 + 顶部构成彩色标尺（蓝标题栏底/红 header 底/绿 grid row0/橙行界）

**顶部空白归因定案**（标尺实测）：标题栏 28 + header 24（chrome，功能本体）→ padding-y + balance 余数（用户 ghostty 配置，≈16.5pt）→ 内容 row0 零浪费；prompt 上的空行是 starship add_newline。渲染层与真 Ghostty 完全一致。

**已知欠账（按优先级建议）**：
1. TaskFolderWatcher 未接壳：任务文件外部变更后 header/侧边栏不自动刷新
2. core `reload_config` 已接；依赖启动期 config 快照的 pane chrome/window base 尚未随 reload 刷新；unfocused-split-opacity/fill 未接
3. Ghostty.app 专属壳功能 command palette / terminal inspector / quick terminal 尚未嵌入；对应 core action 明确返回 false，不另设键位或替代行为
4. "随后"阶段未做：等待输入检测（●/⏳状态标记）、menu bar 图标、系统通知
5. 恢复流程的 `claude --resume` 快捷方式随"去预填"一并移除，30 天内同工具续做场景如需找回需另设计交互
6. 打包分发（现在是 `.build/debug/lightty` 裸二进制，无 app bundle/图标/签名）；性能与内存对照 Ghostty 本体未做

### 2026-08-24 Codex 参考壳层重设计

- 参考用户提供的 ChatGPT Codex 模式截图，并对照 OpenAI Codex app 官方亮/暗色界面，提炼为 lightty 壳层规则：低对比表面、圆角选中态、大点击区域、明确的对象层级、安静的默认控件与 hover 才显形的操作。
- 新增 `ShellStyle.swift`：间距/圆角/动效集中管理。初版错误地让非语义色从 Ghostty background/foreground 派生，导致深色 terminal 把整套壳层染黑；现已重构为从用户参考图取样的独立 Codex 浅色 token（近白标题栏、暖灰白侧栏、`#ECE9E8` 邻域选中态、深灰文字）。侧栏完全不透，覆盖 IOSurface 时不会透出 glyph。
- 任务侧栏重做：300pt 顶满抽屉；标题+运行计数、新任务按钮、软底搜索框、48pt 任务行、相对更新时间、圆角 hover/selection、行内详情入口；详情页重做为返回/标题/状态、cwd 行、圆角正文编辑器和底部保存按钮；列表↔详情交叉淡入。
- 交互重做（初版，收起规则已被后续修订）：抽屉 220ms 纯位移滑入，移除 0.82→1 的透明度动画；透明点击层只用于 hover 预览态，click 钉住态不再安装该层，因此终端点击不收起；脏编辑继续钉住。标题栏抽屉开关带 active 状态。
- 标题栏重做（结构后续精简）：左侧导航、右侧新 tab / 向右分 pane；两者分别只发 core `new_tab` / `new_split:right`。曾在中间重复显示当前 pane 的终端图标+状态点+任务名，现已删除；单 tab 时任务名只保留在 pane header，多 tab 时由原生 tab label 显示，系统 window title 始终为空。私有标题栏可能在首次激活后重建，ensure 改为与当前三键所在 titlebar 做对象身份比较，并由 `windowDidUpdate` 兜底。
- pane header 的「收工/注入」改为同一套安静文字按钮，修复暗色配置下默认 AppKit 按钮对比度不足。
- 真实窗口 QA：在深色 terminal surface 上检查了首次启动、浅色标题栏、抽屉列表、详情页和标题栏重建；确认 terminal 深浅/透明不会再改变应用 chrome。`swift test` 48 项全绿。
- **Ghostty 配置同源修复**：用户并排截图发现 Ghostty.app 为 Catppuccin Latte 浅色，而 lightty terminal 退回默认深色。根因不是配置文件或外观选择，而是 GhosttyKit 静态库不携带内置主题资源，lightty 启动时也没有可发现的 `GHOSTTY_RESOURCES_DIR`，诊断明确报 `theme "Catppuccin Latte" not found`，最终保留默认 `#282c34/#ffffff`。新增 `GhosttyResources.swift`，在 `ghostty_init` 前按「显式环境变量 → app bundle resources → 开发期 vendor 构建树」定位资源；QA bundle 已复制 `zig-out/share/ghostty` 到 `Contents/Resources/ghostty`。新增 `--print-effective-terminal-config` 与 `scripts/check-config-parity.sh` 差分回归，已验证 bare SwiftPM binary 和 QA app 都与 Ghostty `+show-config` 一致：`#eff1f5/#4c4f69`、opacity `0.88`、blur `30`。
- **终端/壳层 seam 收口**：移除 `~/.config/lightty/config` 的加载入口，GhosttyRuntime 只执行 default_files → recursive_files → finalize，并将该 config 原样交给 `ghostty_app_new`；移除 `NSWindow.appearance = Aqua`，浅色 appearance 仅挂在标题栏控件和任务侧栏。`GhosttyResources` 只是静态库资源定位 adapter，不参与配置取值。终端 theme、字体、padding、opacity、blur 与快捷键继续全部由 Ghostty 全局 config/core 决定。
- **terminal adapter 与交互回归完成**：按 vendored Ghostty macOS 壳补齐键盘/IME/鼠标/focus/scale/display/occlusion 桥，core 新建 surface 走 inherited config，菜单与标题栏终端按钮只发 core binding action。实窗验证 Cmd+K 清屏后只剩一个新 prompt；`new_tab` 创建/切换 macOS 原生 tab，`goto_tab` 在原生 tab group 中导航，`new_split` 才创建 pane；新 split 继承 `/tmp` cwd；Cmd+F 搜索可开关；split zoom 可放大/还原；标题栏不再重复系统标题。`scripts/check-terminal-adapter-parity.sh` 固化该边界。
- **任务搜索聚焦态与对齐修复**：borderless `NSSearchFieldCell` 的原生 search button/text rect 会重叠，导致放大镜压住「搜索任务」。改为独立 SF Symbol 图标 + 移除 cell 内建 search button，文字区从图标右侧 6pt 起；图标点击穿透到容器并继续聚焦输入框。由于 13pt `magnifyingglass` 的可见笔画在 image frame 内约下沉 2pt，再给图标增加 `-2pt` optical offset。真实窗口已复验空态 placeholder、输入文字和图标点击：主灰度阈值下空态中心差约 `0.4–0.8px`、输入态约 `0.2–0.4px`。
- **原生 tab / docked 侧栏 / pane 拖拽定稿**：标题栏「+」只发 core `new_tab`，进入 macOS 原生 tab group 后隐藏自绘「+」并使用系统 tab-bar「+」；分屏按钮只发 `new_split:right`，两者不再同效。hover 侧栏仍覆盖预览，click 钉住后给 terminal 增加 300pt leading inset。pane header 以 UUID pasteboard 发起 move drag，目标 pane 按最近边缘显示上/下/左/右落点；drop 时从原 split tree detach 后插入同一个 `PaneView`，保留 PTY、scrollback 与任务绑定，也支持跨窗口重组。

---

*本文件由 2026-08-21 的讨论整理生成，用作该需求后续迭代的起点。第 6、7 节为同日第二、三轮讨论的决议，冲突处以第 7 节为准；第 8 节为形态决议；第 9 节为重建与依赖锚点；第 10 节为实施进展日志。本页由 lightty 仓库 HANDOVER.md 同步，仓库为真源。*
