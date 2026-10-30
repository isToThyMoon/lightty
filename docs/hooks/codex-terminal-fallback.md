# 兜底：Codex 写进本 pane 的终端信号

本篇讲共享后台进程关联失效时，Codex 状态如何退回终端标题（OSC 0）与桌面通知（OSC 9）。回到入口：[Agent 状态 hooks](../hooks.md)；主路径见 [Codex 共享后台进程](codex-shared-daemon.md)。

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
