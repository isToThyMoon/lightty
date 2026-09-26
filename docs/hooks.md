# Agent 状态 hooks

lightty 让 pane 显示里面的 agent 正在干什么（思考中 / 执行工具 / 需要你 / 已完成），
并在 agent 跑完时提醒你。这一切靠给你已装的 coding agent 注册一个小 helper 实现。

入口：**设置 → 通用 → Agent 状态 hooks → 管理…**。首次启动时若检测到你装了 agent 却没配过，
会主动弹一次引导。

## 它是怎么工作的

```
lightty 启动 pane 的 shell 时注入  LIGHTTY_PANE_ID=<uuid>
        ↓ 环境变量沿进程树继承
你在 pane 里运行 claude / codex
        ↓ agent 在生命周期事件上调用 hook
~/.lightty/bin/lightty-hook        （几百字节的 JSON，零模型调用）
        ↓ 往 socket 发一个包，永不阻塞
~/.lightty/run/<lightty-pid>.sock
        ↓ lightty 收包，状态只在内存
pane 头圆点 / 工作区侧栏 / 菜单栏 / 系统通知
```

**helper 不常驻，没有网络，状态不落盘。** helper 只在 agent 触发事件时被拉起，
发完就退出；lightty 没在跑时包直接丢弃——状态是用完即弃的，没有需要补的账。
唯一的例外是下面「Codex 共享后台进程」一节：lightty 自己会挂一条本机连接旁听 Codex。

## 注册方式：以插件形式，不改你的配置

lightty **不会**把 hook 定义写进你的 `~/.claude/settings.json` 或 `~/.codex/hooks.json`。

它在 `~/.lightty/marketplace` 生成一个插件，然后调用 **agent 自己的 CLI** 完成注册：

```sh
claude plugin marketplace add ~/.lightty/marketplace
claude plugin install lightty@lightty

codex plugin marketplace add ~/.lightty/marketplace
codex plugin add lightty@lightty
```

于是 7 条 hook 定义留在 lightty 自己的文件里，你的配置里只多几行声明式开关，
**而且是它们自己的 CLI 写的**：

| Agent | 你的配置里多了什么 |
|---|---|
| Claude Code | `settings.json` 的 `extraKnownMarketplaces` 与 `enabledPlugins` 两个键 |
| Codex | `config.toml` 的 `[marketplaces.lightty]` 与 `[plugins."lightty@lightty"]` |

这样做的好处：lightty 不需要理解、也不可能写坏它们的配置格式；将来它们改格式，
由它们自己的 CLI 负责。

### 注册的事件

`SessionStart`、`UserPromptSubmit`、`PreToolUse`、`PostToolUse`、`Stop`、`SessionEnd`，
外加 Claude Code 的 `PostToolUseFailure` / `Notification`，以及 Codex 的 `PermissionRequest` / `Interrupt`。

`Notification` 里已知只是告知的类型不改变状态，其余都算「待处理」。其中最常见的是回合结束
60 秒没人输入时 Claude Code 发的 `idle_prompt`：它被忽略，pane 保持「已完成」。

hook 不是忙/闲的唯一来源：两家都把状态和会话标题写进终端标题（OSC 0，Claude 是 ◐ ◑ ✳ 前缀，
Codex 是 braille 旋转字符和 `Action Required`），lightty 从那里拿到按 Esc 中断的即时信号和改名，
详见 `docs/specs/pane-status.md` §4.3。
Claude Code 的 `Stop` 在用户中断时不触发，hook 侧只有带 `is_interrupt` 的 `PostToolUseFailure`。

每条注册的命令都带上这一家的名字：

```
~/.lightty/bin/lightty-hook --agent claude
~/.lightty/bin/lightty-hook --agent codex
```

两家的 hooks 文件是 lightty 自己生成的，哪一家读哪份是确定的，直接写进命令行即可；
helper 不必再从父进程链的可执行路径反推是谁调的它——那条路的形状随安装方式变。
没带 `--agent` 的旧版插件退回看载荷里 `transcript_path` 的形状，再退回环境变量。

pane 只跟踪主会话。主会话在工具里拉起的子会话（比如 Bash 里跑 `claude -p`）会继承 pane 的
环境变量，hook 从自己的父进程往上走，走到终端的前台作业组长之前若经过了**脱离终端**的进程，
就认定这是子会话，静默退出，不发状态也不注入交接文档。判据全是内核里的终端结构，
不认任何进程名，见 `docs/specs/pane-status.md` §2.1。

Codex 另有一条：父进程链上一个带终端的进程都没有时（hook 不在任何终端里），继承来的 pane
不可信，同样静默。Claude 不受影响，仍按「宁可多报」。

