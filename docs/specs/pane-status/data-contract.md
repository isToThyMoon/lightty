# 运行时目录、报文与验证

> 状态：现行契约。（核对于 2026-10-29）

终端运行时目录布局与 hook 报文格式，及状态链路的验证清单。属于 [Pane 状态与 Handoff 注入契约](../pane-status.md)；状态含义见 [状态机](state-machine.md)。

## 运行时目录

- ~/.lightty/tasks/：Handoff 任务文件。
- ~/.lightty/panes/<uuid>/owner.pid：终端归属的 lightty 进程，供残留回收。
- ~/.lightty/panes/<uuid>/task：任务绝对路径，lightty 写、hook 读。
- ~/.lightty/panes/<uuid>/handoff.injected：上次注入的会话 ID 与任务路径。

终端解绑删除任务指针及注入标记；终端关闭移除运行时状态。工作区快照中的 Agent 身份用于重启恢复，不代表实时状态持久化。

## 报文

UTF-8 JSON，版本 v=1；信封含 pane UUID，载荷含 ts（ISO8601）、state，以及可选 agent、session_id、tool、detail、cwd、event、transcript_path（会话日志路径，只给[输出速度](../output-speed.md)用，超过 1KB 不发）。
单包上限与编解码校验以 LighttyCore/PaneStatus.swift 的 PaneStatusDatagram 为准。未知版本、畸形报文、已 detach 的 pane 均丢弃；detail 长度不可信，展示时截断。
原始 event 必须区分 SessionStart 与 SessionEnd，两者虽然同为 idle，自动恢复决策不同。

## 状态链路验证

- fixture 验证所有事件映射、未知版本、畸形/超长报文、detach 后在途消息与多实例隔离。
- 临时 socket 验证真实 helper 发包、接收顺序与退出资源清理，不使用用户运行目录做测试。
- 真终端检查环境继承、CLI hook 注册、Codex trust、状态显示、完成提醒和通知定位。
