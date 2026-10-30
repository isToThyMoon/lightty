# hook 事件、命令与 handoff 注入

本篇讲注册哪些事件、命令怎么写、helper 怎么判定是不是主会话、如何注入 handoff 文档。回到入口：[Agent 状态 hooks](../hooks.md)。

## 注册的事件

`SessionStart`、`UserPromptSubmit`、`PreToolUse`、`PostToolUse`、`Stop`、`SessionEnd`，
外加 Claude Code 的 `PostToolUseFailure` / `Notification`，以及 Codex 的 `PermissionRequest` / `Interrupt`。

`Notification` 里已知只是告知的类型不改变状态，其余都算「待处理」。其中最常见的是回合结束
60 秒没人输入时 Claude Code 发的 `idle_prompt`：它被忽略，pane 保持「已完成」。

hook 不是忙/闲的唯一来源：两家都把状态和会话标题写进终端标题（OSC 0，Claude 是 ◐ ◑ ✳ 前缀，
Codex 是 braille 旋转字符和 `Action Required`），lightty 从那里拿到按 Esc 中断的即时信号和改名，
详见 [状态机](../specs/pane-status/state-machine.md)。
Claude Code 的 `Stop` 在用户中断时不触发，hook 侧只有带 `is_interrupt` 的 `PostToolUseFailure`。

这些事件缺一条都会让状态机少一条进出边：只登记 `Stop` 的话圆点永远不会变成"思考中"；
漏掉 `PostToolUse`，工具跑完后状态会卡在 `tool` 上不回落；Codex 漏掉 `Interrupt`，
用户主动停止后会一直停在 `thinking` / `tool`（Claude 这条边由终端标题兜着）。

## 注册的命令与 `--agent`

每条注册的命令都带上这一家的名字：

```
~/.lightty/bin/lightty-hook --agent claude
~/.lightty/bin/lightty-hook --agent codex
```

两家的 hooks 文件是 lightty 自己生成的，哪一家读哪份是确定的，直接写进命令行即可；
helper 不必再从父进程链的可执行路径反推是谁调的它——那条路的形状随安装方式变。
没带 `--agent` 的旧版插件退回看载荷里 `transcript_path` 的形状，再退回环境变量。

### 为什么命令指向 `~/.lightty/bin/`

配置里写的是绝对路径。真实 helper 在 app bundle 内部，你把 lightty 从下载目录拖进
`/Applications`，bundle 路径就变了、hook 会静默失效。所以中间隔一层 symlink，
lightty **每次启动重新指向**当前 bundle，marketplace 也随之重新生成。

## 只跟踪主会话

pane 只跟踪主会话。主会话在工具里拉起的子会话（比如 Bash 里跑 `claude -p`）会继承 pane 的
环境变量，hook 从自己的父进程往上走，走到终端的前台作业组长之前若经过了**脱离终端**的进程，
就认定这是子会话，静默退出，不发状态也不注入交接文档。判据全是内核里的终端结构，
不认任何进程名，见 [进程识别与子会话判定](../specs/pane-status/process-identity.md)。

Codex 另有一条：父进程链上一个带终端的进程都没有时（hook 不在任何终端里），继承来的 pane
不可信，同样静默。Claude 不受影响，仍按「宁可多报」。

后台会话、共享后台进程造成的 pane 误归属另有判定，见 [Claude agent view 的后台会话](claude-agent-view.md) 与 [Codex 共享后台进程](codex-shared-daemon.md)。

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