## Codex 共享后台进程

Codex 0.157 起，终端里的 `codex` 默认只是界面，会话和 hook 都跑在一个多终端共用的
app-server 后台进程里（`codex app-server --listen unix:// --managed-daemon`）。hook 继承的是
后台进程自己的环境，`LIGHTTY_PANE_ID` 属于当初拉起后台进程的那个终端，和当前会话无关；
后台进程的拉起者退出后它被系统收养，父进程链上没有终端。载荷里唯一可靠的身份是 `session_id`。

lightty 不改 Codex 的运行方式，只补上断掉的那一环——「这段会话显示在哪个 pane」。
这一节只作用于 Codex，Claude 的 hook 不查路由记录：

```
lightty ──codex app-server proxy──> 共享后台进程（官方入口，WebSocket + JSON-RPC，只听广播）
   thread/started：会话 ID、目录、创建时间、来源
   thread/status/changed：续接的会话没有 started，第一次状态变化时 thread/read 补查
   thread/closed：撤记录
        ↓ 对 pane（CodexSessionRouter）
~/.lightty/run/sessions/<session_id>   {pane, socket, owner, client}
        ↓ hook 先按 session_id 查这条记录，查到就用它的 pane 和界面进程
之后发状态、找任务、注入 handoff，全走原来按 pane 的路
```

会话对 pane 靠进程事实：pane 里起的进程都继承了 `LIGHTTY_PANE_ID`，界面进程是 pane 终端
的前台作业组长、启动参数是 `codex`（`ProcessInspector`）。规则见 `CodexSessionRouter.choose`：

- 启动参数里带会话 ID（`codex resume <ID>`，lightty 自己续接也是这样）：确定。
  lightty 已声明或已绑定的会话直接用那个 pane。
- 只凭目录配对要有新鲜证据：刚经 `thread/started` 宣布、目录里只有一个界面（含同一界面
  `/new`）；或会话创建时间与界面启动相差 10 秒内且明显最近。界面退出后还挂在后台进程里的
  残留会话目录可能相同，只凭目录会配错。
- 只配 `threadSource: user` 的会话。后台进程自己也会建同目录的会话（生成标题时建
  `thread_title`、`ephemeral` 的临时会话），配上去会挤掉真正会话的记录。
- 一个界面同一时刻只显示一个会话，写新记录时撤掉它的旧记录。

对不上的会话（手敲 `codex resume` 的选择器或 `--last`、同目录一秒内起两个）不写记录，
hook 查不到就静默：宁可暂时没有状态，也不送进别人的 pane。子会话、工具里的 `codex exec`
从来不在界面上，也不会有记录。

连接只在机器上有 Codex 后台进程时有意义：启动时试一次，之后有 pane 开始跑 Codex 再试，
连续失败时间隔从 5 秒倍增到 5 分钟；握手 10 秒没回应就断开重来。记录随 lightty 退出撤掉；
写它的 lightty 或界面进程不在了，记录自动作废。

### 兜底：Codex 写进本 pane 的终端信号

以上都失效时（对不上 pane、`proxy` 不可用、hook 没装或没信任），状态退回 Codex 界面自己
写进这个 pane 的两种信号。它们天然属于这个 pane，不会送错：

- 终端标题（OSC 0）：旋转字符 → 思考中，但只在 Codex 起来之后用户在这个 pane 按过回车才算
  ——界面启动时加载模型、起 MCP 也会转圈，那发生在第一次提交之前（实测：不这样的话刚进会话
  就显示思考中、随后已完成）。在 shell 里敲 `codex` 那一下回车早于认出 Codex，不算；Codex
  退出后清零。`Action Required` → 等你；从这两样回到没有前缀的标题 → 空闲。标题不判完成。
- 桌面通知（OSC 9，Codex 只在终端没有焦点时发）：`Approval requested`、`Codex wants to edit`、
  `Plan mode prompt:`、`Question:` 开头 → 等你；其余是回合完成（正文是回复预览）→ 完成。
  前缀表在 `CodexAgent.attentionNotificationPrefixes`。完成只从这里来，正好是没看着这个 pane、
  需要提醒的时候。

只在这个 pane 没有 hook 在管时生效：没有 Codex 会话路由（有路由说明 hook 那条路通着——
SessionStart 要等第一条消息，不能只看有没有 hook 状态），而且没有状态、上一段会话已结束、
或当前就是兜底状态。路由写上时清掉已经推上去的兜底状态。
hook 报文一到就接管，不比时间戳——标题常比 hook 先到，按时间比会丢掉 hook 的第一发。
兜底只有状态：没有会话身份，侧栏的会话绑定和 handoff 注入都做不了。只作用于 Codex。

