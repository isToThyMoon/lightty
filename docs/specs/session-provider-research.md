# Claude Code CLI / Codex CLI 本机会话发现与恢复调研

日期：2026-09-07。性质：可行性证据与建议，不是已实现功能。仅检查官方文档、官方公开源码及本机 CLI 帮助；没有读取用户会话正文，没有启动或恢复用户会话。

## 结论

范围：只接入 Claude Code CLI 与 Codex CLI 的本机历史，不以 ChatGPT App 的 Codex 会话为数据源，不接入桌面端、IDE 或云端历史列表。

Codex 官方将 `codex resume` 描述为搜索、恢复本地聊天，且本地状态放在 `CODEX_HOME`（默认 `~/.codex`）。这是本地恢复记录的位置，不是“所有对话数据只存在本机”的隐私保证；模型推理的数据传输与保存策略另算。[CLI](https://learn.chatgpt.com/docs/codex/cli)、[本地状态位置](https://learn.chatgpt.com/docs/config-file/config-advanced#config-and-state-locations)

`codex app-server` 是 codex 可执行文件的子命令，可通过本地 stdio 查询历史，不要求安装或连接 ChatGPT App。该 Interface 支持区分 `cli`、`vscode`、`appServer` 等来源，因此不能由“都叫 Codex”推断历史完全互通或完全隔离；本实现显式请求 `sourceKinds: ["cli"]`，不附加 cwd 限制。[官方 app-server 协议](https://learn.chatgpt.com/docs/app-server)

可实现跨项目的本地会话列表，点击后在 Lightty 新终端中运行原生 resume。发现历史与执行会话必须分离：Lightty 管列表和导航，原生 CLI 管推理、权限与交互。不要把 Sessions 伪装成 HandoffTask，也不要为显示列表而启动一次 agent query。

优先验证 Codex 官方 app-server 历史接口与 Claude 官方 SDK 元数据接口；不要先围绕私有 JSONL/SQLite 建立产品模型。Swift 集成成本与实际支持版本仍需一个独立技术验证阶段。

## 已核实的能力

| 项目 | Claude Code | Codex |
| --- | --- | --- |
| 本机版本（只读 `--version`） | 2.1.263 | codex-cli 0.153.4 |
| 按 ID 原生恢复（只读 `--help`） | `claude --resume <session-id>` | `codex resume <session-id>` |
| CLI 全部历史选择器 | `claude --resume`，交互选择器 | `codex resume --all`，取消 cwd 过滤 |
| 结构化历史入口 | Agent SDK `listSessions()` / Python `list_sessions()` | app-server `thread/list` |
| 范围 | 不传项目目录即跨本地所有 projects | 不传 cwd 即跨目录；来源和归档另外过滤 |
| 精确身份 | provider + config-home + session ID | provider + config-home + **thread.id**，不是 sessionId |

Claude CLI 的 resume 接收 ID；continue 只取当前目录最近历史，不能用于点击指定行。两者的 CLI 帮助均表明恢复与新建/分叉是不同操作。[Claude CLI reference](https://code.claude.com/docs/en/cli-reference)

### Claude：公开 SDK 已有列表能力

官方会话指南明确列出 TypeScript `listSessions` 和 Python `list_sessions`；不是只能靠非官方 transcript parser。会话持久化是本机文件，跨主机不能自动恢复。[Agent SDK sessions](https://code.claude.com/docs/en/agent-sdk/sessions)

官方 Python 实现中，不传 `directory` 扫描所有项目；支持 limit/offset，按修改时间降序；指定项目时默认包含 Git worktrees。元数据用 stat 和文件头尾提取，排除 sidechain 与无摘要记录。配置根支持 `CLAUDE_CONFIG_DIR`。这同时说明“只取元数据”不等于“完全不读 transcript 字节”，Lightty 应禁止把扫描内容写入日志。[官方实现，固定快照](https://github.com/anthropics/claude-agent-sdk-python/blob/efd4d865ef1795daffee3cd24cce45307aed8a51/src/claude_agent_sdk/_internal/sessions.py)

可取得 session_id、summary、custom_title、first_prompt、cwd、git_branch、last_modified、created_at、tag；多个字段可空。时间为 epoch **毫秒**。列表无需获取 get_session_messages。[官方 SDKSessionInfo](https://github.com/anthropics/claude-agent-sdk-python/blob/efd4d865ef1795daffee3cd24cce45307aed8a51/src/claude_agent_sdk/types.py#L1713)

本地路径为 `~/.claude/projects/<project>/<session-id>.jsonl`，配置根可替换。历史默认有 30 天清理周期，也可关闭保存，因此不能承诺“所有曾经存在的会话”。同时恢复同一会话到两个终端可能把消息交错写入同一 transcript。[Manage sessions](https://code.claude.com/docs/en/sessions)

**设计推论：** provider 首选官方 SDK metadata helper，但不能假设每台 macOS 都装有 Node/Python 或 SDK。实现前比较固定版本 helper 的签名/分发体积、升级策略与许可证；避免运行时自动安装依赖。若最终选 Swift 原生只读扫描器，应显式承认其兼容性债务，限制在 Claude adapter 内并建立多版本合成 fixtures，不能把文件字段泄漏到领域层。不要逆向编码目录名来猜 cwd。

### Codex：app-server 是历史 UI 的适配入口

官方 app-server 文档直接支持 `thread/list` 的分页历史 UI、初始化握手与 stdio。默认来源过滤为 interactive；归档需 `archived:true` 单独查询。`useStateDbOnly` 可跳过扫描修复，但可能牺牲历史完整性。`thread/read` 不加载执行线程；列表不需要 `thread/resume`。API 有稳定表面和 experimental opt-in，但本机命令整体仍标 experimental，不能宣传为永不变化。[官方 app-server 文档](https://developers.openai.com/codex/app-server)

列表参数提供 cursor、limit、排序、modelProviders、sourceKinds、cwd、archived、searchTerm；空 sourceKinds 并非所有来源。跨目录 All 不应附加 cwd；本需求只选已验证的 cli 来源，不纳入 vscode/appServer/exec 或子 Agent。[ThreadListParams 固定快照](https://github.com/openai/codex/blob/5ecb3afd1bf405149e2159bfda50093b0c1b5fab/codex-rs/app-server-protocol/schema/typescript/v2/ThreadListParams.ts)

Thread 有 id、name、preview、cwd、createdAt/updatedAt、source、parentThreadId、gitInfo 等；时间为 epoch **秒**。`path` 明标不稳定。当前源码同时有共享会话树的 sessionId 与 thread.id，恢复具体条目必须用后者；projectId 可空，不应直接当成 Lightty 项目。[Thread 固定快照](https://github.com/openai/codex/blob/5ecb3afd1bf405149e2159bfda50093b0c1b5fab/codex-rs/app-server-protocol/schema/typescript/v2/Thread.ts)

配置根由 `CODEX_HOME` 覆盖，默认 `~/.codex`；显式覆盖目录须存在。rollout 定义 active `sessions` 与 `archived_sessions`。[配置根源码](https://github.com/openai/codex/blob/5ecb3afd1bf405149e2159bfda50093b0c1b5fab/codex-rs/utils/home-dir/src/lib.rs)、[rollout 常量](https://github.com/openai/codex/blob/5ecb3afd1bf405149e2159bfda50093b0c1b5fab/codex-rs/rollout/src/lib.rs#L82)

**设计推论：** 使用用户实际 CLI 的 stdio 子进程，通过最小 JSON-RPC client 只查询摘要。不要连接未知端口或借用用户应用内部 socket，不设置默认 analytics 标志。可维护 process 生命周期，但不加载执行 thread。app-server 可能做启动初始化、DB 回填，不能把“逻辑只读列表”宣称为进程绝对零磁盘写入。用隔离 config-home 合成数据验证这些副作用与退出清理，再决定持续连接或按需连接。

**版本风险：** 当天公开说明与 main schema 的字段并非完全一致（如 isPinned / sectionId），rollout 的 interactive 来源也比文档更丰富。不能照最新网页硬编码所有字段。必须由目标 CLI `generate-json-schema` 生成对应 schema，再定义最低支持版本、容错解码与能力降级；以上快照是调研证据，不是承诺已安装版本全部支持。

## 恢复计划与权限边界（设计建议）

1. 身份使用 `(provider, installation/configHome, nativeID)`。预先查 Lightty 的 open-pane registry；已打开则前往，不重复 resume。
2. 未打开时，默认新标签页内新 terminal；保留当前页分屏、新窗口选择。恢复固定 provider，不展示会改变历史归属的 Agent 切换。
3. `ResumePlan` 包含 executable、arguments、environment、workingDirectory；使用记录 cwd。目录消失时让用户定位，不能偷偷在当前 cwd 继续。目录迁移的兼容性需单独测试。
4. argv 来自 provider，ID 校验；显示标题不得拼入 shell。沿用 terminal initialInput 时必须集中 shell quoting，并过滤控制字符，不能把 custom launch command 字符串简单追加 resume。
5. 默认恢复命令只包含 resume 与原生 ID。**建议**不要自动继承 Handoff 新任务的 `--yolo` / `bypassPermissions`；用户此前选定的新任务默认不等于给全部外部历史扩大权限。保留原有新任务设置，不擅自更改；如要统一，增加独立、明确可见的恢复权限策略。
6. 不传新 prompt、不注入 Handoff 文件、不创建 task binding。历史上下文交给原生 resume。默认省略权限 override 仍可能受用户 CLI 配置或历史影响，不能称为“保证沙箱安全”。

## All、项目与边界（产品建议）

- All = 已配置本地来源中可恢复的主会话，不是整个云账户、其它电脑、所有子 agent 或已经清理的记录。归档单独过滤；未支持来源给解释，不伪装空列表。
- Project 是 Lightty 自己的组织单元，保存引用和可选 cwd 规则；不移动 transcript、不修改 provider 的数据库。不同 agent 可属于同一个 Project。路径相同可作为自动分组建议，不等于项目身份；同名目录、worktree、symlink 需要规则。
- 外部运行状态不能靠 mtime 或单独 app-server 的 notLoaded 推断。只对 Lightty 自己注册的 pane 显示可靠“已打开”；外部状态未知，不假装“休眠”。
- 本期不做云会话、远程主机、归档写入/删除、子 agent 恢复、会话迁移。Claude background attach 和 cloud 标志是另一类执行目标，不能混入本地 resume 路径。
- 标题/摘要也是私人数据：内存分页索引，必要持久化只留引用与用户组织数据，默认不复制完整历史、不写遥测。失败应能区分未安装、未授权、未发现、源不可用、版本不支持。

## 实施前必须通过的验证门槛

- 固定版本 synthetic fixtures：跨 cwd、重名标题、空字段、中文/空格路径、非默认 config-home、worktree、归档、sidechain、半写 JSONL、清理后的 dangling reference。
- 两种 CLI 的真实 resume 冒烟使用专用测试会话；验证 ID 与 cwd、原上下文继续、不新增错误会话、不注入 prompt、不扩大权限。当前调研没有完成此项。
- Codex：初始化 + 两页列表 + graceful shutdown；不同来源覆盖、旧版本降级、数据库不完整、无网络/无登录时行为、已有 app 同时打开时的资源占用。
- Claude：SDK 最低版本/辅助运行时分发方案、API 缺失处理、分页开销（limit 不保证扫描量也受限）、原生安装与 SDK 的会话格式互通。
- 规模测试：万条历史不阻塞主线程，刷新可取消、切模式丢弃陈旧响应、文件变化合并去抖；禁止定时全量读取正文。
- 本文没有访问私人历史，因而“能列出这台机器所有实际记录”的覆盖率与历史权限恢复细节仍待隔离验证，不能作为已验收结果。
