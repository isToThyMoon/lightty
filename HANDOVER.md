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
- Ghostty 配置兼容分两层：**渲染层**（字体/主题/配色/padding/光标）经 libghostty 加载 `~/.config/ghostty/config` 基本免费继承；**壳层**（窗口/tab/split 行为、部分 keybind、macos-*）实现在 Ghostty 自己的 Swift 壳里，不随库带来，由本 app 自行定义或忽略。配置实时生效需自己实现（监听文件 + 调 config 重载接口）。

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
- **默认行为（用户实测后第三次修正定稿；粒度术语统一为 pane）**：**cmd+T 新建任务 → 在当前任务窗口右侧并排加一个 pane**（同窗多任务、各自 header——非 macOS 原生顶部 tab 条，原生 tab 方案已实测被否）；cmd+N 新建任务 → 独立窗口（交给 aerospace 平铺）；**cmd+D 向右分 pane / cmd+shift+D 向下分 pane**——新 pane 继承当前任务（辅助 shell，同 cwd），实现为嵌套 NSSplitView（方向一致插相邻位、方向不同原位包反向 split，左右/上下任意组合）。pane 任务可随时改绑/重命名（header 点击或热键，写回任务 md，待做）。
- **全局热键呼出任务面板**（cmd+K 式浮层，类 Raycast/fzf）：运行中 + 休眠任务同列，模糊搜索；回车跳转（运行中）或进恢复流程（休眠），选中行右侧预览 handoff 摘要。用完即散，无常驻 UI。清单可见性 = "一键可见"。
- **环境信号**（全选，用户选定）：标题状态标记 + menu bar 图标（等待中任务数，点开迷你任务列表）+ 系统通知（agent 等待输入/任务结束）。
- **任务生命周期（用户定稿：命名即落盘）**：cmd+T/N/D 新开 pane **不创建文件**——未命名只是内存中的 header title（灰点"未命名"，防止文件膨胀）；**双击命名那一刻才创建 `<任务名>.md`**（绿点，绑定），再改名 = `TaskStore.rename` 连文件移动（文件夹保持可读可 grep）。`LIGHTTY_TASK` 环境变量**已整体移除**——「收工」「注入」指令都在点击时实时嵌入当前路径，env 无存在理由。header 两个按钮：**「收工」**让 agent 落盘 handoff（未命名时点击先触发命名编辑）；**「注入」**恢复场景让 agent 读 handoff 文件按「下一步」继续（未绑定时禁用）。面板"休眠"列表天然只含命名过的任务。不自动启动 agent，cwd 固定家目录。
- **恢复流程**：面板选休眠任务 → 新窗口显示 handoff 摘要（进展/卡点/下一步）→ 确认 → 开 shell + 预填充建议命令（30 天内同工具 `claude --resume <id>`，否则注入 handoff 的新会话命令），回车即走。
- **明确不做**：常驻侧栏（退路：若"一键可见"实测不够，再考虑 40px 可收合状态 rail）、内置浏览器、SSH 管理。
- **已知风险**：呼出面板要求养成热键习惯，环境信号是其兑底；pane header 的高度/密度要实测（太高吃行数、太低看不清）。

### 8.2.1 视觉铁律（用户定为默认原则，无需逐项确认）

**渲染层的一切视觉参数——主题、背景、前景、透明度、分隔线色等——一律以 `~/.config/ghostty/config` 为唯一来源，壳层不自造颜色**（语义状态点除外：绿/橙/灰）。lightty 只做壳。已接入：终端渲染（libghostty 天然）、split 分隔线（`split-divider-color`，未设时按官方公式从 background 推导）、pane header 底色/文字（`background`/`foreground` + `background-opacity`）、窗口外观（`window-theme`）、窗口透明度与背景模糊（`background-opacity` + `background-blur`，走 libghostty 公开 API）。读取方式：`ghostty_config_get`（启动时一次，与渲染同一份解析结果），取值与推导公式对齐官方壳防分叉（详见 docs/libghostty-embedding.md 配置对齐清单）。**未接入待办**：unfocused-split-opacity/fill（非聚焦 pane 压暗）、配置热重载（现在改配置需重启）。

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

**随后**：分屏（split tree，pane 级任务继承/改绑）、tab 分组、活动指示与状态标记（等待输入检测）、resume 预填充、menu bar 图标、系统通知。

**最后**：Codex 侧收尾机制、打磨与性能核对（内存对照 Ghostty 本体）。

---

## 9. 重建与依赖锚点

- **最小重建集**：本文件 + `docs/`（libghostty-embedding.md、task-format.md）+ `scripts/` + `Package.swift`。只有 HANDOVER 单文件可做"设计级重建"（功能等价），但会重付 docs 里记录的全部实测坑成本（链接符号清单、SwiftPM 空链接、ContentLayer 裁剪等）。代码与 git 历史不可由文档再生，属预期。
- **vendor 钉点**（shallow clone 无历史，凭此 SHA 重取）：
	- ghostty：`5851d98615187d85052e41042bcf66e0ccec11d4`（main，1.3.2-dev，2026-08-22 取）
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
- Spike 已知欠账：GhosttyKit 需用 `-Dsentry=false` 重建（已完成）；IME/修饰键/换屏等事件未接（正式壳补）。

### 2026-08-22（续）："先做"阶段功能落地（双轮四 agent 并行）

