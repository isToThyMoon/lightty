# 状态机

> 状态：现行契约。（核对于 2026-10-29）

hook 事件如何推出 Agent 活动状态，终端标题补偿，done / attention 与已读。属于 [Pane 状态与 Handoff 注入契约](../pane-status.md)；报文字段见 [数据契约](data-contract.md)。

| 状态 | 触发事件 | 含义 |
| --- | --- | --- |
| idle | SessionStart / SessionEnd / Interrupt / 带 `is_interrupt` 的 PostToolUseFailure / Notification `idle_prompt`（旁证，见下） | 无活跃 turn |
| thinking | UserPromptSubmit / PostToolUse / PostToolUseFailure | turn 进行中 |
| tool | PreToolUse | 正在调用工具 |
| attention | Notification / PermissionRequest | 需要用户介入 |
| background | `background_tasks` 非空的 Stop（目前只有 Claude Code） | turn 已结束，后台工作结束后 Agent 会自己开新回合 |
| done | `background_tasks` 为空或没有该字段的 Stop；background 超过 30 分钟 | turn 完成、待用户查看 |

## 等待后台

两家都没有这个状态，lightty 从 Claude Code `Stop` 载荷的 `background_tasks` 分出来；`session_crons` 不算。
background 不提醒、不算未读，展示计入「进行中」。后台工作结束或被杀时，Claude Code 发
`UserPromptSubmit`（prompt 是 `<task-notification>`），回合结束再发 `Stop`，所以走 thinking → done 正常提醒。
2.1.318 用 `claude -p` 实测过这条路径；后台 shell 不发 `TaskCompleted`，不能拿它判断结束。

- 长驻进程（如 dev server）永远等不到唤醒，超过 30 分钟转为 done 提醒一次（`PaneStatusStore.backgroundWaitLimit`）。
  跑得更久的任务因此会多一次提醒，真正结束时还有一次。
- 后台刚结束、通知还在排队时，`Stop` 的列表可能已经为空：会先到 done，随即被唤醒回到 thinking。
- Codex 的 `Stop` 没有该字段，一律 done。它的 `thread/backgroundTerminals/list` 是实验接口，lightty 不打开。

## 终端标题补偿

**活动状态由 hook 驱动**；终端标题（OSC 0）只补 Claude 缺少 Interrupt hook 的中断信号。
两家也把状态写进了标题，
形状写在各家 `AgentSpec.terminalTitle` 里，解析见 `AgentTerminalTitle`：

| | 忙 | 闲 | 等用户处理 |
| --- | --- | --- | --- |
| Claude Code | `◐ <会话标题>` / `◑ …`（960 毫秒轮换） | `✳ <会话标题>` | 也是 ✳，分不开 |
| Codex（默认 `activity`、`thread-name`、`project-name`） | `⠋ <线程名> \| <项目名>`（braille 旋转字符，100 毫秒一帧） | `<线程名> \| <项目名>`，没有前缀 | `[ ! ] Action Required \| …`（与 `[ . ]` 每秒交替） |

收方规则（`PaneStatusStore.noteTerminalTitle`）：只在 hook 已登记 agent、尚未 SessionEnd，
且该 agent 没有 Interrupt hook 时使用标题补偿（当前仅 Claude）。明确的空闲前缀只允许
thinking / tool → idle；busy 和 attention 标题不修改状态，done / attention 及已读提醒也不受标题影响。
正常结束时 `Stop` 与空闲标题谁先到结果都是 done。Codex 的思考、完成、等待和中断全部由 hook 驱动，
标题动画不能生成提醒，也不能把已完成或待处理改回思考中。

标题继续用于 Agent 识别和名称变化检测；正文变化触发 `SessionLibrary` 合流重读官方目录，
标题的真值仍在目录里。Claude 空闲前缀认不出来时，退回 hook，中断状态可能延迟更新。

hook 侧的用户中断信号两家不同：Codex 发 `Interrupt`；Claude Code 的 `Stop` 在用户中断时
**不触发**，只有中断时正在跑的工具会发带 `is_interrupt` 的 `PostToolUseFailure`。标题前缀里
「等用户处理对话框」和「停在提示符上」都是 ✳，分辨它们只能靠 `Notification` / `PermissionRequest`。
Claude Code 另有一条私有序列 OSC 21337（`indicator=;status=;status-color=`，带文字状态），
2.1.274 里开关写死关闭，未启用；启用后值得替换标题前缀这条路。

## done 与已读

lightty 在用户下一次查看/交互或全部标记已读时清除 done：切入终端、重复聚焦、点击、
键盘/输入法输入、粘贴与滚动均走终端的统一交互事件，由 SessionLibrary 标记已读。
即使完成时终端已聚焦，也先保留提示，不在收到 Stop 时自动清除；其他 pane 的未读不受影响。
attention 与“是否已读”分开：点击、输入或全部标记已读只确认提醒，不把 Agent 的等待状态
改成 idle。文字与状态圆点保留，呼吸与待发通知停止；后续生命周期事件正常替换等待状态。
新的请求重新变为未读；相同请求报文的重复投递不重新点亮。已读信息只由应用在内存管理，
不写入 hook 报文或工作区快照。侧栏重建、切换标签页不丢失已读信息。
新收到的生命周期事件正常覆盖当前状态。hook 不判断用户是否已读。
未知 hook 事件不映射为已有状态。
