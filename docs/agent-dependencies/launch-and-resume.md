# 启动与恢复会话

lightty 怎么找到并拉起 Claude Code / Codex、怎么续接会话、往开着的会话里粘指令，以及对安装方式的唯一假设。总览与入口见[依赖清单](../agent-dependencies.md)。

## 启动与恢复会话

命令行只在 `Sources/lightty/AgentCommand.swift` 一处拼装；调 CLI 与 node helper 的进程环境（清 `LIGHTTY_*`、PATH、配置目录变量、arm64 运行时路径）只在 `AgentHelperProcess` 里拼。

| 功能 | Claude Code | Codex | 出问题时 |
|---|---|---|---|
| 找可执行文件 | 只在三段里找 `claude`：进程 PATH → 登录 shell 的 PATH（`LoginShellPath`）→ `/usr/bin:/bin:/usr/sbin:/sbin` | 同左，找 `codex` | 找不到：设置页显示「未检测到」，会话列表跳过这一家，重启后恢复 pane 只开终端不启动 Agent |
| 新会话 | `claude [--permission-mode bypassPermissions] [自定义参数]` | `codex [--yolo] [自定义参数]` | 参数取自设置，见 `AgentLaunchPreference` |
| 恢复会话 | `claude [参数] --resume <id>` | `codex resume [参数] <id>` | 会话 ID 来自 hook 或列表；配置根不是默认时用 `CLAUDE_CONFIG_DIR` / `CODEX_HOME` 显式传入 |
| 打开 CLI 自带的选择器 | `claude --resume` | `codex resume --all` | |
| 让开着的会话改名 | 往 TUI 粘 `/rename <名字>` | 同左 | 两家写法一致；会话没开时走[会话列表、改名、删除、占用](sessions.md)的官方接口 |
| 让开着的会话重写交接文档 | 往 TUI 粘 `/lightty:handoff <路径>` | 粘 `$lightty:handoff <路径>` | **插件没装或调用名写错两家都静默失败**，所以粘之前先查插件装没装；没装就粘完整指令（`HandoffProtocol.directInstruction`） |

配置根：`SessionConfigurationLocation`，`CLAUDE_CONFIG_DIR` / `CODEX_HOME` 设了就是自定义来源，否则是 `~/.claude` / `~/.codex`。

## 安装方式

**我们对安装方式只有一个假设：CLI 在 tty 的 PATH 上。** 找可执行文件只看进程 PATH、
登录 shell 的 PATH 和系统目录（见上表），不写死 homebrew / nvm / volta / pnpm 那一串目录，
也不按安装路径的形状认身份。理由：pane 里跑的就是这个登录 shell，它的 PATH 看不见的 CLI，
用户自己在终端里也敲不出来；替他找到反而更糟——设置页说「已检测到」，真去 pane 里启动却失败。

hook 认「哪个进程是 agent」也不看名字，只看终端作业结构（见[状态与上下文 hook](status-hooks.md)），所以原生安装的
`versions/<版本号>`、npm 的 `claude.exe`、node 包装脚本这些差异都不再进入任何判断。

不支持的两种安装：Claude 桌面应用自带的 Claude Code；ChatGPT.app 自带的 `codex`
（不在 PATH，也不是给命令行用的）。

唯一还与安装方式有关的实现细节：npm 装的 codex 是个 node 包装脚本再启动平台包里的原生
`codex`，强杀时要连子进程一起杀（`ProcessTree`），否则留孤儿。
