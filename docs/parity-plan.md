# Ghostty 终端适配核查清单

本清单用于变更后的回归核查，不把列出的能力当成尚未实现的功能。

## 所有权

终端输入、快捷键和终端行为配置由 libghostty 解析；需要宿主完成的操作经 action 回到 lightty。
适配契约见 [libghostty 嵌入](libghostty-embedding.md)。参考实现使用仓库中 vendor/ghostty 的对应版本，不依赖易过期的源码行号。

## 核查范围

| 范围 | 核查内容 |
| --- | --- |
| 输入 | key translation、option-as-alt、左右 modifier、IME/preedit、Command keyUp、焦点首击 |
| 鼠标 | 多键鼠标、滚动、压力、拖入路径/文本、配对 mouseDown/mouseUp |
| surface 生命周期 | inherited config、cwd、backing scale、display ID、occlusion、子进程退出 |
| 宿主动作 | 新窗口、标签页、分屏、关闭确认、标题、PWD、剪贴板 |
| 菜单 | binding action 路由、菜单校验、查找、分屏、重置、Services |
| 外观 | 配置重载、COLOR_CHANGE、CONFIG_CHANGE、背景透明度、明暗主题、split 分隔线 |
| 安全与可访问性 | secure input、VoiceOver、选择文本、焦点与通知权限 |
| 辅助能力 | 桌面通知、进度、滚动指示、Inspector；按目标版本确认支持情况 |

## 验证方式

- 运行 scripts/check-terminal-adapter-parity.sh 与相关测试。
- 对照 TerminalSurfaceView、GhosttyRuntime 与 vendored macOS 参考壳核查改变的通路。
- 真实终端覆盖 shell 提示符、全屏 TUI、IME、滚动、分屏与窗口开合。
- 核查内核补丁后重新生成 GhosttyKit，不能只重新构建 Swift。
- 发现缺口时建立具体问题及验收用例，不用旧清单推断当前代码缺失能力。
