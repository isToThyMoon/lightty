# Claude agent view 的后台会话

本篇讲 Claude Code agent view 后台会话的 pane 关联、`ClaudeAgentView` 路由记录与续接。回到入口：[Agent 状态 hooks](../hooks.md)。

Claude Code 2.1.28x 的 agent view（官方文档 agent-view）：空输入框按 ←、或 `/bg`，把前台会话转到
后台并打开后台会话列表；列表里回车连上一段，再按 ← 回到列表；shell 里 `claude attach <id>` 直接连上。
后台会话由 supervisor 托管，跑在它自己的伪终端里，环境继承自第一个拉起 supervisor 的终端（官方只额外
转发 `PATH` 与服务商设置）。所以哪个 pane 转出来的后台会话，hook 都带着那一个 pane 的
`LIGHTTY_PANE_ID`；agent view 预建的备用会话一建出来就发 `SessionStart`（`source: startup`）。按继承的
环境发，会把那个 pane 顶成一段空会话，别的 pane 的后台会话状态也会落到它上面（2026-09-28 实测）。

hook 因此多一条判断（两家都适用）：**agent 所在的终端必须是这个 lightty 开的**——开终端的进程（组长往上
第一个不在这个终端上的，见 `AgentProcessIdentity.foregroundJobLeader(in:)`）要是 `LIGHTTY_SOCK` 名字
`<pid>.sock` 里的那个 lightty。pane 里的 agent 往上是 shell、login，再往上就是 lightty；后台会话往上是
supervisor 的伪终端宿主。不成立就只认路由记录，查不到就隐形。在 pane 里套 tmux 这类自己开终端的程序时，
里面的 agent 同样按这条隐形——它们的环境同样来自第一个拉起它们的终端，按它发也会发错。

路由记录由 `ClaudeAgentView` 写，它只看两样公开的东西：pane 的终端标题（列表时是 `claude agents`，有会话
等输入时是 `2 awaiting input · claude agents`，两种都写在官方文档里；连上一段后台会话时是那段会话的
`<前缀> <会话名>`，和前台会话同一种形状），以及 `claude agents --json`（官方说的从外面读会话状态的正式途径；
后台会话名字不重复）。← 转后台时 Claude 可能换一个会话 ID 接着跑（`--fork-session`），旧会话停写。

**标题只决定什么时候去问，答案每次都从会话表从头核对**：pane 关联的会话还在前台（`interactive` 行）就是
前台；不在前台了、有一段同名的后台会话，就是连着它，写记录、把 pane 关联过去；换成了另一段对话（名字不同）
就解绑 pane 上的 handoff 任务，← 转后台再连回来是同一段对话，任务留着；不知道上一段叫什么（重启后第一条
标题）不算换了对话。回到列表时撤记录，pane 暂不关联会话。什么时候去问：标题正文变了，或上一条标题不是认识
的会话标题（列表、认不出来的写法、刚启动）；转圈时正文不变就不问，没核对出结果隔 10 秒再问。不靠「先看到
列表」——2.1.295 起列表标题带上了等输入的个数，旧的精确匹配漏认一次，pane 就一直关联着被转走的旧会话，
重启也好不了。没有关联任何会话的 pane（没装 hook）答不了「关联的还在不在前台」，只在看到列表之后才跟。

续接一段会话前（重启恢复、从侧栏打开）也问 `claude agents --json`：它是后台会话就敲 `claude attach <短 ID>`
连回去，不敲 `--resume`——对后台会话 `--resume` 会被 Claude 拒绝（"That session is running in the
background. Run `claude attach`…"），pane 退回 shell。重启恢复是同步问的（pane 装进窗口前要定下第一行
命令），同一家只问一次、3 秒为限，问不出来照常续接。删除时后台会话算「在用」。
