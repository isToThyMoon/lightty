# 终端、会话与 Handoff 的关联契约

## 所有权与基数

```text
Window → Tab → Pane（分屏树叶子）
                 ├─ 0..1 Agent Session Association + Agent 运行实例
                 └─ 0..1 Handoff task 文件绑定
```

会话和任务都可以被多个 Pane 引用；它们之间没有隐式的一对一关系。目录相同、名字相同、同一标签页都不是关联证据。Pane 移动到另一标签页/窗口时保留本体和两种关联；重启后 Pane 的运行时 UUID 重新分配，持久关联随该快照叶子重建，不复用旧 hook 路由。

## 唯一身份来源

`PaneSessionAssociation` 包含完整 `AgentSessionKey(agent, sourceRoot, nativeID)`、配置来源和工作目录。`PaneView` 不再分别维护 catalog key 与三份恢复身份兜底；显示、保存、恢复都使用同一模型。工作目录是恢复参数，不是身份。

身份输入只有两类：

- Lightty 原生 resume 计划：创建 Pane 时原子建立关联，不等待 hook。
- 此 Pane 收到的 hook：明确 Agent、ID、来源根目录和配置来源，覆盖旧身份。旧 hook 缺少根目录时，仅接受已知同身份或唯一 catalog 匹配；歧义不猜测。

## 关联在哪里建立

所有由 lightty 发起的新终端——启动浮层、Sessions 续接与原生会话选择器、任务开始处理、重启恢复——都构造一个 `TerminalLaunchRequest` 交给 `PaneLauncher`（`AppState.paneLauncher`），不各自造 `PaneView`。启动器按固定顺序处理：删除互斥 → 已打开则聚焦 → 恢复计划 → 占用检查 → surface 配置 → 会话关联 → 任务绑定 → 放置。

- 续接会话：会话已在本应用某个终端里开着就聚焦那个终端，不新开；否则用 `SessionResumePlan` 构造命令，在装进窗口之前调用 `associateSession` 原子建立关联。
- 重启恢复：`restoredPane(from:)` 从快照叶子重建关联。目录与 CLI 都在时记为恢复中并构造续接命令；缺任何一项记为无法恢复，保留意图、不启动 Agent。原来的终端名原样回填。
- 新建会话、原生会话选择器：不指向任何会话，不建立关联；身份由之后的 hook 带来。选择器用 `SessionPickerPlan`，不需要伪造会话身份。
- 请求带任务、或快照里的任务文件还在：经 `TaskBindings.bind` 绑定，与会话关联互不影响。

启动器只返回结果（已启动、已聚焦、没启动及原因），目录选择面板、占用提示框、错误框由调用方按结果呈现。Finder 服务（`FinderServiceProvider`）、内核的 new_window / new_tab、分屏、空态与第二侧栏的「新标签页」只开纯终端，直接建 `PaneView`，不经过启动器，也不建立关联。

配置来源区分 standard 与 custom，即使 custom 路径恰好等于默认目录也不能合并；Claude 的设置查找语义可能不同。新 hook 在运行时报文中传递这一信息。旧报文未携带配置来源时，优先保留已知关联的来源，否则标准根目录按 standard、其他根目录按 custom 处理，这是旧信息的边界，不宣称能还原缺失的历史环境。

## 生命周期

| 事件 | 关联与恢复行为 |
| --- | --- |
| 新建空 shell | 无会话关联；可独立绑定任务 |
| 已发起 resume，尚无 hook | 保留关联及恢复参数，不等同于 CLI 已成功恢复 |
| surface 尚未创建 | 不算进程退出，不清除关联 |
| 收到明确会话 hook | 使用 hook 身份；新会话替换旧会话 |
| 收到 SessionEnd / 终端进程退出 | 不再高亮此会话，不自动续接 |
| 关闭最后窗口 / 退出应用 | 从同一关联值投影到 workspace 快照 |
| 重启 | 从快照重建关联，再用 SessionResumePlan 构造命令；不用等待下一次聊天 |
| 找不到 CLI / 工作目录 | 保留恢复意图；空 shell 不标为已打开，不悄悄换根目录 |
| 绑定、解绑、改名 Handoff | 不改变会话关联 |

hook 只提供活动证据。没有 hook 既不能证明 CLI 已结束，也不能证明一个尚未知晓 ID 的普通 shell 中运行了哪个会话。Lightty 外部终端没有本应用的 Pane 所有权，不进入内部跳转映射；外部占用检查仍是只读的，不杀进程、不删除锁、不修改 Agent 配置。

## Agent 进程生命周期

