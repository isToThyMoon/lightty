# Agent 状态 hooks

lightty 让 pane 显示里面的 agent 正在干什么（思考中 / 执行工具 / 需要你 / 已完成），
并在 agent 跑完时提醒你。这一切靠给你已装的 coding agent 注册一个小 helper 实现。

菜单：**lightty → Agent status hooks**。首次启动时若检测到你装了 agent 却没配过，
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

**没有后台常驻进程，没有网络，状态不落盘。** helper 只在 agent 触发事件时被拉起，
发完就退出；lightty 没在跑时包直接丢弃——状态是用完即弃的，没有需要补的账。

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
外加 Claude Code 的 `Notification` / Codex 的 `PermissionRequest`。

七个都要，是因为状态机需要完整的进出边：只登记 `Stop` 的话圆点永远不会变成"思考中"；
漏掉 `PostToolUse`，工具跑完后状态会卡在 `tool` 上不回落。

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
echo '{"hook_event_name":"Stop"}' | LIGHTTY_PANE_ID=$LIGHTTY_PANE_ID LIGHTTY_SOCK=$LIGHTTY_SOCK ~/.lightty/bin/lightty-hook
```

**`echo $LIGHTTY_PANE_ID` 或 `$LIGHTTY_SOCK` 是空的** —— 这个 pane 是升级前开的。新开一个 pane。

> 注意：**不要用 `ps eww` 检查 pane 的环境变量**。macOS 不允许读取经由 setuid
> `login` 派生的进程环境，它会让一个正常工作的变量看起来"不存在"。要查就在 shell
> 里直接 `echo`。

**装好了但状态文件不变（Codex）** —— 多半是还没批准那个信任提示。跑一次 codex 看看。

**agent 会话是配置前起的** —— hook 配置在会话启动时读取，重开 claude/codex。

**手动喂事件后 UI 不动** —— lightty 侧的接收问题，请提 issue。

## 卸载

**lightty → Agent status hooks → Uninstall**，或直接用它们自己的 CLI：

```sh
claude plugin uninstall lightty@lightty
codex  plugin remove    lightty@lightty
```

卸载后 agent 一切照旧，只是 lightty 不再知道它在做什么。

## 相关文档

- `docs/specs/pane-status.md` —— 设计与实施计划、契约、已验证事实（§2.1.1 是插件路线的实测记录）
- `docs/task-format.md` —— 任务文件格式（其中的 `status` 字段与本机制**无关**，已弃用）
