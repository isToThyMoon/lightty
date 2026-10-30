# 第一侧栏：Handoff 任务 / Sessions 会话

> 状态：部分实现。双模式外壳、会话目录、项目组织与续接已落地；发布加固（万条规模、helper 签名公证、旧系统验收）未完成，见「待实施」。（核对于 2026-10-29）

第一侧栏（`PrimarySidebar`）在两种资料导航之间切换：Handoff 任务（`HandoffSidebarContent`，基于 `TaskStore`）与 Sessions 会话（`SessionsSidebarContent`，基于 `SessionLibrary`）。Sessions 复用 Claude Code CLI / Codex CLI 的原生恢复，不在 lightty 重建对话引擎；原始会话归 Agent，lightty 只持有组织数据与可重建的目录。本文的 Codex 指 Codex CLI，不是 ChatGPT App 内的 Codex。术语见 [CONTEXT.md](../../CONTEXT.md)，卡片布局与第二侧栏见 [双侧栏布局约定](double-sidebar.md)。

按任务读：

- 改 Sessions 列表的布局、行内容、拖放、动画、搜索浮层或“新建”：[Sessions 列表布局与交互](primary-sidebar-modes/sessions-list.md)
- 改单击会话、启动浮层续接、占用检查、目录丢失或 resume 命令安全：[单击会话与续接](primary-sidebar-modes/session-launch.md)
- 改项目分组、移到项目、本地归档 / 恢复或 `organization.json`：[项目与本地归档](primary-sidebar-modes/projects-and-archive.md)
- 改目录读取、分页、刷新时机、来源 Adapter、失败处理或性能：[会话目录：来源、刷新与故障](primary-sidebar-modes/session-catalog.md)

## 模式切换

- `ModeSwitch` 是两段式切换：灰底圆角轨道，**Handoff** / **Sessions**（不本地化）两段按卡片宽度等分，当前段铺白色滑块（深色下比轨道亮一档），点另一段即切换并平移滑块（“减少动态效果”下直接到位）。激活段 semibold 主文字色，其余 medium 次级色；长文字截断；辅助功能为单选组。
- 模式说明只在每段 tooltip 与空状态里出现，不常驻占行。
- 头部的搜索、新建、收起三钮在两种模式都显示；搜索与新建按模式路由（Handoff：任务搜索 / 新建任务；Sessions：会话搜索浮层 / 新会话）。切换模式关闭旧模式的菜单、启动浮层与搜索浮层，只替换内容区：面板尺寸、两栏开合、终端焦点与标签页 / 分屏树都不变。
- 模式按窗口保存：写入工作区快照的可选字段 `primarySidebarMode`，旧快照缺失时按 Handoff 解码；新窗口继承最近选用的模式，其他已开窗口不跟着切换。默认 Handoff，升级不改变已有习惯。快照里的 `taskPanelOpen` 等旧键名保持不变。

## Handoff 模式的归档与搜索

- 首次成功归档任务时提示可在设置里找回或彻底删除（`handoffArchiveNoticeShown`）；失败不消耗这次提示。已归档任务的恢复与彻底删除在设置的 Handoff 页，见 [Handoff 设置页](handoff-settings.md)。
- 任务搜索（`SearchPaletteView`）右侧保留正文滚动预览，下方嵌入 `LaunchComposer` 的 Agent、已打开位置、目的地与启动按钮；默认新标签页，回车优先前往已打开位置，否则按当前选择启动。启动区独立滚动，最多占预览区 70%，长正文或多个已打开位置不遮住控件。

## 不做

对话全文阅读器、跨 Agent 转换历史、云端同步、归档写回 Agent、后台自动恢复所有会话、多层项目树、自动合并 worktree、第三方 Agent 插件系统。会话改名与永久删除已实现，接口见 [会话接口](agent-session-apis.md)。

## 待实施：发布加固

目标值均未实测：

- 规模：合成 1 万条会话，主线程无 I/O，缓存首屏 200ms 内，分页 / 筛选可取消，内存随元数据而非全文增长。
- 真实 UI：深浅色、全局 accent、键盘 / VoiceOver、多语言、长标题、快速切模式；macOS 13–15 与 26 分别验收，旧系统抖动须在对应系统上验证。
- 发布包：签名公证、helper 分发、无 Node / Python 开发环境、两家 CLI 升级、外部程序不可用时降级；门槛细节见 [SDK helper 验证](claude-sdk-distribution-research.md)。
