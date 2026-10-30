# hook 故障排查

本篇讲 pane 头圆点不动、状态不更新等问题的逐项检查。回到入口：[Agent 状态 hooks](../hooks.md)；Hook 路由与 socket 的阶段化诊断见 [运行时诊断](../agent-compatibility.md#运行时诊断)。

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
