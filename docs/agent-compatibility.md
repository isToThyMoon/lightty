# Agent 对接兼容验证

保留现有对接功能，以集中验证减少逐项追上游的工作。兼容结论绑定到实际 CLI 版本、固定的
Claude SDK 版本和 lightty 提交；不把「测试命令成功」等同于所有原生交互都已验证。

## 执行入口

在已按 README 准备好 Swift 与 GhosttyKit 构建环境的 macOS 上运行：

```sh
python3 scripts/check-agent-compatibility.py
```

脚本先准备锁定版本的 Claude helper（缓存缺失时会下载依赖），构建一次，再按功能运行既有
回归测试。完整模式要求本机两家 CLI 都存在；通过与应用相同的定位逻辑记录实际路径与版本。
缺 CLI、跳过测试、筛选后零测试、失败或超时都不能算通过。各组失败后继续检查其余组。

只检查 fixture 回归时使用 `--fixtures-only`。报告会将本机接口标为 `not-checked`，不产生
CLI 兼容结论。两种模式都不会自动升级 CLI、安装 lightty 插件或发起模型请求。

结果位于 `.build/agent-compatibility/<本次运行>/report.json`，每组有独立日志。报告包括提交、
工作区是否有未提交改动、SDK 版本、CLI 版本、测试数量和退出码，保存在本机供排查与复核。
脚本清除继承的 `LIGHTTY_*` 环境后运行；测试自己的 Hook socket 与随机 pane 不受影响。
默认每步最多 600 秒，可用 `--timeout` 调整；超时会结束该检查的进程组。

## 覆盖范围

| 检查组 | 验证内容 |
| --- | --- |
| state-routing | Hook 二进制与 socket、会话关联、后台重连、状态合并、Claude agent view |
| handoff | 注入、去重、晚绑定、技能与直接指令 |
| sessions-titles | 启动参数、恢复关联、目录、改名与删除模型、标题解析、app-server 传输 |
| output-speed | 日志解析、请求边界、用量与速度窗口 |
| plugins-config | 插件生成与安装逻辑、插件和 MCP 配置解析 |
| installed-contracts | 本机 Codex schema 与真实配置根的普通/归档目录首页、Claude 活会话接口与 attach 帮助；临时合成会话经真实 Codex / 固定 Claude SDK 改名、列表回读、删除 |

除最后一组外是 fixture 回归，不能证明新版 CLI 真的仍产生相同事件。最后一组的 Codex 目录与 Claude
活会话查询只读本机状态，元数据写操作只碰临时配置根。它也不启动原生 TUI，不验证模型调用。

## 上游升级后的维护

检查仅在本机按需运行，使用本机已安装的 CLI 版本。升级 CLI 或修改对接实现后，手动执行上述命令。

先运行完整检查，按失败组进入 [依赖清单](agent-dependencies.md) 的对应实现。新增回归优先
扩展已有场景或输入表。来自真实事件的样本要标注 CLI 版本、采集场景及脱敏方式；手工构造的
样本明确标为合成，不能当作新版本实测证据。只保留所需协议字段，移除正文、路径和凭证。

schema 检查负责方法、字段与枚举存在性；fixture 负责已知行为；真实流程负责字段语义和事件
时序。发布前仍要验证两家新建/恢复、审批/中断、后台切换、标题同步、Handoff 读写与输出速度。
自动运行这些 TUI / 模型流程需要专门的登录及后台进程隔离环境，目前尚未接入。

### 适配入口

| 变化发生在哪里 | 修改入口 |
| --- | --- |
| 两家 Hook 的载荷字段、细节摘要、additionalContext 输出格式 | `AgentHookEvent`；事件到活动状态的映射仍由 `PaneActivity` 负责 |
| 两家输出速度日志格式与请求边界 | `TranscriptSpeedParser`；字节预筛容忍 type 字段冒号两侧的 JSON 空白 |
| Codex 后台广播、thread/read 状态与会话来源字段 | `CodexSessionEvents`：转换成有类型的会话事件与快照 |
| Codex 后台连接与 WebSocket 传输 | `CodexDaemonChannel` |
| 会话如何关联 pane、广播与在途快照谁更新 | `CodexSessionRouter` |
| Codex 活动如何与 Hook 合并 | `PaneStatusStore.noteCodexActivity` |
| Claude 活会话表格式 | `ClaudeSessionProvider.decodeLiveSessions`，由 agent view 与占用判断共用 |

