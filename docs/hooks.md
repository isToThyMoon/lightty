# Agent 状态 hooks

lightty 让 pane 显示里面的 agent 正在干什么（思考中 / 执行工具 / 需要你 / 已完成），
并在 agent 跑完时提醒你。这一切靠给你已装的 coding agent 注册一个小 helper 实现。

入口：**设置 → 通用 → Agent 状态 hooks → 管理…**。首次启动时若检测到你装了 agent 却没配过，
会主动弹一次引导。

状态、标题或 Handoff 异常时，按 [运行时诊断](agent-compatibility.md#运行时诊断) 采集
Hook 路由、socket 发送/接收、后台会话关联和上下文输出的阶段与原因。

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
唯一的例外是 [Codex 共享后台进程](hooks/codex-shared-daemon.md)：lightty 自己会挂一条本机连接旁听 Codex。

## 按任务读哪一篇

- 改注册的事件、`--agent` 命令、主会话/子会话判定，或排查某个状态边缺失时读 [hooks/events.md](hooks/events.md)（含 handoff 上下文注入的时机与去重）。
- 改 Codex 共享后台进程的会话到 pane 关联、`CodexSessionRouter`、路由记录、`thread/*` 回合状态时读 [hooks/codex-shared-daemon.md](hooks/codex-shared-daemon.md)。
- 改 Codex 在没有路由 / hook 时的终端标题（OSC 0）与桌面通知（OSC 9）兜底状态时读 [hooks/codex-terminal-fallback.md](hooks/codex-terminal-fallback.md)。
- 改 Claude agent view 后台会话的 pane 关联、`ClaudeAgentView`、`claude attach` 续接，或「终端必须是本 lightty 开的」判断时读 [hooks/claude-agent-view.md](hooks/claude-agent-view.md)。
- pane 头圆点不动、状态不更新、手动喂事件没反应时读 [hooks/troubleshooting.md](hooks/troubleshooting.md)。

## 注册方式：以插件形式，不改你的配置

lightty **不会**把 hook 定义写进你的 `~/.claude/settings.json` 或 `~/.codex/hooks.json`。

它在 `~/.lightty/marketplace` 生成一个插件，然后调用 **agent 自己的 CLI** 完成注册：

```sh
claude plugin marketplace add ~/.lightty/marketplace
claude plugin install lightty@lightty

codex plugin marketplace add ~/.lightty/marketplace
codex plugin add lightty@lightty
```

于是这些 hook 定义留在 lightty 自己的文件里，你的配置里只多几行声明式开关，
**而且是它们自己的 CLI 写的**：

| Agent | 你的配置里多了什么 |
|---|---|
| Claude Code | `settings.json` 的 `extraKnownMarketplaces` 与 `enabledPlugins` 两个键 |
| Codex | `config.toml` 的 `[marketplaces.lightty]` 与 `[plugins."lightty@lightty"]` |

这样做的好处：lightty 不需要理解、也不可能写坏它们的配置格式；将来它们改格式，
由它们自己的 CLI 负责。

注册哪些事件、命令写法、子会话判定、命令为何指向 `~/.lightty/bin/`：见 [hook 事件、命令与 handoff 注入](hooks/events.md)。

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
