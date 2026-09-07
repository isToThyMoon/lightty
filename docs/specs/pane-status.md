# Pane 状态与 Handoff 注入契约

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

## 4. 数据契约

### 4.1 运行时目录

- ~/.lightty/tasks/：Handoff 任务文件。
- ~/.lightty/panes/<uuid>/owner.pid：终端归属的 lightty 进程，供残留回收。
- ~/.lightty/panes/<uuid>/task：任务绝对路径，lightty 写、hook 读。
- ~/.lightty/panes/<uuid>/handoff.injected：上次注入的会话 ID 与任务路径。

终端解绑删除任务指针及注入标记；终端关闭移除运行时状态。工作区快照中的 Agent 身份用于重启恢复，不代表实时状态持久化。

### 4.2 报文

UTF-8 JSON，版本 v=1；信封含 pane UUID，载荷含 ts（ISO8601）、state，以及可选 agent、session_id、tool、detail、cwd、event。
单包上限与编解码校验以 LighttyCore/PaneStatus.swift 的 PaneStatusDatagram 为准。未知版本、畸形报文、已 detach 的 pane 均丢弃；detail 长度不可信，展示时截断。
原始 event 必须区分 SessionStart 与 SessionEnd，两者虽然同为 idle，自动恢复决策不同。

### 4.3 状态机

| 状态 | 触发事件 | 含义 |
| --- | --- | --- |
| idle | SessionStart / SessionEnd / Interrupt | 无活跃 turn |
| thinking | UserPromptSubmit / PostToolUse | turn 进行中 |
| tool | PreToolUse | 正在调用工具 |
| attention | Notification / PermissionRequest | 需要用户介入 |
| done | Stop | turn 完成、待用户查看 |

lightty 在查看终端或全部标记已读时清除 done；新收到的生命周期事件正常覆盖当前状态。hook 不判断用户是否已读。
未知 hook 事件不映射为已有状态。

## 5. 展示与线程

PaneStatusStore 在主线程使用，接收队列回到主线程后发布定向 lighttyPaneStatusDidChange；不复用会重建任务列表的通知。
终端头部、第二侧栏和菜单栏使用一致的状态语义；高频更新原地重绘，不改变终端名称布局。提醒与通知由各自展示逻辑处理。
动态颜色的 CGColor 快照在外观变化时重新解析；不可见终端不应持续运行动画。

## 6. 验证

- fixture 验证所有事件映射、未知版本、畸形/超长报文、detach 后在途消息与多实例隔离。
- 临时 socket 验证真实 helper 发包、接收顺序与退出资源清理，不使用用户运行目录做测试。
- 真终端检查环境继承、CLI hook 注册、Codex trust、状态显示、完成提醒和通知定位。
- Handoff 注入验证先绑定后启动、先启动后绑定、改名、解绑再绑定、同一会话重复提交。

## 8. Handoff 注入

helper 在 SessionStart 读取已绑定任务，通过 hookSpecificOutput.additionalContext 注入正文与任务地址。
UserPromptSubmit 补处理晚绑定与改名；handoff.injected 按 session ID + 路径去重，同一组合不重复注入，解绑清除标记。

上下文注入不等于自动生成或写回总结。用户向 Agent 提出“总结当前 handoff task”等请求后，由 Agent 按任务协议写回；必须验证配置与任务绑定有效。
任务启动弹窗由 RestoreFlow 提供，选择 Agent 与分屏 / 新标签页 / 新窗口；已打开位置可直接前往。Sessions 模式的原生恢复不自动绑定任务或额外注入 Handoff。
