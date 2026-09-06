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
`lighttyTasksDidChange` 仅保留任务/现场结构相关用途，不再承载会话标题或 Agent 关联变化。

## 验证

- `SessionModelTests` 通过真实 provider/状态输入的替身验证模型接口，不创建视图。
- `RestoredSessionTitleTests` 覆盖 Handoff 模式冷启动、前后台 pane 和重复启动。
- `SessionSurfaceConsistencyTests` 验证一个模型更新两个侧栏和 pane，且保留物化行身份。
- `SessionRestorationTests`、`AgentProcessLifecycleTests` 保留快照兼容、真实进程退出与任务独立性的验证。
- `SessionPresenceTests` 覆盖真实关闭标签入口、多个本地窗口与外部进程并存、退出后的侧栏原地更新、PID 复用。

本重构不改变工作区快照、任务文件、组织文件或 hook 报文的持久化格式。
