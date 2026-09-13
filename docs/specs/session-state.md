# 统一会话状态

`SessionLibrary` 是应用级会话状态模块。Sessions 第一侧栏、标签页第二侧栏、pane
胶囊与展开身份面板消费同一个模型，不从其他视图读取会话资料，不靠界面展示触发同步。

## 数据所有权

- `AgentSessionKey`（Agent、配置根、原生 ID）是唯一会话身份；标题、目录不能当身份。
- 官方 provider 负责会话元数据；`SessionLibrary` 合并分页和本地组织数据。
- `PaneStatusStore` 负责 hook 传输、顺序和进程存活检查，是模型的输入，不是视图的数据源。
- `SessionRuntime` 在模块内部归并恢复意图、hook 和终端进程事件，产生 `PaneSessionState`。
- `PaneSessionState` 同时携带 Agent 活动和提醒是否未读；阅读 attention 只取消未读强调，
  不等于处理完请求。该变化同样通过 `.activity` 通知侧栏与 pane，视图不自行保存已读标记。
- 关联状态为无关联、恢复中、已关联、无法恢复。无法恢复仍保存恢复意图，但不显示为已打开。
- 窗口报告 pane 集合与选中 pane；模型维护多窗口关系。同一会话允许多个 pane。
- `sourceProcesses` 只记录来源读取时观察到的进程身份（PID + 启动时间），不是实时运行布尔值。
  模型统一派生 `SessionPresence`：本应用有对应 pane、确认有存活外部进程、或没有可靠占用证据。
  关闭本地 pane 不会把其进程改判为外部进程；同一会话确实另有外部进程时仍保留提示。
- shell 目录、Agent 工作目录和目录中的会话元数据各有含义，不互相覆盖。
- 用户的 pane 名、标签页名及 Handoff 任务绑定保持独立；会话标题只影响派生显示。

## 生命周期与更新

1. 应用启动调用 `SessionLibrary.start()`，在恢复窗口前发起共享目录读取；此入口幂等。
2. pane 注册后才挂到窗口；恢复或启动命令把确定的关联提交给模型。
3. hook、进程结束、shell 目录变化、目录读取完成均先更新模型，再通知视图。
4. 新恢复关联覆盖此前遗留的结束状态；旧 shell completion 不能清除更新的关联。
5. 关闭或移动窗口改变现场关系，不等同于删除会话；Agent 退出则清除运行关联。
6. 已关联会话不在第一页时，模型继续读取已有 cursor，找到记录、来源读完或出错即停止。
   元数据失效后，即使旧记录已有缓存，也要在本轮读取中到达目标页，不能拿缓存当作已刷新。
7. Agent 操作可使元数据失效。模型合并延迟读取，最多五次；取消同时清除待重试请求。
   官方目录没有适用于当前独立终端运行方式的完整实时订阅，因此有界读取仍有同步窗口。
8. 已观察进程通过系统 process exit source 订阅退出，不依靠刷新目录或 UI 可见性。
   退出证据使缓存失效，通知受影响会话；旧 PID 被复用也不能复活旧占用状态。
   进程归属无法验证时显示未知，不把读取失败当作外部终端；原生恢复前的占用检查仍独立保留。

打开/切换侧栏和搜索只呈现当前状态。用户显式刷新仍可重新读取目录。

## 通知契约

`lighttySessionLibraryDidChange` 的 `object` 是所属 `SessionLibrary`，载荷由
`SessionChange.from(_:)` 读取，包含：

- `catalog`：目录、组织或加载状态变化，第一侧栏重新计算列表的差异；
- `panes`：变化的 pane ID，以及身份、元数据、活动、目录字段分类；
- `windows`：现场成员或选中项变化的窗口 ID；
- `sessions`：受影响的完整会话 key。

状态同步提交，通知合流到下一轮主 runloop。收到通知时所有相关 pane 都已归并完毕。
消费者只渲染，不再发送另一种“数据变化”通知。活动和元数据更新原地修改已显示的
pane 行，不重建标签页树，也不改变选中项、滚动位置或输入焦点。

