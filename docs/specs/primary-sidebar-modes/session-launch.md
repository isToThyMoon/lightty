# 单击会话与续接

> 状态：现行契约。（核对于 2026-10-29）

Sessions 里点一条会话之后发生什么：前往、启动浮层、占用检查、错误与恢复安全。入口见 [第一侧栏模式](../primary-sidebar-modes.md)。启动链路的固定顺序与关联生命周期见 [终端关联契约](../../terminal-associations.md)；两家的命令写法、配置根变量与启动参数见 [启动与恢复会话](../../agent-dependencies/launch-and-resume.md)。

## 单击与目的地

1. 已在 lightty 打开：经 `PaneLauncher` 前往对应窗口 / 标签页 / 终端，不新开。
2. 未打开：弹启动浮层（`LaunchComposer` 的 `.resume` 主体），显示标题、Agent、更新时间与目录，只选去处（当前标签页分屏 / 新标签页（默认）/ 新窗口）；Agent 与目录归会话，不可改。点继续才运行原生 resume，与 Handoff 单击任务一致。打开方式只在浮层里，行菜单不重复。搜索浮层是键盘流程，回车直接在新标签页续接。
3. 会话只能由原 Agent 恢复，不能把 Claude 会话换成 Codex 打开。
4. 发出 resume 不等于恢复成功：只有匹配 Agent 与会话身份的 hook 才确认，无 hook 时只算“已发起”；进程失败保留可见终端错误。
5. CLI 不存在、目录丢失、来源不可用：先显示可恢复的错误，不创建无声失败的空终端。目录丢失让用户选新目录再重新请求，不退到 home 执行 Agent。

## 占用检查

手动续接前 `PaneLauncher` 在后台调 `provider.occupancy`，同一会话的检查合并：

- `.inUse(pid)`：提示回原终端继续，不新建终端；lightty 不结束 Agent、不删锁、不自动 fork。
- `.background(job)`：命令改为 `claude attach` 接回后台会话。
- `.unknown`：交给原生 CLI 判断。Codex 恒为 `.unknown`（已确认在 lightty 运行的会话仍前往原终端）；Claude 读 `claude agents --json`，超时 3 秒，问不出即未知，不读进程表或文件表反推。

该检查不是互斥锁，不消除检查与启动之间的竞态。原生选择器没有会话 ID，占用由 CLI 自行处理。为什么两家不同见 [会话接口](../agent-session-apis.md)。

## 恢复环境与安全

- 来源、配置根、可执行文件与 resume ID 必须一致：`SessionConfigurationLocation` 把默认配置与显式目录分开（路径相同也不合并）；默认配置在子进程里 `env -u` 清除覆盖变量，自定义配置只在子进程设置该变量。工作区同时保存确认后的会话身份与配置来源，缺来源时不猜目录。
- 侧栏、搜索与工作区恢复共用 `SessionResumePlan`，原生选择器用 `SessionPickerPlan`，两者组合同一个 `AgentLaunchContext`——校验与命令拼法只在这里。续接带上用户为新会话设置的启动参数（`launchArguments` 无默认值，新入口必须显式交代）。
- `SessionResumePlan` 拒绝空、超长、以 `-` 开头或含白名单外字符的 ID，避免数据被当成选项。受管查询进程用 executable + argv、不经 shell；必须经 shell 输入时只在唯一编码出口逐参数 quoting，不插入标题或预览正文。
- 续接不绑定 handoff、不注入交接文档、不修改 Agent 配置、认证文件或原始会话。
- 浏览与手动续接不要求会话仍 alive；工作区重启时的 alive 只决定是否自动重开 Agent，不用于过滤目录。
