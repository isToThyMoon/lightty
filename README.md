# Lightty

为并行运行多个 AI agent 设计的 macOS 终端。内核基于 [libghostty](https://github.com/ghostty-org/ghostty)，保留完整的终端能力；壳层针对多 agent 会话的三个核心问题：**掌握各会话的运行状态、在完成或需要介入时获得提醒、让中断的工作可以延续**。

**运行状态一目了然。** 每个 pane 实时显示其中 agent 的状态：思考中、执行工具中、等待输入或已完成。离开当前窗口也不影响——agent 完成或需要介入时，菜单栏状态项与系统通知会及时提醒，点击即可定位到对应 pane。

**中断的工作可以延续。** 每个 pane 可绑定一个「任务」。结束会话前让 agent 将当前进展写入任务的交接文档；之后在任意新会话中打开该任务，新的 agent 会自动获得这份上下文并继续工作，无需回溯聊天记录或手工复制。

**依然是完整的终端。** Ghostty 的渲染、配置与快捷键均按原样可用；支持多工作区与分屏，pane 可自由拖拽重组，误操作可用 cmd+Z 撤销。支持应用内更新，界面提供中英双语（跟随系统语言）。

初次使用时，在菜单中选择「Agent 状态 hooks」一键安装，即可接入 claude / codex 的状态。安装通过二者自身的插件机制完成，不会改动你的 agent 配置。

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
