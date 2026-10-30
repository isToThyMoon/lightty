# Pane 状态与 Handoff 注入契约

> 状态：现行契约。（核对于 2026-10-29）

安装、卸载和故障排查见 [Agent 状态 hooks](../hooks.md)。实时活动状态与任务文件 frontmatter 的 status 无关；后者仅作文件兼容保留。

## 1. 职责

状态不依赖任务绑定。Claude Code CLI / Codex CLI 的生命周期 hook 为 lightty 中的终端提供活动信号；Handoff 注入只对已绑定任务的终端执行。

## 2. 注册与生命周期

- lightty 在自己的 marketplace 中提供插件，通过 Agent 官方 CLI 注册，不自行合并用户 hook 配置文件。
- helper 是独立 lightty-hook executable，只依赖 Foundation / LighttyCore，不执行模型调用。
- 稳定入口 ~/.lightty/bin/lightty-hook 指向当前 app 内的 helper，启动时刷新。
- Codex hook trust 由用户与 Codex 管理，lightty 不绕过审核。

## 3. 数据流

终端启动时注入 LIGHTTY_PANE_ID 与 LIGHTTY_SOCK，shell、Agent、hook 沿进程树继承。
helper 将一事件一报文发往当前 lightty 实例的 Unix domain SOCK_DGRAM socket；PaneStatusStore 接收并在主线程更新状态。

每实例路径为 ~/.lightty/run/<pid>.sock。实时状态仅在内存，不写 status.json，不用目录 watcher 传输，不做持久化补发。
收包队列顺序解码，每次状态迁移交给主线程；UI 可按 runloop 合并重绘，不能在接收层压掉用于完成提醒的迁移。
无监听者或发送失败不应阻塞 Agent。报文不能用于证明外部终端的运行状态，多个发送者也不构成全局执行顺序证明。

## 4. 专题

按任务读对应一份，互不依赖：

- 改 hook 如何认 agent 进程、丢弃工具里拉起的子会话（`AgentProcessIdentity`、Codex 会话路由）时，读 [进程识别与子会话判定](pane-status/process-identity.md)。
- 改运行时目录（`~/.lightty/panes`、`run`）、`PaneStatusDatagram` 报文字段，或写状态链路测试与真终端验收时，读 [运行时目录、报文与验证](pane-status/data-contract.md)。
- 改 agent 状态如何从 hook 事件推出、终端标题补偿、done / attention 已读规则时，读 [状态机](pane-status/state-machine.md)。
- 改状态圆点、呼吸动效、第二侧栏文字、系统通知合并与撤回规则时，读 [展示与线程](pane-status/display.md)。
- 改 Handoff 注入文本、`handoff.injected` 去重、「更新交接文档」写回路径及其验证时，读 [Handoff 注入与写回](pane-status/handoff.md)。