`CodexSessionEvents.Method` 是订阅广播名的唯一清单，契约检查直接用它核对本机 schema。
新增未知广播不影响已有行为；已知广播缺少必要结构时记录诊断。未知状态仍保留会话身份并推进
Router 的 revision，防止较早发出的 thread/read 回来后覆盖较新的事件。广播与补查共用状态解析。
乱序场景用合成事件回放验证，不标作上游真实录制样本。

`AgentHookEvent` 逐个容错读取可选字段，避免单个新增或变形字段导致整发状态丢失。路径按
UTF-8 字节限制报文大小，文本摘要按字符截断；旧插件的 Agent 推断仍使用未截断的日志路径。
helper 只负责输入输出、进程与 pane 路由、Handoff 绑定及去重，不再散布 Hook 字段名。

继续整理其他适配边界时，先以场景保护行为，再移动协议解析与身份规则。保持现有兜底逻辑，
不要把本机新版本一次通过解释为历史版本、所有安装方式或所有后台模式均已覆盖。

## 运行时诊断

使用含当前改动的 lightty 和 `lightty-hook` 二进制，先打开系统日志流，再复现问题：

```sh
/usr/bin/log stream --level debug --style compact --predicate 'subsystem == "com.lightty.agent"'
```

按同一 `pane`、`session` 和时间顺序检查以下阶段。进程名可区分 app 与 hook：

| stage | 关注的 reason |
| --- | --- |
| daemonConnection | connecting → connected；launchFailed、handshakeTimeout、disconnected 表示连接问题 |
| daemonEvent | unsupportedPayload 表示订阅的广播缺少必要字段；未订阅的广播忽略 |
| sessionRoute | declaredSession、resumeArgument、uniqueDirectory、nearestStart 说明 Codex 关联依据；Claude 用 titleMatched / foreground / list；unresolved、titleUnmatched、lookupFailed、writeFailed 定位未能关联的阶段 |
| titleRefresh | requested 表示标题变化已触发查询，不代表目录已返回新标题 |
| hookRoute | sessionRecord / inheritedTerminal 表示路由来源；unsupportedPayload、missingRoute、nestedSession、ignoredSessionEnd 表示载荷不支持或事件没有继续发送 |
| hookSend | sent 只证明 datagram 发送成功；sendFailed 不影响后续 Handoff 输出 |
| statusIngest | accepted 与 activity 记录被接纳的状态；detachedPane、staleTimestamp、staleSession、staleProcess、settledTurn 说明为何忽略报文 |
| handoff | noTask、alreadyInjected、unreadableTask；outputWritten / outputFailed 表示向 Hook stdout 写上下文的结果 |

`outputWritten` **不证明上游接受了上下文或模型读取了文档**；当前单向 Hook 协议没有这层确认。
同样，`accepted` 是状态存储接纳报文，不等于桌面通知已送达。没有日志也不能证明 Hook 未执行：
这些诊断以 debug 级别在复现时采集，系统不保证长期保留；不在 lightty 环境中的 Hook 仍静默退出。
路由写入、启动和上下文输出失败另以 error 级别记录，保留错误可见性。

诊断字段由 `AgentDiagnostic` 集中定义，只记录阶段、固定原因、Agent、pane、规范化的会话 UUID、
已知 Hook 名称与状态。不记录任务正文、提示词、工具参数、目录、标题或原始错误文本。会话 ID
不符合 UUID 时显示 unknown。采集文件仍包含会话标识和时间，在分享前按需要脱敏。
不修改 Agent 配置、不向 Hook stdout/stderr 添加诊断文本，也不新增常驻文件写入或重试。
