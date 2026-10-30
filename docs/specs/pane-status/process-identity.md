# 进程识别与子会话判定

> 状态：现行契约。（核对于 2026-10-29）

hook helper 如何认出 agent 进程、丢弃子会话事件。属于 [Pane 状态与 Handoff 注入契约](../pane-status.md)。

## 哪个进程是 agent、哪一发是子会话

helper 不按进程名认 agent——名字随安装方式变——只看内核里的终端作业结构。
实测（2026-09-16，Claude Code 2.1.274、Codex 0.154.0，`script` 造 pty 记录 hook 的祖先链）：

| 进程 | 进程组 | 终端前台组 | 控制终端 |
| --- | --- | --- | --- |
| Claude 主会话（pty 上） | = 自己 pid | = 自己 pid | 有 |
| Claude 起的 hook | 自己一组 | 0 | 无（Claude 把 hook 脱离了终端） |
| Claude 的 Bash 工具子进程 | 自己一组 | 0 | 无 |
| 工具里起的 `claude -p` | 沿用工具 shell 的组 | 0 | 无 |
| Codex 主会话（pty 上） | = 自己 pid | = 自己 pid | 有 |
| Codex 起的 hook | 自己一组 | = codex pid | 有 |
| Codex 的 shell 工具子进程 | 自己一组 | 0 | 无 |
| 工具里起的 `codex exec` | 沿用工具 shell 的组 | 0 | 无 |

两家一致：主会话是终端的**前台作业组长**（pid == `e_pgid` == `e_tpgid`、`e_tdev != NODEV`），
工具子进程一律**脱离终端**。据此：

- **agent 进程** = hook 父进程链上最近的前台作业组长。记 pid + 内核启动时间（`AgentProcessIdentity`），
  供退出监视、删除核查与「在其他终端中打开」。npm 版 codex 的 node 包装、用户自己的启动脚本，
  组长就是外层包装进程，监视它退出与监视里面那个等价。
- **子会话** = 从 hook 的父进程走到组长之前经过了没有控制终端的进程。子会话的事件全部丢弃，
  不发状态也不注入，否则它的 SessionStart / SessionEnd 会顶掉主会话的状态与绑定。
- 判定从 hook 的**父进程**起算：Claude 把 hook 自己脱离了终端，hook 没有控制终端不作数，
  也因此 helper 不能 `open("/dev/tty")` 或 `tcgetpgrp`，只能沿祖先链读 `kinfo_proc`。
- 链上找不到组长：不记进程身份，**也不按子会话处理**——宁可多报一发状态，不能把主会话的事件丢掉。
- **仅 Codex**（Claude 照上面三条）：
  - 先按 `session_id` 查会话路由记录（`AgentSessionRoute`，`~/.lightty/run/sessions/`）。
    查到就用记录里的 pane 与界面进程，不看继承的环境和祖先链。记录由 lightty 的
    `CodexSessionRouter` 写，见 [hooks 文档](../../hooks/codex-shared-daemon.md)。
  - 查不到、而链上一个带控制终端的进程都没有时静默：hook 不在哪个终端里，继承来的 pane
    不可信。0.157 被系统收养的共享后台进程就是这个形状（2026-09-25 实测：PPID 1、无终端，
    `LIGHTTY_PANE_ID` 属于当初拉起它的终端）。
