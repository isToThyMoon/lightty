# 脆弱程度与输出速度

两家改了什么会直接失效、改了什么只是功能变弱，以及输出速度计对私有日志格式的依赖。升级任一家 CLI 后评估影响面时读。总览与入口见[依赖清单](../agent-dependencies.md)。

## 输出速度

第二侧栏的速度计只读 hook 报来的 `transcript_path` 指向的会话日志，不加入 Agent 的命令、配置、
请求或会话订阅链路。读的是两家的**私有日志格式**（Claude transcript、Codex rollout）；
格式变了只是速度计不显示，认不出的行不猜。
升级任一家后，拿本机一段新会话核对：Claude Code 2.1.310、Codex 0.164.0 实测通过。
各家用到的行与字段、计算口径与依据见[输出速度方案](../specs/output-speed.md)。

## 脆弱程度

改了会**直接失效**的，按影响面排序：

1. hook 载荷字段名、`hookSpecificOutput.additionalContext` 协议、插件目录约定 —— 状态、绑定、注入全没。
2. `codex app-server` 的方法名与响应形状 —— Codex 会话列表与改名、插件清单（`plugin/installed`）。官方区分稳定接口和 `experimentalApi` 门控接口，不能把所有方法统称为 experimental；稳定 schema 也不保证来源字段语义或 pane 关联规则不变。app-server 须常驻：它一启动就跑插件同步、git 市场升级检查等启动任务，问一句就关会砍断这些任务，留下孤儿 `git` 和 `~/.codex/.tmp/git-*`。
3. `@anthropic-ai/claude-agent-sdk` 的 `listSessions` / `renameSession` / `deleteSession` —— Claude 会话列表；版本锁在 `scripts/claude-session-helper/package.json`。
4. `claude agents --json` 的输出格式 —— 占用一律变成「问不出来」，删除时每次都弹确认；pane 不再跟着 agent view 切换会话。`pid`、`sessionId` 按官方文档是「有才给」（后台会话的进程被 supervisor 停掉后没有 `pid`），缺一个不算格式变了。
5. `claude plugin …` / `codex plugin …` 子命令形状 —— hook 装不上，已装的照常工作。

改了只是**功能变弱**的：会话日志的行格式（速度计不显示）、终端标题的前缀格式（Claude 中断后停在「思考中」、改名延后）、Codex 终端界面的 `originator` 名（0.157 起的终端会话从会话列表消失，pane 标题退回 pane 名）、配置文件的键名（设置页显示不全）、CLI 在 PATH 上的位置（找不到 CLI）。
这些都必须退化成「问不出来」或空列表，不能崩、也不能把「不知道」当成「没有」。

后台广播与补查快照的适配入口是 `CodexSessionEvents`；它将外部字段转成类型化事件，
`CodexSessionRouter` 负责会话关联与事件先后关系。修改入口和验证方式见 [兼容验证](../agent-compatibility.md#适配入口)。
