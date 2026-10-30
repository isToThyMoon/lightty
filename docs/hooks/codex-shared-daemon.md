# Codex 共享后台进程

本篇讲 Codex 0.157 起共享 app-server 后台进程下，会话到 pane 的关联（`CodexSessionRouter`）、路由记录与回合状态接收。回到入口：[Agent 状态 hooks](../hooks.md)；关联失效时的退路见 [终端信号兜底](codex-terminal-fallback.md)。

Codex 0.157 起，终端里的 `codex` 默认只是界面，会话和 hook 都跑在一个多终端共用的
app-server 后台进程里（`codex app-server --listen unix:// --managed-daemon`）。hook 继承的是
后台进程自己的环境，`LIGHTTY_PANE_ID` 属于当初拉起后台进程的那个终端，和当前会话无关；
后台进程的拉起者退出后它被系统收养，父进程链上没有终端。载荷里唯一可靠的身份是 `session_id`。

lightty 不改 Codex 的运行方式，通过官方连接确定会话所属 pane，并接收回合状态。
这一节只作用于 Codex，Claude 的 hook 不查路由记录：

```
lightty ──codex app-server proxy──> 共享后台进程（官方入口，WebSocket + JSON-RPC，广播与只读补查）
   thread/started：会话 ID、目录、创建时间、来源
   thread/status/changed：续接的会话没有 started，第一次状态变化时 thread/read 补查
   turn/completed：按 completed / interrupted / failed 更新回合结果
   thread/closed：撤记录
   thread/name/updated：自动起名或 /rename 之后，重读官方目录里的标题
        ↓ 对 pane（CodexSessionRouter）
~/.lightty/run/sessions/<session_id>   {pane, socket, owner, client}
        ↓ hook 先按 session_id 查这条记录，查到就用它的 pane 和界面进程
之后发状态、找任务、注入 handoff，全走原来按 pane 的路
```

已确认关联的会话直接接收 `thread/status/changed` 的 active / idle；active 带着 `activeFlags` 的
`waitingOnApproval` / `waitingOnUserInput` 时是等你（后者没有 hook 能报），这样亮起的等你只由后台进程
自己收回，hook 亮起的仍由后续 hook 收回，两条路先后错开也不闪；恢复后尚未收到 hook，
也能建立活动状态。连接时通过 `thread/loaded/list` 和 `thread/read` 补查当前状态，补查结果
不能覆盖请求之后收到的新状态事件。`turn/completed` 补足缺失的 Stop，后续 idle 或重复完成
不重建已读提醒。hook 继续提供工具和权限细节。

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

走路由记录送达的 `SessionEnd` 一律不发：共享后台进程关一个会话循环就跑它（上游 `shutdown_session_runtime`），
新界面续接同一段会话时正是先关掉旧的循环。lightty 重启恢复现场时，旧界面留下的 `SessionEnd` 会按刚写好的
路由落进新 pane，把续接的关联清掉。界面退出由 shell 的命令结束信号（OSC 133）判断，不靠它。

对不上的会话（手敲 `codex resume` 的选择器或 `--last`、同目录一秒内起两个）不写记录，
hook 查不到就静默：宁可暂时没有状态，也不送进别人的 pane。子会话、工具里的 `codex exec`
从来不在界面上，也不会有记录。

连接只在机器上有 Codex 后台进程时有意义：启动时试一次，之后有 pane 开始跑 Codex 再试，
连续失败时间隔从 5 秒倍增到 5 分钟；握手 10 秒没回应就断开重来。
后台进程重启（Codex 升级时就会）不会让连接自己断：`proxy` 要两个方向的转发都结束才退出，
后台进程那头结束了，它还在等标准输入，也不关标准输出，lightty 读不到结尾。它只在下一次
往里写时报错退出。所以连着的时候，在两种时机往里写一次 `thread/loaded/list`：有新的 Codex
界面起来；有 Codex pane 在靠终端信号兜底（最多 30 秒一次）。连接活着，这一写顺带补查错过的
会话；已经死了，`proxy` 退出，lightty 马上重连并补查。平时不发任何东西。记录随 lightty 退出撤掉；
写它的 lightty 或界面进程不在了，记录自动作废。