底层 hook 通知仍供系统通知和状态菜单使用，但两个侧栏、pane/身份面板不直接订阅它。

会话之外，任务绑定、任务文件与窗口结构各有一条通知，都不承载会话标题或 Agent 关联变化：

- `lighttyTaskBindingsDidChange`：`object` 是发出变更的 `TaskBindings`，载荷由
  `TaskBindingChange.from(_:)` 读取——`cause`（绑定、解绑、终端释放，以及经 `TaskBindings`
  发起的建档、改名、归档、删除）、每个受影响终端的 before / after 任务、涉及的任务文件。
  操作完成时同步发出。终端标题、Handoff 列表、第二侧栏的任务名都订阅它；查询绑定一律问
  `TaskBindings`，不各自扫窗口比对 URL。外部改了已绑定任务的 `name`，也以 `rename` 发出（见下条）。
- `lighttyTasksDidChange`（定义在 LighttyCore）：`object` 是 `TaskBindings`，无载荷，收到的一方
  自己重读。含义是「任务目录里的文件变了」，谁写的都算——lightty 自己的写入与 Agent 按交接协议
  写回一视同仁。只有 `TaskBindings` 发：它持有任务目录的监听（生产用 `TaskFolderWatcher`，
  创建时开始、释放时结束，目录打不开时不监听、记一条日志），目录事件防抖约 0.2 秒后在主线程
  处理：先重读已绑定任务的名字，变了就发 `rename` 绑定变更；文件读不出来（不存在、内容写坏）
  不算改名、不解绑，保留现状；然后发本通知。Handoff 列表订阅它，只认
  `AppState.shared.taskBindings` 发出的那条。
  自己写入也要等这一拍：需要立刻看到结果的视图自己重读（设置里的归档列表、启动浮层的目录
  展示），不另发通知。归档子目录内的永久删除不触发它，Handoff 列表本就不显示归档任务。
- `lighttyWindowArrangementDidChange`：无载荷。`TerminalWindowController` 在 `commit` 收尾与
  `windowWillClose` 里发出，让别的窗口的第二侧栏跟上。任务「活跃」不靠它：只问 `TaskBindings`，
  挪动终端、关窗不改绑定，终端释放时由 `TaskBindings` 发 `paneRemoved`。Handoff 列表不订阅它。

窗口结构通知、任务绑定通知和 pane 状态通知会触发工作区快照的节流保存。快照只记任务文件路径，
`lighttyTasksDidChange` 不触发保存。

## 验证

- `SessionModelTests` 通过真实 provider/状态输入的替身验证模型接口，不创建视图。
- `RestoredSessionTitleTests` 覆盖 Handoff 模式冷启动、前后台 pane 和重复启动。
- `SessionSurfaceConsistencyTests` 验证一个模型更新两个侧栏和 pane，且保留物化行身份。
- `SessionRestorationTests`、`AgentProcessLifecycleTests` 保留快照兼容、真实进程退出与任务独立性的验证。
- `TaskBindingsTests`（Core）验证每种操作发出的载荷与指针文件，以及任务目录变更：手动触发的变更源验证一次事件一条列表通知、外部改名同步到已绑定终端、文件消失或读不出不解绑、跨线程回到主线程、释放即停止监听；另有一条用真实 `TaskFolderWatcher` 验证「临时文件加 mv」到达一次。`PaneTaskBindingsTests` 用真实终端验证改名（含外部改名）、归档、删除传导到每个绑定终端，以及终端释放后任务不再算已打开。`HandoffSidebarReloadTests` 验证列表跟随外部写入与归档恢复，且不再随窗口结构变化重读。
- `SessionPresenceTests` 覆盖真实关闭标签入口、多个本地窗口与外部进程并存、退出后的侧栏原地更新、PID 复用。

本重构不改变工作区快照、任务文件、组织文件或 hook 报文的持久化格式。
