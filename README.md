# Lightty

给同时跑多个 AI agent 的人的 macOS 终端。内核是 [libghostty](https://github.com/ghostty-org/ghostty)——终端该有的样子一点不少；壳层解决的是开一排 claude / codex 之后的真实问题：**谁在跑、谁跑完了、中断的活怎么接着干**。

**不用盯着屏幕。** 每个 pane 实时显示它的 agent 在思考、在执行还是在等你；切去干别的也没关系——agent 跑完或卡住时，菜单栏和系统通知会叫你，点一下直达那个 pane。

**中断的工作接得上。** 每个 pane 可以绑定一个「任务」。让 agent 收工时把现状写进任务的交接文档，之后在任何新会话里打开这个任务，新 agent 自动拿到上下文，接着上一棒继续干——不用翻聊天记录、不用手工粘贴。

**还是你熟悉的终端。** Ghostty 的渲染、配置和快捷键原样可用；工作区和分屏随意组织，pane 想怎么拖就怎么拖（拖错了 cmd+Z）。应用内更新，界面中英双语。

初次使用：菜单里「Agent 状态 hooks」一键安装即可接入 claude / codex 的状态——安装走它们自家的插件机制，不会改动你的 agent 配置。

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

开发文档：[任务文件格式](docs/task-format.md) · [agent 状态 hooks](docs/hooks.md)

## License

内核 ghostty 遵循其自身许可证；本仓库壳层代码许可证待定。