- **数据层 LighttyCore** ✅（TDD，31 测试全绿）：TaskFile parse/serialize（正文与未知键字节保真）、TaskStore（list/create/update/rename/appendSession，原子写 + 时钟注入 + `/var` 符号链接陷阱处理）、TaskFolderWatcher（200ms 防抖）、FuzzyMatch（贪心子序列评分）。格式规范 docs/task-format.md。
- **壳层** ✅：spike 拆成模块；pane header（24pt，状态点 + 任务名 + 收工/注入按钮 + 双击改名）；嵌套分屏（cmd+D/cmd+shift+D）；pane 导航（cmd+alt+方向/cmd+[]）；cmd+W 关 pane；cmd+K 任务面板；cmd+shift+K 悬浮侧边栏（列表↔详情两页、脏编辑钉住）；隐藏标题栏（含 NSTitlebarContainerView 整体隐藏）。
- **透明排查实录**（防复发）：现象——窗口/层级全部非不透明、surface 像素 alpha 正确，视觉仍不透明。根因——**layer 化后 NSView 自绘内容落在超出 bounds 的 ContentLayer 里**（实测 header 24pt 的绘制内容出现在全窗口尺寸的 ContentLayer 上），父 layer 不裁剪 → 半透明底色整张盖住终端。修复：自绘 NSView 必须 `clipsToBounds = true`。排查最快路径：**双窗口 layer 树 diff**（有可工作参照物时直接从它开始）。
- **实现层坑（备忘）**：macOS 上 `login` setuid 谱系导致 `ps eww` 读不到子进程 env，验证只能从 shell 内部做；`homeDirectoryForCurrentUser` 走 getpwuid 不认 `$HOME`，壳层依赖 home 的路径无法用环境变量沙箱化。
- **split 官方结构（"随后"阶段直接引用）**：split 全在窗口内——每窗口一棵 `SplitTree`（不可变值类型），每个 split 是独立 surface（与 tab 同一 `ghostty_surface_new`，仅归属不同），SwiftUI 递归渲染，焦点走 core `goto_split` action。lightty 的"pane = 任务绑定点"精确对应 leaf。
- cmux 的钉版本策略（备忘）：CI 用预构建 GhosttyKit + 校验和，不在开发机现编。lightty 稳定后可仿效。

### 2026-08-22 重建演练：按本文档从零重建成功（新仓库 ~/project/one-thousand-plan/lightty）

- **本节由重建会话补写**。原仓库 `~/project/ai/lightty` 在重建机器上不存在，完全按第 9 节路径执行：Notion 镜像 → 最小重建集落盘 → vendor 按 SHA `5851d98` 浅克隆 → 环境搭建 → GhosttyKit 构建 → 数据层 TDD + 壳层设计级重建。
- 环境坑**全部如实复现**，文档解法全部有效：brew zig 恰为 0.16.0；Metal Toolchain 缺失（`xcodebuild -downloadComponent MetalToolchain` 解决）；zig 拉依赖 400（curl 预下载 38 依赖 + `zig fetch` 灌缓存解决）。
- **新坑（原文档未记）**：`zig fetch <本地路径>` 必须在含 build.zig 的目录（如 vendor/ghostty）内执行，否则报 "no build.zig file found"；scratchpad 里直接跑会全部失败。
- 重建结果对照验收标准（scripts 附件页）：① `swift test` 全绿——数据层重写为 **48 测试**（覆盖面为原 31 测试的超集）；② `.build/debug/lightty` 窗口渲染真实终端（login→zsh，oh-my-zsh/主题/透明全部生效，截图目视确认）；③ 冒烟 `ghostty_info()` 真实调用已固化在 main.swift。
- 代码为**设计级重建**（功能等价，第 9 节预期）：LighttyCore（TaskFile/TaskStore/TaskFolderWatcher/FuzzyMatch）+ 壳层（pane header、嵌套分屏 cmd+D/cmd+shift+D、cmd+T/N、pane 导航、cmd+K 任务面板、cmd+shift+K 侧边栏、恢复流程、HandoffPrompt 收工/注入、配置对齐）。已知欠账与原版一致：IME/修饰键未接、TaskFolderWatcher 未接进壳、配置热重载未做。

### 2026-08-23 重建后首轮实测修正（快捷键架构 + 侧边栏形态修订）

- **快捷键架构对齐官方壳（用户定为原则）**：壳层不自设终端类快捷键。按键进 surface → core 按 `~/.config/ghostty/config` keybind（含默认值）匹配 → `action_cb` 回调壳层执行（new_split 四方向 / goto_split / equalize_splits / resize_split / new_window / close / quit）；`new_tab` 映射为「新任务 pane 并排右侧」（8.2 语义不变，键位归 ghostty）。补了官方壳的 `performKeyEquivalent` + `key_is_binding` 路径防 cmd 组合键被 AppKit 吞。壳层只保留 lightty 拓展键。
- **分屏尺寸对齐 Ghostty**：新 pane 与当前 pane 对半分、其余不动；反向包裹时外层尺寸不变；cmd+T 顶层各列均分。
- **形态修订（推翻 8.2 两点）**：cmd+K 独立居中任务面板**取消**，并入**窗口内悬浮左侧侧边栏**（悬浮卡片：内缩/圆角/投影，非常驻、非 split pane），理由：减少视觉转换成本。侧边栏 = 任务管理唯一入口：列表页（全部任务、运行中置顶、模糊搜索、双击/回车跳转或恢复、Esc 收起、点击卡片外自动收起）↔ 详情页（md 正文与状态编辑、脏编辑钉住）。cmd+shift+K 废弃。
- pane header 改名编辑器精修：与 label 同字体、firstBaseline 对齐、占位符延续原 title（零位移）；Enter 提交 / Esc 取消 / 失焦提交，结束后焦点回终端。

---

*本文件由 2026-08-21 的讨论整理生成，用作该需求后续迭代的起点。第 6、7 节为同日第二、三轮讨论的决议，冲突处以第 7 节为准；第 8 节为形态决议；第 9 节为重建与依赖锚点；第 10 节为实施进展日志。本页由 lightty 仓库 HANDOVER.md 同步，仓库为真源。*
