# 会话目录：来源、刷新与故障

> 状态：现行契约；万条规模与发布包验收未完成，见入口的「待实施」。（核对于 2026-10-29）

`SessionLibrary` 与两个来源 Adapter（`CodexSessionProvider`、`ClaudeSessionProvider`）怎样读取、合并、刷新会话目录，以及失败时保留什么。入口见 [第一侧栏模式](../primary-sidebar-modes.md)。各家官方接口与用法见 [会话接口](../agent-session-apis.md)，来源调研见 [CLI 会话调研](../session-provider-research.md)，Claude helper 的分发与固定版本见 [SDK helper 验证](../claude-sdk-distribution-research.md)。

## 范围

“全部”指本机已配置 CLI 来源下、跨工作目录的用户主会话。Codex 只收终端界面建的会话（判据在 `CodexAgent` 与调研文档），不纳入桌面端 / IDE、`appServer`、`exec` 或子 Agent；未知来源类型不得映射为可恢复的主会话。某版本来源编码变了，先用 fixture / 专用会话验证再改 Adapter，不放开所有来源掩盖问题。不承诺远程机器、云端独有、其他系统用户、已删除或未落盘的会话。

## 结构约束

- `SessionLibrary` 是 deep module：对外只有快照通知、刷新 / 加载更多 / 取消、修改组织数据；内部隐藏多源合并、排序、去重、部分失败、缓存与取消。结果同时含数据与各来源状态，一个来源出错不清空另一个来源已读到的会话。
- 来源 seam 只要求两件事：读某查询的一页元数据；为确定会话给出可验证的 resume 计划。只有两个真实 Adapter，不预建插件注册、事件总线或通用数据库层。
- 分页 cursor 是 Adapter 私有 opaque token，视图不接触 Codex cursor 或 Claude offset。
- `AgentSessionKey` = agent + sourceRoot + nativeID，不能只用裸 ID、标题或 cwd。Codex 的 nativeID 取 `thread.id`，不是共享会话树的 `sessionId`；Claude 毫秒与 Codex 秒在 Adapter 内统一成 Date。`AgentSession` 只带列表需要的元数据，不带 transcript。
- 归组、排序、会话 key、启动计划是 `LighttyCore` 里的 Foundation 纯逻辑；视图只做展示与用户意图，磁盘与外部进程在后台执行。
- 任务与会话可共用行外观、菜单与启动控件，不合成一个满是可选字段的通用 Entry 模型；Handoff 文档不伪装成会话，会话不灌进 `TaskStore`。
- 只读元数据：Codex app-server 不用 `thread/resume` 预载历史或开始 turn；Claude helper 不调用模型、不在运行时 npm install、不要求另配 API key。helper 缺失时给出可操作错误并保留原生选择器，不回退到私有解析器或用户 PATH 中的 Node。

## 刷新

- 查询时机：应用启动、手动刷新、登录 shell PATH 变化、hook 触发的元数据重读（`SessionLibrary` 合流）。切换模式、打开侧栏或搜索浮层、回前台、展开 / 收起、本地筛选与归组都不查询目录。
- 每来源每分区（普通 / 原生归档，后者仅 Codex 有）首页 100 条，“加载更多”按需取后续页；搜索只覆盖已加载记录，未加载完显示加载状态，不把未扫描当无匹配，不以第一页冒充“全部”。各来源取到足够头部数据后才承诺全局按时间合并的顺序。
- 刷新与取消递增 generation，旧请求不能覆盖新状态；分页去重并检查循环游标。刷新按钮在加载期间变为取消。
- 刷新期间保留已加载行；加载只显示为“最近会话”标题右侧的小型旋转指示器（搜索浮层在搜索框尾部），不在主体或底部显示加载文字。
- 若以后加 watcher：只作失效提示，不在回调里读整库，合并事件，退出时释放资源。

## 故障与规模

- 外部进程有超时、输出上限、取消、退出清理（`AgentHelperProcess`）；Claude helper 按页运行、读完释放。
- 失败保留已有记录，来源失联不等于会话被删；只有完整来源读取成功后才清理失效记录。
- Claude SDK 列表会读 transcript 头尾生成元数据，limit 不限制底层扫描量；性能预算按实际扫描量测，不只看返回条数。不在每次按键重拉全量 transcript。
- 日志只记来源、计数、耗时、错误类型，不落正文、完整 prompt、密钥或默认完整路径。
