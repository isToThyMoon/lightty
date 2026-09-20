# Lightty

为并行运行多个 AI agent 设计的 macOS 终端。内核基于 [libghostty](https://github.com/ghostty-org/ghostty)，保留完整的终端能力；壳层针对多 agent 会话的三个核心问题：**掌握各会话的运行状态、在完成或需要介入时获得提醒、让中断的工作可以延续**。

A macOS terminal built for running multiple AI agents in parallel. The core is [libghostty](https://github.com/ghostty-org/ghostty), so full terminal capability is a given; the shell addresses the three problems that come with a screen full of claude / codex sessions: **knowing what each session is doing, being notified when one finishes or needs you, and picking up interrupted work where it left off**.

**运行状态一目了然。** 每个 pane 实时显示其中 agent 的状态：思考中、执行工具中、等待输入或已完成。离开当前窗口也不影响——agent 完成或需要介入时，菜单栏状态项与系统通知会及时提醒，点击即可定位到对应 pane。

**Status at a glance.** Every pane shows what its agent is doing in real time: thinking, running a tool, waiting for input, or finished. You don't need to keep watching — when an agent finishes or needs your intervention, the menu bar item and a system notification will tell you, and one click takes you to the pane.

**中断的工作可以延续。** 每个 pane 可绑定一个「任务」。结束会话前让 agent 将当前进展写入任务的交接文档；之后在任意新会话中打开该任务，新的 agent 会自动获得这份上下文并继续工作，无需回溯聊天记录或手工复制。

**Interrupted work carries over.** Each pane can be bound to a "task". Before ending a session, have the agent write its progress into the task's handoff document; open that task in any new session later and the new agent automatically receives the context and continues the work — no scrolling through chat history, no manual copying.

**依然是完整的终端。** Ghostty 的渲染、配置与快捷键均按原样可用；支持多工作区与分屏，pane 可自由拖拽重组，误操作可用 cmd+Z 撤销。支持应用内更新（Sparkle），界面提供中英双语（跟随系统语言）。

**Still a full terminal.** Ghostty's rendering, configuration, and keybindings work as-is. Organize tabs and splits freely; panes can be dragged and rearranged, and mistakes are undoable with cmd+Z. In-app updates via Sparkle; the UI is bilingual (English / Simplified Chinese, following the system language).

初次使用时，在菜单中选择「Agent 状态 hooks」一键安装，即可接入 claude / codex 的状态。安装通过二者自身的插件机制完成，不会改动你的 agent 配置。

First-time setup: choose "Agent status hooks" from the menu to connect claude / codex status with one click. Installation goes through their own plugin mechanisms — your agent configuration is never modified.

## 安装 / Install

从 [Releases](../../releases) 下载 DMG，拖入 Applications。

Download the DMG from [Releases](../../releases) and drag it into Applications.

应用已签名但未公证。首次打开若提示「无法验证开发者」：**系统设置 → 隐私与安全性 → 拉到底部 → 「仍要打开」**；或在终端执行：

The app is signed but not notarized. If Gatekeeper blocks the first launch: **System Settings → Privacy & Security → scroll down → "Open Anyway"**, or run:

```sh
xattr -cr /Applications/lightty.app
```

要求 macOS 13+。Apple Silicon 下载 `-arm64`，Intel 下载 `-x64`。

Requires macOS 13+. Download `-arm64` for Apple Silicon or `-x64` for Intel.

## 从源码构建 / Building from source

内核是带补丁的 ghostty fork（分支 [`lightty-patches`](https://github.com/isToThyMoon/ghostty/tree/lightty-patches)），需要 [zig](https://ziglang.org) 0.16.0：

The kernel is a patched ghostty fork (branch [`lightty-patches`](https://github.com/isToThyMoon/ghostty/tree/lightty-patches)) and requires [zig](https://ziglang.org) 0.16.0:

```sh
git clone https://github.com/isToThyMoon/lightty && cd lightty
git clone -b lightty-patches https://github.com/isToThyMoon/ghostty vendor/ghostty
(cd vendor/ghostty && zig build -Demit-macos-app=false -Dsentry=false -Doptimize=ReleaseFast)
scripts/sync-ghosttykit.sh
swift build && .build/debug/lightty      # 开发运行 / run for development
scripts/package-app.sh                   # 打包 lightty.app（MAKE_DMG=1 出 DMG）/ package lightty.app (MAKE_DMG=1 for a DMG)
```

开发文档：[任务文件格式](docs/task-format.md) · [agent 状态 hooks](docs/hooks.md)

Developer docs: [task file format](docs/task-format.md) · [agent status hooks](docs/hooks.md)

## 许可证 / License

[MIT](LICENSE)，与 Ghostty 相同。vendored 的 ghostty 内核遵循其自身的 MIT 许可证。

[MIT](LICENSE), same as Ghostty. The vendored ghostty kernel remains under its own MIT license.
