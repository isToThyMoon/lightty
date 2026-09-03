# Lightty

面向 AI agent 工作流的 macOS 终端：内核基于 [libghostty](https://github.com/ghostty-org/ghostty)，壳层围绕「任务」组织终端会话——每个 pane 可绑定一个任务的 handoff 文档，会话中断后随时在新会话里让 agent 接续上一棒。

- **知道 agent 在干什么的终端**：一键安装 agent 状态 hooks（经 claude / codex 自家 CLI 注册，不改你的 agent 配置），pane 级实时显示思考中 / 执行工具 / 需要你 / 已完成；跑完或卡住时菜单栏状态项计数提醒 + 系统通知，点击直达对应 pane
- **任务与 Handoff**：任务 = 一个 markdown 文件（frontmatter + handoff 正文），活跃/休眠由 pane 绑定实时派生；绑定任务后 hook 自动向 agent 会话注入 handoff 上下文，接续上一棒无需手工粘贴
- **窗口 › 工作区 › pane 三层布局**：双层侧栏（工作区栏 + 任务浮层卡片，可拖宽）、pane 身份胶囊（灵动岛式展开改名/绑任务）、全文搜索浮层（⇧⇧）
- **分屏行为对齐 Ghostty.app**：cmd+D 分屏、拖 pane header 四边落点重组（可 cmd+Z 撤销）、跨窗口拖拽、侧栏行拖到其他工作区；侧栏动画期间终端逐帧真实重排（内核补丁消除 prompt 闪烁）
- **开箱即用**：Sparkle 应用内更新、内置终端主题开关、一键下载安装默认字体（Maple Mono NF CN）；界面中英双语（跟随系统），handoff 文档协议为英文

## 安装 / Install

从 [Releases](../../releases) 下载 DMG，拖入 Applications。

应用已签名但未公证。首次打开若提示「无法验证开发者」：**系统设置 → 隐私与安全性 → 拉到底部 → 「仍要打开」**；或在终端执行：

```sh
xattr -cr /Applications/lightty.app
```

The app is signed but not notarized. If Gatekeeper blocks the first launch:
**System Settings → Privacy & Security → scroll down → "Open Anyway"**, or run
`xattr -cr /Applications/lightty.app`.

要求 macOS 13+（Apple Silicon / Intel 通用包）。

## 从源码构建

内核是带补丁的 ghostty fork（分支 [`lightty-patches`](https://github.com/isToThyMoon/ghostty/tree/lightty-patches)），需要 [zig](https://ziglang.org) 0.16.0：

```sh
git clone https://github.com/isToThyMoon/lightty && cd lightty
git clone -b lightty-patches https://github.com/isToThyMoon/ghostty vendor/ghostty
(cd vendor/ghostty && zig build -Demit-macos-app=false -Dsentry=false -Doptimize=ReleaseFast)
scripts/sync-ghosttykit.sh
swift build && .build/debug/lightty      # 开发运行
scripts/package-app.sh                   # 打包 lightty.app（MAKE_DMG=1 出 DMG）
```

深入文档：[任务文件格式](docs/task-format.md) · [agent 状态 hooks](docs/hooks.md) · [pane 状态协议](docs/specs/pane-status.md) · [双层侧栏设计](docs/specs/double-sidebar.md)

## License

内核 ghostty 遵循其自身许可证；本仓库壳层代码许可证待定。