这些事件缺一条都会让状态机少一条进出边：只登记 `Stop` 的话圆点永远不会变成"思考中"；
漏掉 `PostToolUse`，工具跑完后状态会卡在 `tool` 上不回落；Codex 漏掉 `Interrupt`，
用户主动停止后会一直停在 `thinking` / `tool`（Claude 这条边由终端标题兜着）。

### 为什么命令指向 `~/.lightty/bin/`

配置里写的是绝对路径。真实 helper 在 app bundle 内部，你把 lightty 从下载目录拖进
`/Applications`，bundle 路径就变了、hook 会静默失效。所以中间隔一层 symlink，
lightty **每次启动重新指向**当前 bundle，marketplace 也随之重新生成。

## Codex 的信任提示

Codex 会对 hook 配置做哈希校验。装完之后**你下次运行 codex 会看到一个审核提示**——
那是 Codex 注意到多了一个带 hook 的插件，属于正常现象。

**不批准的话 hook 不会执行**（实测确认）。lightty 不会、也不应该绕过它。

Claude Code 侧没有这道门，插件装完即生效。

## 隐私

状态只在本机内存里，通过本机 socket 传递，**不落盘、不上传任何地方**。内容是：
当前状态、工具名、一行截断的摘要（如文件路径）、会话 id、工作目录。

之所以用 socket 而不是系统通知中心：后者是**登录会话级广播**，任何进程都能
读到 agent 执行的命令行——那是隐私泄露。socket 只有 lightty 自己收得到。

## handoff 上下文注入

pane 绑定了任务时，lightty 会把任务文件的绝对路径写进
`~/.lightty/panes/<uuid>/task`。helper 在两个时机读它，把 handoff 文档
**直接注入 agent 的上下文**：

- `SessionStart`：agent 开场，绑了就注。
- `UserPromptSubmit`：每次提问前查一下。先开 agent 再绑任务、新建任务、
  改名（路径变了，agent 要知道新的回写地址）——这些晚于开场的变化在下一次提问时补注。
  去重靠 `~/.lightty/panes/<uuid>/handoff.injected`（记上次注入的 session 与路径），
  同一会话同一路径只注一次；解绑时 lightty 连它一起删。

这比「在 AGENTS.md 里写一句让 agent 去读文件」可靠得多——不需要 agent 遵循指令，
文档就在那里。

## 故障排查

**pane 头圆点不动**

```sh
# 1. pane 里确认 env 到位
echo $LIGHTTY_PANE_ID

# 2. 确认插件装上了
claude plugin list | grep lightty
codex  plugin list | grep lightty

# 3. 确认 shim 有效
ls -l ~/.lightty/bin/lightty-hook

# 4. 确认 socket 在（lightty 运行中才有）
echo $LIGHTTY_SOCK && ls -l $LIGHTTY_SOCK

# 5. 手动喂一个事件，pane 头圆点应立刻变化
echo '{"hook_event_name":"Stop"}' | LIGHTTY_PANE_ID=$LIGHTTY_PANE_ID LIGHTTY_SOCK=$LIGHTTY_SOCK ~/.lightty/bin/lightty-hook --agent claude
```

**`echo $LIGHTTY_PANE_ID` 或 `$LIGHTTY_SOCK` 是空的** —— 这个 pane 是升级前开的。新开一个 pane。

> 注意：**不要用 `ps eww` 检查 pane 的环境变量**。macOS 不允许读取经由 setuid
> `login` 派生的进程环境，它会让一个正常工作的变量看起来"不存在"。要查就在 shell
> 里直接 `echo`。

**装好了但状态不更新（Codex）** —— 检查是否批准了 hook 信任提示。实时状态通过 socket 传输，没有状态文件需要观察。

**agent 会话是配置前起的** —— hook 配置在会话启动时读取，重开 claude/codex。

**手动喂事件后 UI 不动** —— 先确认这条命令是在 pane 的 shell 里**直接**敲的：
在某个 agent 的工具里（或在别的会话的 Bash 工具跑的脚本里）喂事件，hook 会把它判成
子会话而静默退出，这是对的。直接敲还是不动，就是 lightty 侧的接收问题，请提 issue。

## 卸载

**设置 → 通用 → Agent 状态 hooks → 管理… → 卸载**，或直接用它们自己的 CLI：

```sh
claude plugin uninstall lightty@lightty
codex  plugin remove    lightty@lightty
```

卸载后 agent 一切照旧，只是 lightty 不再知道它在做什么。

## 相关文档

- `docs/specs/pane-status.md` —— 当前状态传输、展示与 Handoff 注入契约
- `docs/task-format.md` —— 任务文件格式（旧文件里的 `status` 字段与本机制**无关**，已移除）