shell/PTY 的所有权与生命周期由 TerminalSurface/libghostty 管理，不能用 shell 仍存活推断 Agent 仍存活。`AgentProcessIdentity` 单独记录 PID 与内核进程启动时间，只存在于 hook 运行时报文与 PaneStatusStore，不写进 workspace，更不能在重启后复用旧 PID。

hook 在自己的祖先进程链中定位最近的受支持 Agent 可执行程序，报告的是 Agent，不是 hook 或中间 shell。因此 Lightty 发起 resume 和用户在 Lightty Terminal 中手动启动 Agent 共用这条注册链路。应用对属于本进程树的已知实例注册 [DispatchSource 退出事件](https://developer.apple.com/documentation/dispatch/dispatchsourceprocess)，不以按键次数、提示符文本或高频全局扫描判断退出。

- 退出事件解除当前实例的活动关联，清除侧栏高亮/已打开并更新恢复意图；Handoff 绑定保持不变。
- 快照与点击恢复之前，额外复核已知实例，覆盖退出通知还在主队列等待的窗口。
- 校验 PID 和启动时间，拒绝旧实例的迟到报文；退出回调只能结束相同实例，不能影响已替换的新实例。
- 若报文已经来自退出的实例，不把后续迟到的工具事件当成复活。
- 未取得 PID 的旧报文/已知 resume，使用 Ghostty 的 shell command-finished 事件兜底。启动命令尚未发送时忽略该事件；已知 Agent 仍存活或无法确认状态时不因该事件解绑。
- Pane 注销、状态源停止时取消进程监听。监听不拥有、终止或接管 Agent。

可观测性边界：hook 未启用、尚未产生任何身份事件，或自定义包装方式无法识别 Agent 进程时，不能凭目录推导新 Session ID。若同时禁用了 shell integration，也没有已知 PID，则缺少可靠退出信号，保留未知而不假装已结束。此处不承诺对任意第三方包装脚本和关闭所有信号的环境零盲区。

## 导航与持久化

- Tab 拥有 Pane；当前窗口的 activePane 决定 Sessions 选中项，不存一份“最后点击会话”。
- “已打开”从当前窗口集合中的 Pane 关联派生，不存入 organization.json。
- 点击已打开会话聚焦已有 Pane，不重复启动（由 `PaneLauncher` 判断）；一对多时当前实现选择窗口树遍历中的第一个匹配。聚焦前先复核已知 Agent 进程。
- Handoff 的文件绑定由 `TaskBindings` 统一持有（终端 UUID ↔ 任务文件），`PaneView` 只读查询；任务文件不是 Agent transcript。
- `PaneSnapshot` 保留已发布 workspace v1 字段作为磁盘适配层；catalogSession/catalogConfiguration 现用于所有完整身份，不仅侧栏发起的会话。旧 agent/sessionID 字段仍由同一个值投影，业务层不独立修改它们。
- 旧快照没有完整来源时使用旧版标准 CLI 恢复语义；此前已经被写成空的会话身份无法凭空找回，不按目录猜配。

## 回归验证

`SessionAssociationTests` 使用隔离工作区、真实 Unix socket、真实 Pane 与快照读写，覆盖两种 Agent 的普通 hook 入口、无 hook 连续三次保存恢复、配置来源、命令排队、任务解绑独立性、退出清除、恢复依赖缺失及 Tab/分屏聚焦。测试恢复命令使用 `/bin/echo`，不调用用户的 Agent，也不修改其配置。

`AgentProcessLifecycleTests.swift` 另外启动测试自有进程，验证没有 SessionEnd 的退出、PID 重用、旧报文重放、新实例替换、活进程不误解绑、退出后快照同步复核，以及每一种关闭入口都对账进程；`SessionFocusTests.swift` 验证侧栏高亮与 Sessions 选中项跟随当前聚焦的终端。`PaneLauncherTests.swift` 用会话 provider 替身验证启动器：被占用时不建终端、已打开时聚焦、空闲时关联并放到指定去处、删除进行中拒绝续接与选择器、选择器不需要会话身份、任务经 `TaskBindings` 绑定、CLI 缺失时快照恢复记为无法恢复。

这些 swift-testing 用例都挂在 `SessionAssociationTests` 套件下，按套件名过滤即可一并运行。

```sh
swift test --filter 'SessionAssociationTests|ordinaryAgentLaunchUsesHookIdentity|hookSourceRootSurvivesWireRoundTrip|WorkspaceSnapshotTests|HookAgentEndToEndTests|PaneStatusStoreTests'
```
